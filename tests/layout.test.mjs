import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

// Load order is a property of the manifest itself, so it is checked statically.
// Everything else about these modules is covered by tests/lua/spec.lua.
test('the manifest loads every module in dependency order', async () => {
  const manifest = await readFile('fxmanifest.lua', 'utf8');
  const order = [
    'server/core/namespace.lua',
    'server/core/schema.lua',
    'server/integrations/framework.lua',
    'server/core/registry.lua',
    'server/core/audit.lua',
    'server/core/actions.lua',
    'server/integrations/website.lua',
    'server/integrations/actions.lua',
    'server/http/security.lua',
    'server/http/request.lua',
    'server/http/openapi.lua',
    'server/http/router.lua',
  ];
  const positions = order.map((name) => manifest.indexOf(name));
  assert.ok(positions.every((position) => position >= 0), 'every module is listed');
  assert.deepEqual(positions, [...positions].sort((a, b) => a - b));
});

test('config.lua is loaded before the modules that read it', async () => {
  const manifest = await readFile('fxmanifest.lua', 'utf8');
  assert.ok(manifest.indexOf('config.lua') < manifest.indexOf('server/core/registry.lua'));
});

test('the token store is never committed', async () => {
  const ignore = await readFile('.gitignore', 'utf8');
  assert.match(ignore, /^data\/tokens\.json$/m);
  assert.match(ignore, /^data\/audit\.json$/m);
});

test('the in-game website screen is wired into the manifest', async () => {
  const manifest = await readFile('fxmanifest.lua', 'utf8');
  assert.match(manifest, /ui_page 'html\/index\.html'/);
  for (const asset of ['html/index.html', 'html/style.css', 'html/app.js']) {
    assert.ok(manifest.includes(asset), `${asset} is listed in files`);
    await readFile(asset, 'utf8');
  }
  assert.match(manifest, /client_scripts/);
  await readFile('client/website.lua', 'utf8');
  // The client script would never load while the resource declares server_only.
  assert.ok(!manifest.includes('server_only'), 'server_only is not set');
});
