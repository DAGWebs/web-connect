import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

test('manifest loads dependencies before router', async () => {
  const manifest = await readFile('fxmanifest.lua', 'utf8');
  const modules = ['server/core/schema.lua', 'server/core/registry.lua', 'server/http/security.lua', 'server/http/openapi.lua', 'server/http/router.lua'];
  const positions = modules.map((name) => manifest.indexOf(name));
  assert.ok(positions.every((position) => position >= 0));
  assert.deepEqual(positions, [...positions].sort((a, b) => a - b));
});

test('OpenAPI and Scalar are exposed', async () => {
  const openapi = await readFile('server/http/openapi.lua', 'utf8');
  assert.match(openapi, /openapi = '3\.1\.0'/);
  assert.match(openapi, /@scalar\/api-reference/);
});

test('action engine is loaded before built-in action adapters', async () => {
  const manifest = await readFile('fxmanifest.lua', 'utf8');
  assert.ok(manifest.indexOf('server/core/actions.lua') < manifest.indexOf('server/integrations/actions.lua'));
  const actions = await readFile('server/integrations/actions.lua', 'utf8');
  assert.match(actions, /giveCash/);
  assert.match(actions, /giveItem/);
  assert.match(actions, /setJob/);
  assert.match(actions, /kick/);
  assert.match(actions, /giveCar|ActionConnectors/);
  assert.match(actions, /RegisterCommand\('connect'/);
});

test('HTTP action catalog is available to authenticated callers', async () => {
  const router = await readFile('server/http/router.lua', 'utf8');
  assert.match(router, /'\/actions'/);
  assert.match(router, /WebConnect\.ListActions/);
});

test('direct and batch API actions are audited', async () => {
  const router = await readFile('server/http/router.lua', 'utf8');
  const audit = await readFile('server/core/audit.lua', 'utf8');
  const actions = await readFile('server/integrations/actions.lua', 'utf8');
  assert.match(router, /ActionApiPrefix/);
  assert.match(router, /directAction:lower\(\) == 'batch'/);
  assert.match(router, /IdempotencyLookup/);
  assert.match(audit, /data\/audit\.json/);
  assert.match(actions, /subcommand == 'logs'/);
});
