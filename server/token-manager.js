const { createHash, randomBytes, timingSafeEqual, randomUUID } = require('node:crypto');

const RESOURCE = GetCurrentResourceName();
const TOKEN_FILE = 'data/tokens.json';
let tokens = loadTokens();

function loadTokens() {
  const contents = LoadResourceFile(RESOURCE, TOKEN_FILE);
  if (!contents) return [];
  try {
    const data = JSON.parse(contents);
    return Array.isArray(data.tokens) ? data.tokens : [];
  } catch (error) {
    console.error(`[${RESOURCE}] Could not read ${TOKEN_FILE}: ${error.message}`);
    return [];
  }
}

function persist() {
  const document = JSON.stringify({ version: 1, tokens }, null, 2);
  if (!SaveResourceFile(RESOURCE, TOKEN_FILE, document, Buffer.byteLength(document))) {
    throw new Error(`Unable to write ${TOKEN_FILE}`);
  }
}

function digest(value) {
  return createHash('sha256').update(value).digest('hex');
}

function authenticate(value) {
  const candidate = Buffer.from(digest(value), 'hex');
  const record = tokens.find((item) => {
    const stored = Buffer.from(item.hash, 'hex');
    return stored.length === candidate.length && timingSafeEqual(stored, candidate);
  });
  if (!record || (record.expiresAt && Date.parse(record.expiresAt) <= Date.now())) return null;
  record.lastUsedAt = new Date().toISOString();
  return { id: record.id, name: record.name, scopes: record.scopes };
}

function reply(source, message) {
  if (source === 0) return console.log(`[${RESOURCE}] ${message}`);
  emitNet('chat:addMessage', source, { color: [255, 180, 0], args: ['WEB CONNECT', message] });
}

exports('AuthenticateBearer', authenticate);
exports('HasBearerTokens', () => tokens.length > 0);

RegisterCommand('webconnect_token', (source, args) => {
  const action = (args.shift() || '').toLowerCase();
  try {
    if (action === 'create' || action === 'generate') {
      const name = args.shift() || 'default';
      const scopes = (args.shift() || 'events:*').split(',').filter(Boolean);
      const lifetimeDays = Number(args.shift() || 0);
      const secret = randomBytes(32).toString('base64url');
      const expiresAt = lifetimeDays > 0
        ? new Date(Date.now() + lifetimeDays * 86400000).toISOString()
        : null;
      tokens.push({ id: randomUUID(), name, hash: digest(secret), scopes, createdAt: new Date().toISOString(), expiresAt });
      persist();
      reply(source, `Token created for "${name}" with scopes [${scopes.join(', ')}]. Copy it now: ${secret}`);
      return;
    }
    if (action === 'list') {
      if (!tokens.length) return reply(source, 'No saved API tokens.');
      tokens.forEach((token) => reply(source, `${token.id} | ${token.name} | ${token.scopes.join(', ')}`));
      return;
    }
    if (action === 'revoke') {
      const id = args.shift();
      const previousLength = tokens.length;
      tokens = tokens.filter((token) => token.id !== id && token.name !== id);
      if (tokens.length === previousLength) return reply(source, 'Token not found.');
      persist();
      reply(source, `Revoked token ${id}.`);
      return;
    }
    reply(source, 'Usage: /webconnect_token create <name> [scope,scope] [lifetime-days] | list | revoke <id-or-name>');
  } catch (error) {
    reply(source, error.message);
  }
}, true);
