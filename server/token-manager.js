const { createHash, randomBytes, timingSafeEqual, randomUUID } = require('node:crypto');

const RESOURCE = GetCurrentResourceName();
const TOKEN_FILE = 'data/tokens.json';
const USAGE_FLUSH_INTERVAL_MS = 30000;
let usageDirty = false;
let tokens = loadTokens();

function isExpired(token) {
  return Boolean(token.expiresAt) && Date.parse(token.expiresAt) <= Date.now();
}

function loadTokens() {
  const contents = LoadResourceFile(RESOURCE, TOKEN_FILE);
  if (!contents) return [];
  try {
    const data = JSON.parse(contents);
    if (!Array.isArray(data.tokens)) return [];
    // Expired credentials are dropped at load so the file does not accumulate
    // dead records that still have to be compared against on every request.
    const live = data.tokens.filter((token) => !isExpired(token));
    if (live.length !== data.tokens.length) {
      console.log(`[${RESOURCE}] Removed ${data.tokens.length - live.length} expired token(s).`);
      usageDirty = true;
    }
    return live;
  } catch (error) {
    console.error(`[${RESOURCE}] Could not read ${TOKEN_FILE}: ${error.message}`);
    return [];
  }
}

function persist() {
  usageDirty = false;
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
  // Every record is compared, so how long the lookup takes does not reveal where
  // in the file a matching credential sits.
  let record = null;
  for (const item of tokens) {
    const stored = Buffer.from(item.hash, 'hex');
    if (stored.length === candidate.length && timingSafeEqual(stored, candidate)) record = item;
  }
  if (!record || isExpired(record)) return null;
  // Written back on a timer: persisting here would put a disk write on every
  // authenticated API request.
  record.lastUsedAt = new Date().toISOString();
  usageDirty = true;
  return { id: record.id, name: record.name, scopes: record.scopes };
}

function flushUsage() {
  if (usageDirty) persist();
}

if (typeof setInterval === 'function') {
  setInterval(flushUsage, USAGE_FLUSH_INTERVAL_MS);
}

function reply(source, message) {
  if (source === 0) return console.log(`[${RESOURCE}] ${message}`);
  emitNet('chat:addMessage', source, { color: [255, 180, 0], args: ['WEB CONNECT', message] });
}

// The secret always goes to the server console. Chat messages pass through the
// chat resource, where other scripts routinely log or echo them.
function revealSecret(source, name, scopes, secret) {
  console.log(`[${RESOURCE}] Token created for "${name}" with scopes [${scopes.join(', ')}]. Copy it now: ${secret}`);
  if (source !== 0) {
    reply(source, `Token created for "${name}" with scopes [${scopes.join(', ')}]. The secret was written to the server console.`);
  }
}

function actorFor(source) {
  return source === 0
    ? { id: 'console', name: 'console' }
    : { id: `player:${source}`, name: GetPlayerName(source) || `player:${source}` };
}

exports('AuthenticateBearer', authenticate);
exports('HasBearerTokens', () => tokens.length > 0);
exports('FlushTokenUsage', flushUsage);

RegisterCommand('webconnect_token', (source, args) => {
  const action = (args.shift() || '').toLowerCase();
  try {
    if (action === 'create' || action === 'generate') {
      const name = args.shift() || 'default';
      const scopes = (args.shift() || 'event:*,action:execute').split(',').filter(Boolean);
      const lifetimeDays = Number(args.shift() || 0);
      const secret = randomBytes(32).toString('base64url');
      const expiresAt = lifetimeDays > 0
        ? new Date(Date.now() + lifetimeDays * 86400000).toISOString()
        : null;
      tokens.push({ id: randomUUID(), name, hash: digest(secret), scopes, createdAt: new Date().toISOString(), expiresAt });
      persist();
      emit('web-connect:recordAudit', { action: 'token:create', actor: actorFor(source), status: 200 });
      revealSecret(source, name, scopes, secret);
      return;
    }
    if (action === 'list') {
      emit('web-connect:recordAudit', { action: 'token:list', actor: actorFor(source), status: 200 });
      if (!tokens.length) return reply(source, 'No saved API tokens.');
      tokens.forEach((token) => reply(
        source,
        `${token.id} | ${token.name} | ${token.scopes.join(', ')} | last used ${token.lastUsedAt || 'never'}`
      ));
      return;
    }
    if (action === 'revoke') {
      const id = args.shift();
      const previousLength = tokens.length;
      tokens = tokens.filter((token) => token.id !== id && token.name !== id);
      if (tokens.length === previousLength) return reply(source, 'Token not found.');
      persist();
      emit('web-connect:recordAudit', { action: 'token:revoke', actor: actorFor(source), status: 200 });
      reply(source, `Revoked token ${id}.`);
      return;
    }
    reply(source, 'Usage: /webconnect_token create <name> [scope,scope] [lifetime-days] | list | revoke <id-or-name>');
  } catch (error) {
    reply(source, error.message);
  }
}, true);
