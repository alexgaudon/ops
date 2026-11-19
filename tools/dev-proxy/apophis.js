import { spawnSync } from 'node:child_process'

const domain = 'dev.misery.systems'
const endpoint = 'https://preview-api.internal.misery.systems/v1/routes'

export function previewName(input) {
  const name = input.endsWith(`.${domain}`) ? input.slice(0, -domain.length - 1) : input
  if (!/^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/.test(name) || name === 'preview-api') {
    throw new Error(`Use a preview label (lowercase letters, digits, hyphens) or a .${domain} hostname`)
  }
  return name
}

export function apophis(ip, token) {
  function request(method, path = '', data) {
    const args = ['-q', '--silent', '--show-error', '--noproxy', '*', '--max-time', '10',
      '--request', method, '--write-out', '\n%{http_code}']
    let input
    if (method !== 'GET') {
      if (!/^[A-Za-z0-9_-]{32,128}$/.test(token || '')) {
        throw new Error('Set PREVIEW_INTERNAL_TOKEN in the ignored .env file')
      }
      args.push('--config', '-')
      input = `header = "Authorization: Bearer ${token}"\n`
    }
    if (data) args.push('--header', 'Content-Type: application/json', '--data-binary', JSON.stringify(data))
    const result = spawnSync('/usr/bin/curl', [...args, `${endpoint}${path}`], { input, encoding: 'utf8' })
    if (result.status !== 0) throw new Error('Could not reach the Apophis preview API over HTTPS')
    const split = result.stdout.lastIndexOf('\n')
    const code = Number(result.stdout.slice(split + 1))
    let body
    try { body = JSON.parse(result.stdout.slice(0, split)) } catch { /* empty response */ }
    if (code >= 200 && code < 300) return body
    if (code === 409) throw new Error('Preview name already registered or route limit reached; use list to check')
    throw new Error(`Apophis preview API returned HTTP ${code}`)
  }

  const list = () => request('GET', '?scope=internal').routes
  return {
    list,
    add(input, port) {
      const name = previewName(input)
      return request('POST', '', { name, ip, port, scope: 'internal' }).url
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
