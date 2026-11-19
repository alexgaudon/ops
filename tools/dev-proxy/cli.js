#!/usr/bin/env node
// dev-proxy: manage Apophis preview routes (or opt into the legacy NPM backend).
// Usage:
//   npm run up -- <name> <port> [--cwd <dir>] [--no-route] -- <command...>
//                                       start <command> in a detached tmux session and
//                                       publish https://<name>.<domain> -> http://<host>:<port>
//                                       (pass --no-route to skip publishing, e.g. a backing service)
//   npm run down -- <name>              stop the session and remove its Apophis route
//   npm run status                      show running previews and their routes
//   npm run add -- <name> <port>        register a route without starting a service
//   npm run remove -- <name>            remove the route and stop its session
//   npm run list                        show active internal preview routes
//   npm run certs                       show certificates for the preview domain

import { execFileSync } from 'node:child_process'
import { mkdirSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'
import { NpmClient } from 'nginx-proxy-manager-sdk'
import { installCurlFetch } from './curl-fetch.js'
import { apophis, previewName } from './apophis.js'

// macOS Local Network privacy blocks ad-hoc signed binaries (node) from reaching
// the LAN, so route the SDK's requests through Apple-signed curl instead of
// requiring sudo. See curl-fetch.js.
installCurlFetch()

const env = (k, fallback = '') => process.env[k] || fallback

// Accept short names in .env (URL/EMAIL/PASSWORD) as aliases for the NPM_* names.
const BASE_URL = env('NPM_BASE_URL', env('URL', 'http://10.0.0.20:81'))
const EMAIL = env('NPM_EMAIL', env('EMAIL'))
const PASSWORD = env('NPM_PASSWORD', env('PASSWORD'))
const TOKEN = env('NPM_TOKEN')
const CLOUDFLARE_TOKEN = env('CLOUDFLARE_API_TOKEN', env('CF_TOKEN'))
const DNS_PROVIDER = env('DNS_PROVIDER', 'cloudflare')
const PORKBUN_KEY = env('PORKBUN_API_KEY', env('PORKBUN_KEY'))
const PORKBUN_SECRET = env('PORKBUN_SECRET_API_KEY', env('PORKBUN_SECRET'))
const DOMAIN = env('PREVIEW_DOMAIN', 'dev.amgau.xyz')
const FORWARD_HOST = env('PREVIEW_HOST', '10.0.0.49')
const LOG_DIR = join(homedir(), '.dev-proxy', 'logs')
const BACKEND = env('PREVIEW_BACKEND', 'apophis')
const shellQuote = (value) => "'" + value.replaceAll("'", "'\\''") + "'"

function client() {
  if (TOKEN) return new NpmClient({ baseUrl: BASE_URL, token: TOKEN })
  if (EMAIL && PASSWORD) return new NpmClient({ baseUrl: BASE_URL, email: EMAIL, password: PASSWORD })
  throw new Error('Set NPM_TOKEN, or NPM_EMAIL and NPM_PASSWORD, in .env')
}

const fullName = (name) => (name.includes('.') ? name : `${name}.${DOMAIN}`)

// ---- tmux helpers ----

function tmux(args, opts = {}) {
  const { PREVIEW_INTERNAL_TOKEN, ...childEnv } = process.env
  return execFileSync('tmux', args, { stdio: 'pipe', env: childEnv, ...opts })
}

function ensureTmux() {
  try {
    tmux(['-V'])
  } catch {
    throw new Error('tmux is required. Install it (brew install tmux) and try again.')
  }
}

/** tmux-safe session name, derived from the short preview name. */
function sessionName(name) {
  const short = name.includes('.') ? name.split('.')[0] : name
  return `devproxy-${short.replace(/[^a-zA-Z0-9_-]/g, '-')}`
}

function hasSession(session) {
  try {
    tmux(['has-session', '-t', `=${session}`])
    return true
  } catch {
    return false
  }
}

function listSessions() {
  try {
    return tmux(['ls', '-F', '#{session_name}'])
      .toString()
      .split('\n')
      .map((line) => line.trim())
      .filter((line) => line.startsWith('devproxy-'))
  } catch {
    return []
  }
}

function killSession(session) {
  if (!hasSession(session)) return false
  try {
    tmux(['kill-session', '-t', `=${session}`])
    return true
  } catch {
    return false
  }
}

function sessionFromName(name) {
  const short = name.includes('.') ? name.split('.')[0] : name
  return sessionName(short)
}

// ---- routes ----

async function ensureWildcardCert(c) {
  const wildcard = `*.${DOMAIN}`
  const certs = await c.certificates.list()
  const existing = certs.find((cert) => (cert.domain_names || cert.domains || []).includes(wildcard))
  if (existing) {
    console.log(`reusing certificate #${existing.id} for ${wildcard}`)
    return existing.id
  }
  if (!DNS_PROVIDER || (DNS_PROVIDER === 'cloudflare' && !CLOUDFLARE_TOKEN) || (DNS_PROVIDER === 'porkbun' && (!PORKBUN_KEY || !PORKBUN_SECRET))) {
    throw new Error(
      `No certificate for ${wildcard} found and DNS credentials for provider "${DNS_PROVIDER}" are not complete. ` +
        'Set the matching API keys in .env (see .env.example).',
    )
  }
  let creds = ''
  if (DNS_PROVIDER === 'porkbun') {
    creds = `dns_porkbun_key = ${PORKBUN_KEY}\ndns_porkbun_secret = ${PORKBUN_SECRET}`
  } else {
    creds = `dns_cloudflare_api_token = ${CLOUDFLARE_TOKEN}`
  }
  console.log(`creating Let's Encrypt wildcard certificate for ${wildcard} (DNS-01 via ${DNS_PROVIDER})...`)
  const cert = await c.certificates.create({
    provider: 'letsencrypt',
    domain_names: [wildcard, DOMAIN],
    meta: {
      dns_challenge: true,
      dns_provider: DNS_PROVIDER,
      dns_provider_credentials: creds,
      propagation_seconds: 30,
      key_type: 'ecdsa',
    },
  })
  console.log(`certificate #${cert.id} created`)
  return cert.id
}

async function findHost(c, domain) {
  const hosts = await c.proxyHosts.list({ expand: ['certificate'] })
  return hosts.find((h) => (h.domain_names || []).includes(domain))
}

async function ensureRoute(c, name, port) {
  const domain = fullName(name)
  const certId = await ensureWildcardCert(c)
  const existing = await findHost(c, domain)

  if (existing) {
    console.log(`updating proxy host #${existing.id} for ${domain}`)
    await c.proxyHosts.update(existing.id, {
      forward_host: FORWARD_HOST,
      forward_port: port,
      certificate_id: certId,
      ssl_forced: true,
      http2_support: true,
      allow_websocket_upgrade: true,
    })
  } else {
    console.log(`creating proxy host for ${domain} -> http://${FORWARD_HOST}:${port}`)
    await c.proxyHosts.create({
      domain_names: [domain],
      forward_scheme: 'http',
      forward_host: FORWARD_HOST,
      forward_port: port,
      certificate_id: certId,
      ssl_forced: true,
      http2_support: true,
      block_exploits: true,
      allow_websocket_upgrade: true,
    })
  }
  return domain
}

// ---- commands ----

function parsePort(raw) {
  const port = Number(raw)
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error(`Bad port: ${raw}`)
  return port
}

/** Splits `name port [--cwd dir] -- command...` into its parts. */
function parseUpArgs(args) {
  const sep = args.indexOf('--')
  if (sep === -1) throw new Error('Usage: npm run up -- <name> <port> [--cwd <dir>] -- <command...>')
  const head = args.slice(0, sep)
  const command = args.slice(sep + 1)
  if (command.length === 0) throw new Error('Missing command after "--"')

  const [name, portRaw] = head
  if (!name || !portRaw) throw new Error('Usage: npm run up -- <name> <port> [--cwd <dir>] -- <command...>')

  let cwd = process.cwd()
  const cwdIdx = head.indexOf('--cwd')
  if (cwdIdx !== -1) {
    const value = head[cwdIdx + 1]
    if (!value) throw new Error('--cwd requires a directory')
    cwd = value
  }

  return { name, port: parsePort(portRaw), cwd, command, noRoute: head.includes('--no-route') }
}

async function cmdUp(c, args) {
  const { name, port, cwd, command, noRoute } = parseUpArgs(args)
  ensureTmux()

  const domain = noRoute ? null : await ensureRoute(c, name, port)

  const session = sessionFromName(name)
  if (killSession(session)) console.log(`stopped existing session ${session}`)

  mkdirSync(LOG_DIR, { recursive: true })
  const logFile = join(LOG_DIR, `${session}.log`)
  const shell = `PORT=${port} ${command.map(shellQuote).join(' ')} 2>&1 | tee ${shellQuote(logFile)}`

  tmux(['new-session', '-d', '-s', session, '-c', cwd, shell])
  console.log(`started ${session} in ${cwd} (PORT=${port})`)
  console.log(`  tmux attach -t ${session}`)
  console.log(`  log: ${logFile}`)
  console.log(domain ? `live at https://${domain}/` : 'no route created (--no-route)')
}

async function cmdDown(_c, args) {
  const [name] = args
  if (!name) throw new Error('Usage: npm run down -- <name>')
  ensureTmux()
  const session = sessionFromName(name)
  console.log(killSession(session) ? `stopped session ${session}` : `no session ${session}; nothing to do`)
}

async function cmdStatus(c) {
  ensureTmux()
  const sessions = listSessions()
  const hosts = await c.proxyHosts.list({ expand: ['certificate'] })

  if (sessions.length === 0) {
    console.log('no running dev-proxy services')
    return
  }

  for (const session of sessions) {
    const short = session.replace(/^devproxy-/, '')
    const route = hosts.find((h) => (h.domain_names || []).some((d) => d.startsWith(`${short}.`)))
    const target = route ? `https://${(route.domain_names || [])[0]}` : '(no route)'
    console.log(`● ${session.padEnd(28)} ${target}`)
    console.log(`  attach: tmux attach -t ${session}`)
    console.log(`  log:    ${join(LOG_DIR, `${session}.log`)}`)
  }
}

async function cmdAdd(c, args) {
  const [name, portRaw] = args
  if (!name || !portRaw) throw new Error('Usage: npm run add -- <name> <port>')
  const domain = await ensureRoute(c, name, parsePort(portRaw))
  console.log(`live at https://${domain}/`)
}

async function cmdRemove(c, args) {
  const [name] = args
  if (!name) throw new Error('Usage: npm run remove -- <name>')
  const domain = fullName(name)
  const existing = await findHost(c, domain)
  if (!existing) {
    console.log(`no proxy host for ${domain}`)
  } else {
    await c.proxyHosts.delete(existing.id)
    console.log(`removed proxy host #${existing.id} for ${domain}`)
  }
  try {
    ensureTmux()
    const session = sessionFromName(name)
    if (killSession(session)) console.log(`stopped session ${session}`)
  } catch {
    // tmux absent: nothing to stop
  }
}

async function cmdList(c) {
  const hosts = await c.proxyHosts.list({ expand: ['certificate'] })
  if (!hosts.length) {
    console.log('no proxy hosts')
    return
  }
  for (const h of hosts) {
    const names = (h.domain_names || []).join(', ')
    const certName = h.certificate ? h.certificate.domain_names?.join(', ') || h.certificate.name || `#${h.certificate.id}` : 'none'
    const state = h.enabled === false ? 'disabled' : 'enabled'
    console.log(
      `#${String(h.id).padEnd(4)} ${names.padEnd(38)} -> http://${h.forward_host}:${h.forward_port}  [${state}] cert(${certName})`,
    )
  }
}

async function cmdCerts(c) {
  const certs = await c.certificates.list()
  if (!certs.length) {
    console.log('no certificates')
    return
  }
  for (const cert of certs) {
    const names = (cert.domain_names || cert.domains || []).join(', ')
    console.log(`#${String(cert.id).padEnd(4)} ${names}`)
  }
}

const commands = {
  up: cmdUp,
  down: cmdDown,
  status: cmdStatus,
  add: cmdAdd,
  remove: cmdRemove,
  list: cmdList,
  certs: cmdCerts,
}

const [cmd, ...rest] = process.argv.slice(2)
const fn = commands[cmd]
if (!fn) {
  console.error(`Unknown command "${cmd}". Use one of: ${Object.keys(commands).join(', ')}`)
  process.exit(1)
}

let c
try {
  if (BACKEND === 'npm') {
    c = cmd === 'down' || (cmd === 'up' && parseUpArgs(rest).noRoute) ? null : client()
    await fn(c, rest)
  } else if (BACKEND === 'apophis') {
    const api = apophis(FORWARD_HOST, env('PREVIEW_INTERNAL_TOKEN'))
    if (cmd === 'up') {
      const { name: input, port, cwd, command, noRoute } = parseUpArgs(rest)
      const name = previewName(input)
      ensureTmux()
      const session = sessionFromName(name)
      if (hasSession(session)) throw new Error(`Session ${session} already exists; run down first`)
      mkdirSync(LOG_DIR, { recursive: true })
      const logFile = join(LOG_DIR, `${session}.log`)
      const shell = `PORT=${port} ${command.map(shellQuote).join(' ')} 2>&1 | tee ${shellQuote(logFile)}`
      tmux(['new-session', '-d', '-s', session, '-c', cwd, shell])
      try {
        console.log(noRoute ? 'Started without a route (--no-route)' : `Live at ${api.add(name, port)}`)
        console.log(`Session: ${session}\nLog: ${logFile}`)
      } catch (error) {
        killSession(session)
        throw error
      }
    } else if (cmd === 'down' || cmd === 'remove') {
      if (!rest[0]) throw new Error(`Usage: npm run ${cmd} -- <name>`)
      const name = previewName(rest[0])
      // Stop the backend even if the registry is temporarily unreachable.
      const stopped = killSession(sessionFromName(name))
      console.log(stopped ? `Stopped ${name}` : `No running session for ${name}`)
      console.log(api.remove(name) ? `Removed ${name} route` : `No active ${name} route`)
    } else if (cmd === 'add') {
      if (!rest[0] || !rest[1]) throw new Error('Usage: npm run add -- <name> <port>')
      console.log(`Live at ${api.add(rest[0], parsePort(rest[1]))}`)
    } else if (cmd === 'list' || cmd === 'status') {
      const routes = api.list()
      if (cmd === 'list') {
        if (!routes.length) console.log('No active internal previews')
        for (const { url, ip, port } of routes) console.log(`${url} -> ${ip}:${port}`)
      } else {
        const sessions = listSessions()
        if (!sessions.length) console.log('No running dev-proxy sessions')
        for (const session of sessions) {
          const name = session.slice('devproxy-'.length)
          const route = routes.find((r) => r.name === name && r.ip === FORWARD_HOST)
          console.log(`${session}: ${route?.url || '(no route)'}`)
        }
      }
    } else {
      console.log('Apophis manages wildcard TLS centrally. Use PREVIEW_BACKEND=npm npm run certs for legacy certificates.')
    }
  } else {
    throw new Error('PREVIEW_BACKEND must be apophis or npm')
  }
} catch (error) {
  console.error(error.message)
  process.exitCode = 1
} finally {
  c?.clearCredentials?.()
}
