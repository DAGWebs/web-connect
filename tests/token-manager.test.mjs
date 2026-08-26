import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import vm from 'node:vm';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

async function runtime(seed) {
  const source = await readFile('server/token-manager.js', 'utf8');
  const registered = {};
  const files = new Map();
  if (seed) files.set('data/tokens.json', JSON.stringify(seed));
  const logs = [];
  const chat = [];
  const audit = [];
  let command;
  const context = {
    require: () => crypto,
    GetCurrentResourceName: () => 'web-connect',
    GetPlayerName: (id) => `Player${id}`,
    LoadResourceFile: (_, name) => files.get(name) || null,
    SaveResourceFile: (_, name, data) => (files.set(name, data), true),
    RegisterCommand: (_, callback, restricted) => { command = callback; assert.equal(restricted, true); },
    exports: (name, callback) => { registered[name] = callback; },
    emitNet: (event, target, payload) => chat.push({ event, target, payload }),
    emit: (event, payload) => audit.push({ event, payload }),
    console: { log: (message) => logs.push(message), error: (message) => logs.push(message) },
    Buffer,
    Date,
  };
  vm.runInNewContext(source, context);
  const run = (source_, ...args) => command(source_, args, '');
  return {
    registered,
    files,
    logs,
    chat,
    audit,
    run: (...args) => run(0, ...args),
    runAs: run,
    saved: () => JSON.parse(files.get('data/tokens.json')),
    secretFrom: (line) => logs[line].split('Copy it now: ')[1],
  };
}

test('creates, authenticates, lists, and revokes hashed tokens', async () => {
  const app = await runtime();
  app.run('create', 'website', 'event:announcement');
  const saved = app.saved();
  assert.equal(saved.tokens.length, 1);
  assert.equal(saved.tokens[0].name, 'website');
  assert.equal(saved.tokens[0].scopes[0], 'event:announcement');
  assert.equal('token' in saved.tokens[0], false);
  assert.equal('hash' in saved.tokens[0], true);

  const secret = app.secretFrom(0);
  const principal = app.registered.AuthenticateBearer(secret);
  assert.equal(principal.name, 'website');
  assert.equal(app.registered.AuthenticateBearer('wrong'), null);

  app.run('revoke', 'website');
  assert.equal(app.registered.HasBearerTokens(), false);
});

test('the default scope is one the API actually grants', async () => {
  const app = await runtime();
  app.run('create', 'website');
  // `events:*` never matched the `event:<name>` scopes the router requires, so
  // a token created with the default authorised nothing.
  assert.deepEqual(app.saved().tokens[0].scopes, ['event:*', 'action:execute']);
});

test('an expired token stops authenticating after a restart', async () => {
  const app = await runtime();
  app.run('create', 'temporary', 'event:*', '1');
  const secret = app.secretFrom(0);
  assert.ok(app.registered.AuthenticateBearer(secret), 'valid while unexpired');

  const stored = app.saved();
  stored.tokens[0].expiresAt = new Date(Date.now() - 1000).toISOString();

  // Tokens are read at load time, so a restart is the way to observe expiry.
  const restarted = await runtime(stored);
  assert.equal(restarted.registered.HasBearerTokens(), true, 'the record is still stored');
  assert.equal(restarted.registered.AuthenticateBearer(secret), null, 'but no longer authenticates');
});

test('last use is recorded in memory and written back on flush', async () => {
  const app = await runtime();
  app.run('create', 'website', 'event:*');
  const secret = app.secretFrom(0);
  const beforeUse = app.saved();
  assert.equal(beforeUse.tokens[0].lastUsedAt, undefined);

  app.registered.AuthenticateBearer(secret);
  assert.equal(app.saved().tokens[0].lastUsedAt, undefined, 'not written per request');

  app.registered.FlushTokenUsage();
  assert.match(app.saved().tokens[0].lastUsedAt, /^\d{4}-\d{2}-\d{2}T/);
});

test('the secret goes to the console, never through chat', async () => {
  const app = await runtime();
  app.runAs(12, 'create', 'website', 'event:*');
  const secret = app.secretFrom(0);

  assert.ok(secret, 'the console received the secret');
  assert.equal(app.chat.length, 1, 'the player got one message');
  const chatText = JSON.stringify(app.chat[0].payload);
  assert.ok(!chatText.includes(secret.trim()), 'the chat message does not contain the secret');
  assert.match(chatText, /server console/);
});

test('token management is audited with the acting administrator', async () => {
  const app = await runtime();
  app.runAs(12, 'create', 'website', 'event:*');
  const entry = app.audit.find((item) => item.payload.action === 'token:create');
  assert.equal(entry.payload.actor.id, 'player:12');
  assert.equal(entry.payload.actor.name, 'Player12');
});
