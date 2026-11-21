import { spawnSync } from 'node:child_process'

const domain = 'dev.misery.systems'
export const externalDomain = 'preview.external.misery.systems'
const endpoint = 'https://preview-api.internal.misery.systems/v1/routes'
const helper = 'sudo -n /usr/local/bin/apophis-preview-publish'

export function apophisPublishHelper(data) {
  const result = spawnSync('/usr/bin/ssh', ['-T', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=5',
    '-o', 'StrictHostKeyChecking=yes', 'ag@10.0.0.50', data ? helper : `${helper} --check`], {
    input: data ? JSON.stringify(data) : '', encoding: 'utf8', timeout: 15000,
  })
  if (result.status !== 0) throw new Error('Could not run the Apophis publishing helper over SSH')
  let body
  try { body = JSON.parse(result.stdout) } catch { throw new Error('Unexpected Apophis publishing helper response') }
  if (body.status) throw apiError(body.status, 'external')
  return body
}

function apiError(code, scope) {
  if (code === 409) return new Error('Preview name already registered or route limit reached; check the preview dashboard')
  if (code === 403 && scope === 'external') return new Error('The backend is not approved for external previews; check the Apophis allowlist')
  return new Error(`Apophis preview API returned HTTP ${code}`)
}

export function previewName(input) {
  const name = input.endsWith(`.${domain}`) ? input.slice(0, -domain.length - 1) : input
  if (!/^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/.test(name) || name === 'preview-api') {
    throw new Error(`Use a preview label (lowercase letters, digits, hyphens) or a .${domain} hostname`)
  }
  return name
}

export function apophis(ip, internalToken, externalToken) {
  function request(method, path = '', data, scope = 'internal') {
    const args = ['-q', '--silent', '--show-error', '--noproxy', '*', '--max-time', '10',
      '--request', method, '--write-out', '\n%{http_code}']
    let input
    if (method !== 'GET') {
      const token = scope === 'external' ? externalToken : internalToken
      if (!/^[A-Za-z0-9_-]{32,128}$/.test(token || '')) {
        throw new Error(scope === 'external'
          ? 'Configure PREVIEW_EXTERNAL_TOKEN in the publishing runtime'
          : 'Set PREVIEW_INTERNAL_TOKEN in the ignored .env file')
      }
      args.push('--config', '-')
      input = `header = "Authorization: Bearer ${token}"\n`
    }
    if (data) args.push('--header', 'Content-Type: application/json', '--data-binary', JSON.stringify(data))
    const { PREVIEW_INTERNAL_TOKEN, PREVIEW_EXTERNAL_TOKEN, ...env } = process.env
    const result = spawnSync('/usr/bin/curl', [...args, `${endpoint}${path}`], { input, encoding: 'utf8', env })
    if (result.status !== 0) throw new Error('Could not reach the Apophis preview API over HTTPS')
    const split = result.stdout.lastIndexOf('\n')
    const code = Number(result.stdout.slice(split + 1))
    let body
    try { body = JSON.parse(result.stdout.slice(0, split)) } catch { /* empty response */ }
    if (code >= 200 && code < 300) return body
    throw apiError(code, scope)
  }

  const list = () => request('GET', '?scope=internal').routes
  return {
    list,
    add(input, port) {
      const name = previewName(input)
      return request('POST', '', { name, ip, port, scope: 'internal' }).url
    },
    publish(name, port, ttl) {
      const data = { name: previewName(name), ip, port, ttl_seconds: ttl }
      const result = externalToken
        ? request('POST', '', { ...data, scope: 'external' }, 'external')
        : apophisPublishHelper(data)
      if (result?.url !== `https://${name}.${externalDomain}/` || !Number.isSafeInteger(result.expires_at)) {
        throw new Error('Unexpected publish result; check the preview dashboard before retrying')
      }
      return { url: result.url, expiresAt: result.expires_at }
    },
    remove(input) {
      const name = previewName(input)
      const route = list().find((item) => item.name === name)
      if (!route) return false
      if (route.ip !== ip) throw new Error('Refusing to remove a preview targeting another host')
      request('DELETE', `/internal/${name}`)
      return true
    },
  }
}
