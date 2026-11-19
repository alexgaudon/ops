#!/usr/bin/env node
import { execFileSync } from 'node:child_process'
import { mkdirSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'
import { apophis, previewName } from './apophis.js'

const host = process.env.PREVIEW_HOST || '10.0.0.49'
const api = apophis(host, process.env.PREVIEW_INTERNAL_TOKEN)
const logDir = join(homedir(), '.dev-proxy', 'logs')
const quote = (value) => "'" + value.replaceAll("'", "'\\''") + "'"
const sessionName = (name) => `devproxy-${name}`

function tmux(args) {
  const { PREVIEW_INTERNAL_TOKEN, ...env } = process.env
  return execFileSync('tmux', args, { stdio: 'pipe', env })
}

function hasSession(session) {
  try {
    tmux(['has-session', '-t', `=${session}`])
    return true
  } catch {
    return false
  }
}

function killSession(session) {
  if (!hasSession(session)) return false
  tmux(['kill-session', '-t', `=${session}`])
  return true
}

function listSessions() {
  try {
    return tmux(['ls', '-F', '#{session_name}']).toString().split('\n')
      .filter((name) => name.startsWith('devproxy-'))
  } catch {
    return []
  }
}

function parsePort(raw) {
  const port = Number(raw)
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error(`Bad port: ${raw}`)
  return port
}

function up(args) {
  const separator = args.indexOf('--')
  if (separator < 2 || separator === args.length - 1) {
    throw new Error('Usage: npm run up -- <name> <port> [--cwd <dir>] [--no-route] -- <command...>')
  }
  const [input, rawPort, ...options] = args.slice(0, separator)
  const name = previewName(input)
  const port = parsePort(rawPort)
  let cwd = process.cwd()
  let noRoute = false
  for (let i = 0; i < options.length; i++) {
    const option = options[i]
    if (option === '--no-route') noRoute = true
    else if (option === '--cwd' && options[i + 1] && !options[i + 1].startsWith('--')) cwd = options[++i]
    else throw new Error(`Invalid option: ${option}`)
  }
  const command = args.slice(separator + 1)
  const session = sessionName(name)
  if (hasSession(session)) throw new Error(`Session ${session} already exists; run down first`)
  mkdirSync(logDir, { recursive: true })
  const logFile = join(logDir, `${session}.log`)
  const shell = `PORT=${port} ${command.map(quote).join(' ')} 2>&1 | tee ${quote(logFile)}`
  tmux(['new-session', '-d', '-s', session, '-c', cwd, shell])
  try {
    console.log(noRoute ? 'Started without a route (--no-route)' : `Live at ${api.add(name, port)}`)
    console.log(`Session: ${session}\nLog: ${logFile}`)
  } catch (error) {
    killSession(session)
    throw error
  }
}

const [cmd, ...args] = process.argv.slice(2)
try {
  if (cmd === 'up') {
    up(args)
  } else if (cmd === 'down' || cmd === 'remove') {
    if (!args[0]) throw new Error(`Usage: npm run ${cmd} -- <name>`)
    const name = previewName(args[0])
    const stopped = killSession(sessionName(name))
    console.log(stopped ? `Stopped ${name}` : `No running session for ${name}`)
    console.log(api.remove(name) ? `Removed ${name} route` : `No active ${name} route`)
  } else if (cmd === 'add') {
    if (!args[0] || !args[1]) throw new Error('Usage: npm run add -- <name> <port>')
    console.log(`Live at ${api.add(args[0], parsePort(args[1]))}`)
  } else if (cmd === 'list') {
    const routes = api.list()
    if (!routes.length) console.log('No active internal previews')
    for (const { url, ip, port } of routes) console.log(`${url} -> ${ip}:${port}`)
  } else if (cmd === 'status') {
    const routes = api.list()
    const sessions = listSessions()
    if (!sessions.length) console.log('No running dev-proxy sessions')
    for (const session of sessions) {
      const name = session.slice('devproxy-'.length)
      const route = routes.find((r) => r.name === name && r.ip === host)
      console.log(`${session}: ${route?.url || '(no route)'}`)
    }
  } else {
    throw new Error('Commands: up, down, add, remove, list, status')
  }
} catch (error) {
  console.error(error.message)
  process.exitCode = 1
}
