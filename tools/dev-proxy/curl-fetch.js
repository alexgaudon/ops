// curl-fetch: a drop-in fetch() replacement that shells out to /usr/bin/curl.
//
// Why: macOS Local Network privacy blocks ad-hoc signed binaries from reaching
// other hosts on the LAN. Node (Homebrew, vite-plus, npx installed builds) is
// ad-hoc signed, so fetch() to 10.0.0.20 fails instantly with EHOSTUNREACH while
// Apple-signed /usr/bin/curl on the same machine works. Running the CLI as root
// also works, but that should not be necessary for a dev tool.
//
// Implementing fetch on top of curl keeps the NPM SDK (payload building, token
// exchange, retries, error handling) exactly as it is.

import { execFile } from 'node:child_process'

const CURL = '/usr/bin/curl'
const STATUS_MARKER = '\n__CURL_FETCH_STATUS__:'
const MAX_BUFFER = 32 * 1024 * 1024

function abortError() {
  const err = new Error('This operation was aborted')
  err.name = 'AbortError'
  return err
}

function headerArgs(headers = {}) {
  const args = []
  const entries = headers instanceof Map ? headers.entries() : Object.entries(headers)
  for (const [name, value] of entries) {
    if (value === undefined || value === null) continue
    args.push('-H', `${name}: ${value}`)
  }
  return args
}

/**
 * fetch()-compatible function backed by curl. Supports method, headers, body and
 * an AbortSignal. Returns a minimal Response-like object: ok, status, text(),
 * json().
 */
export function curlFetch(url, init = {}) {
  const { method = 'GET', headers, body, signal } = init

  if (signal?.aborted) return Promise.reject(abortError())

  const args = [
    '-sS',
    '--no-progress-meter',
    '--max-time',
    '60',
    '-X',
    method,
    '-w',
    `${STATUS_MARKER}%{http_code}`,
    ...headerArgs(headers),
  ]

  if (body !== undefined && body !== null) {
    args.push('--data-binary', typeof body === 'string' ? body : String(body))
  }
  args.push(String(url))

  return new Promise((resolve, reject) => {
    const child = execFile(CURL, args, { maxBuffer: MAX_BUFFER, signal }, (error, stdout, stderr) => {
      if (error) {
        if (error.name === 'AbortError' || signal?.aborted) return reject(abortError())
        const detail = (stderr || error.message || '').trim()
        return reject(new Error(`curl failed for ${method} ${url}: ${detail}`))
      }

      const index = stdout.lastIndexOf(STATUS_MARKER)
      if (index === -1) {
        return reject(new Error(`curl returned no status for ${method} ${url}`))
      }

      const status = Number(stdout.slice(index + STATUS_MARKER.length))
      const text = stdout.slice(0, index)

      resolve({
        ok: status >= 200 && status < 300,
        status,
        statusText: '',
        url: String(url),
        text: async () => text,
        json: async () => JSON.parse(text),
      })
    })

    child.stderr?.on('data', () => {})
  })
}

/** Route all SDK requests through curl. Call once at startup. */
export function installCurlFetch() {
  globalThis.fetch = curlFetch
}
