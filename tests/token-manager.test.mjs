import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import vm from 'node:vm';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

async function runtime() {
  const source = await readFile('server/token-manager.js', 'utf8');
  const registered = {};
  const files = new Map();
  let command;
  const logs = [];
  const context = {
    require: () => crypto,
    GetCurrentResourceName: () => 'web-connect',
    LoadResourceFile: (_, name) => files.get(name) || null,
    SaveResourceFile: (_, name, data) => (files.set(name, data), true),
    RegisterCommand: (_, callback, restricted) => { command = callback; assert.equal(restricted, true); },
    exports: (name, callback) => { registered[name] = callback; },
    emitNet: () => {},
    console: { log: (message) => logs.push(message), error: (message) => logs.push(message) },
    Buffer,
    Date,
  };
  vm.runInNewContext(source, context);
  return { registered, files, logs, run: (...args) => command(0, args, '') };
}

test('creates, authenticates, lists, and revokes hashed tokens', async () => {
  const app = await runtime();
  app.run('create', 'website', 'event:announcement');
  const saved = JSON.parse(app.files.get('data/tokens.json'));
  assert.equal(saved.tokens.length, 1);
  assert.equal(saved.tokens[0].name, 'website');
  assert.equal(saved.tokens[0].scopes[0], 'event:announcement');
  assert.equal('token' in saved.tokens[0], false);
  assert.equal('hash' in saved.tokens[0], true);
  const secret = app.logs[0].split('Copy it now: ')[1];
  const principal = app.registered.AuthenticateBearer(secret);
  assert.equal(principal.name, 'website');
  assert.equal(app.registered.AuthenticateBearer('wrong'), null);
  app.run('revoke', 'website');
  assert.equal(app.registered.HasBearerTokens(), false);
});
