import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { test } from 'node:test'
import { fileURLToPath } from 'node:url'

const cli = fileURLToPath(new URL('./cli.js', import.meta.url))
function run(args, input = '', nodeArgs = []) {
  return spawnSync(process.execPath, [...nodeArgs, cli, ...args], {
    env: { PREVIEW_HOST: '10.0.0.49', PREVIEW_EXTERNAL_TOKEN: 'e'.repeat(32) },
    encoding: 'utf8',
    input,
    timeout: 2000,
  })
}

test('publish rejects noninteractive confirmation even with the correct hostname', () => {
  const result = run(['publish', 'demo', '3007'], 'demo.preview.external.misery.systems\n')
  assert.equal(result.status, 1)
  assert.match(result.stderr, /requires --confirm with the exact external hostname/)
})

test('publish has no confirmation bypass flag', () => {
  const result = run(['publish', 'demo', '3007', '--yes'])
  assert.equal(result.status, 1)
  assert.match(result.stderr, /Usage:/)
})

test('publish rejects confirmation for a different preview', () => {
  const result = run(['publish', 'demo', '3007', '--confirm', 'other.preview.external.misery.systems'])
  assert.equal(result.status, 1)
  assert.match(result.stderr, /--confirm must match demo\.preview\.external\.misery\.systems/)
})

test('exact confirmation publishes a scoped seven-day route without printing credentials', () => {
  const mock = `
    import assert from 'node:assert/strict';
    import child from 'node:child_process';
    import { syncBuiltinESMExports } from 'node:module';
    child.spawnSync = (bin, args, options) => {
      assert.equal(bin, '/usr/bin/curl');
      assert.equal(args.at(-1), 'https://preview-api.internal.misery.systems/v1/routes');
      assert.deepEqual(JSON.parse(args[args.indexOf('--data-binary') + 1]), {
        name: 'demo', ip: '10.0.0.49', port: 3007, scope: 'external', ttl_seconds: 604800,
      });
      assert.ok(options.input.includes('Bearer ' + 'e'.repeat(32)));
      assert.ok(!options.env.PREVIEW_EXTERNAL_TOKEN);
      return { status: 0, stdout: JSON.stringify({ url: 'https://demo.preview.external.misery.systems/', expires_at: 604800, basic_auth: { password: 'example-private-password' } }) + '\\n201' };
    };
    syncBuiltinESMExports();
  `
  const result = run(['publish', 'demo', '3007', '--ttl', '604800', '--confirm', 'demo.preview.external.misery.systems'], '',
    [`--import=data:text/javascript,${encodeURIComponent(mock)}`])
  assert.equal(result.status, 0, result.stderr)
  assert.match(result.stdout, /Live at https:\/\/demo\.preview\.external\.misery\.systems\//)
  assert.doesNotMatch(result.stdout, /example-private-password/)
})

test('external options are rejected by internal add', () => {
  const result = run(['add', 'demo', '3007', '--external'])
  assert.equal(result.status, 1)
  assert.match(result.stderr, /internal only/)
})
