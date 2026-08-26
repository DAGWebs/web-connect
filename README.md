# web-connect

`web-connect` is a small, framework-independent FiveM resource that exposes an
authenticated HTTP endpoint to a website and turns accepted requests into
allow-listed **server-side** events.

It supports standalone FiveM, ESX, QBCore/QBus, Qbox, and vRP. Framework
auto-detection is enabled by default, while the HTTP API remains identical for
every framework.

## Project structure

```text
config.lua                     Server-owner configuration
server/core/namespace.lua      Shared namespace and logging
server/core/registry.lua       Integration registration and dispatch
server/core/schema.lua         Request schema validation
server/core/actions.lua        Colon action parsing and action registry
server/core/audit.lua          Persistent admin-visible command audit
server/http/request.lua        Request body and JSON parsing
server/http/response.lua       JSON response formatting
server/http/security.lua       Authentication and rate limiting
server/http/idempotency.lua    Duplicate-request protection
server/http/openapi.lua        Live OpenAPI schema and Scalar page
server/http/router.lua         HTTP routes only
server/integrations/framework.lua  Framework detection and normalized exports
server/integrations/builtins.lua   Included announcement/notification handlers
server/integrations/actions.lua    Money, commands, and configured connectors
server/integrations/website.lua    In-game website screen and link codes
client/website.lua                 NUI control for the website screen
html/                              The in-game website screen
server/init.lua                Startup checks
server/token-manager.js        Secure token generation and persistence
data/                          Runtime token storage (secret is git-ignored)
examples/                      Copyable integration examples
tests/lua/harness.lua          FiveM natives stubbed for tests
tests/lua/spec.lua             Behavioural tests for the Lua resource
tests/*.test.mjs               Node test runner entry points
```

The manifest lists modules explicitly in dependency order. HTTP concerns,
integration concerns, and core registration state are kept separate so new
features do not require growing a single server file.

## Install

1. Put this directory in your server's `resources` directory.
2. Generate a strong token (for example, `openssl rand -hex 32`).
3. Add the following to `server.cfg`:

   ```cfg
   set web_connect_token "replace-with-your-random-token"
   ensure web-connect
   ```

4. Keep the FiveM HTTP endpoint behind HTTPS (a reverse proxy is recommended),
   and restrict it by firewall/IP allow-list where possible. Never place the API
   token in browser JavaScript; make requests from your website's backend.

## Generate and save a bearer token

From the server console, run:

```text
webconnect_token create website event:*,action:execute
```

An authorized administrator can also run `/webconnect_token create website event:*,action:execute`
in game.
Grant access to the restricted command in `server.cfg`:

```cfg
add_ace group.admin command.webconnect_token allow
```

The command uses Node's cryptographic random generator to create a 256-bit token,
stores only its SHA-256 hash in `data/tokens.json`, and prints the secret once, to
the **server console**. Chat messages pass through the chat resource, where other
scripts routinely log or echo them, so an administrator who runs the command in
game is told to read the secret from the console. The file is git-ignored; protect
it like any credential database and include it in secure backups.

Create narrowly scoped credentials for separate integrations, then list or revoke
them without affecting other callers:

```text
webconnect_token create race-site event:start_race 90
webconnect_token create control-panel event:announcement,event:notify_player
webconnect_token list
webconnect_token revoke race-site
```

`list` shows each credential's id, name, scopes, and when it was last used. Last-use
timestamps are written back on a timer rather than on every request, so the value
can lag by up to thirty seconds.

Scopes are `event:<public-name>` for events and `action:execute` for the action
API. A trailing `*` grants everything below that prefix, so `event:*` covers every
registered event and `*` covers the whole API. Prefer individual
`event:<public-name>` scopes whenever possible.

`events:*` (plural) was previously documented as the grant-everything event scope
but never matched the singular `event:<name>` scopes the router requires, so
tokens created with it were rejected on every event route. It is now accepted as
an alias for `event:*`; existing tokens keep working, but new ones should use
`event:*`.

The `web_connect_token` convar remains supported as an unrestricted legacy key.
Remove it after migrating the website to scoped saved credentials.

## API

### Interactive Scalar documentation

Open `http://your-server:30120/web-connect/docs` to browse and try the API using
Scalar. The page reads a live OpenAPI 3.1 document from
`/web-connect/openapi.json`, so events registered by other resources appear in
the documentation automatically. Scalar's browser assets are loaded from its
jsDelivr package; self-host or proxy that package if game-server users cannot
access the public CDN.

### Health check

```http
GET /web-connect/health
```

The health route intentionally does not disclose players, configuration, or the
secret token.

### Trigger an event

```http
POST /web-connect/events/announcement
Authorization: Bearer <token>
Content-Type: application/json

{"message":"The race starts in five minutes!"}
```

An accepted request returns HTTP `202`. Invalid JSON, unknown events, missing
authentication, oversized bodies, and rate-limit violations are rejected before
an event is emitted. Run the Node example with:

```bash
FIVEM_URL=http://127.0.0.1:30120 \
FIVEM_API_TOKEN=your-token node examples/send-event.mjs
```

### Notify one player

The built-in `notify_player` event chooses the correct client notification for
ESX, QBCore/QBus, or Qbox. Standalone and vRP installations fall back to the
standard FiveM chat resource.

```http
POST /web-connect/events/notify_player
Authorization: Bearer <token>
Content-Type: application/json

{"playerId":42,"message":"Your event is ready!","type":"success","duration":5000}
```

`playerId` is a current server ID, not a database ID. Messages are limited to 500
bytes by the included handler.

### Run a base action

The `execute_action` endpoint provides short, allow-listed action strings while
keeping the target player separate from the action arguments:

```http
POST /web-connect/events/execute_action
Authorization: Bearer <token with action:execute>
Content-Type: application/json
Idempotency-Key: store-order-1827

{"playerId":42,"action":"connect:giveCash:1000"}
```

Included framework actions are `giveCash`, `giveMoney` (cash alias), `giveBank`,
and `giveCrypto`. Money is passed through the detected ESX, QBCore/QBus, Qbox, or
vRP adapter and is capped by `Config.MaxMoneyAction`. Standalone servers must
register their own money action because FiveM has no standard economy.

Authorized administrators can run the same actions in game or console:

```text
/connect 42 giveCash 1000
/connect 42 giveCar adder
```

Run `/connect help` or `/connect list` to print every currently registered action,
its arguments, and its description. Websites can retrieve the same live catalog
with authenticated `GET /web-connect/actions` using the `action:execute` scope.

Run `/connect logs` or `/connect logs 50` to view recent audit entries in game.
The ACE-restricted command shows the timestamp, API credential or administrator,
target player, action, HTTP-style status, and error. Logs are capped and persisted
to the git-ignored `data/audit.json`; every action, failed action, token-management
operation, and log/list access also emits `web-connect:audit` for external logging.
Entries are held in memory and flushed to disk every five seconds and on resource
stop, so a busy API does not put a synchronous write on the main thread per request.
Call `exports['web-connect']:FlushAudit()` to force a write.

Common actions included by default:

| Command | Result |
| --- | --- |
| `/connect 42 giveCash 1000` | Adds framework cash |
| `/connect 42 giveBank 1000` | Adds framework bank money |
| `/connect 42 giveCrypto 100` | Adds framework crypto where supported |
| `/connect 42 giveItem lockpick 2` | Adds an inventory item where supported |
| `/connect 42 setJob police 2` | Sets the framework job and grade |
| `/connect 42 notify Welcome` | Shows a framework-aware notification |
| `/connect 42 giveCar adder` | Runs the configured garage connector |
| `/connect 42 kick Maintenance` | Disconnects the player with a reason |

Economy, inventory, and job actions return an explicit `*_not_supported` error
when the selected framework lacks a compatible operation — including on standalone,
where there is no economy at all. If the player is online but the framework has not
finished loading their record, the error is `player_not_loaded`; `player_not_found`
means the server ID is not connected. Configure or register a custom action rather
than silently changing a database table.

Grant the restricted command with:

```cfg
add_ace group.admin command.connect allow
```

The player must be online and `42` is their current server ID. The command and
HTTP endpoint use the same parser and action registry.

## Open the website in game

`/connect` on its own opens the server website for the player who ran it. Set the
address first:

```lua
Config.Website = {
    Enabled = true,
    Url = 'https://your-server.example',
    Title = 'Server Website',
    Mode = 'tablet'
}
```

`tablet` mode renders the site on an in-game screen; Escape or the close button
dismisses it, and a **Copy link** button puts the address on the player's
clipboard. `chat` mode skips the screen and prints the link instead.

**Your site must allow being framed.** A page served with `X-Frame-Options: DENY`
or a restrictive `Content-Security-Policy: frame-ancestors` will not render in the
tablet — the screen detects this and offers the link to copy instead. Either allow
framing for the page you point `/connect` at, or use `Mode = 'chat'`. FiveM has no
native for opening the player's external browser, which is why copying the link is
the fallback rather than launching one.

A player may also open a specific page with `/connect store`, and the website can
push a page to someone in game:

```http
POST /api/openwebsite
Authorization: Bearer <token with action:execute>
Content-Type: application/json

{"playerId":42,"arguments":["/store"]}
```

The path is joined to `Config.Website.Url`, and anything carrying a scheme, an
authority, or a `..` escape is refused with `invalid_path`. A caller chooses a page
on your site; it can never point the in-game browser somewhere else.

### Sharing the command with administrators

`/connect` cannot be ACE restricted while every player needs to run it, so the
administrator subcommands check `command.connect` individually instead:
`/connect <playerId> <action>`, `/connect list`, and `/connect logs` still require
the ACE, and a player without it is told so. The `add_ace` line above is unchanged.

If you would rather keep `/connect` entirely to administrators, give the website
its own command:

```lua
Config.Website.Command = 'website'   -- players run /website
```

`/connect` is then registered restricted exactly as before. Setting
`Config.Website.Enabled = false` does the same.

### Signing the player in

With `Config.Website.LinkCode = true`, the opened URL carries a single-use
`?code=` that identifies the player who ran the command. Your site redeems it from
its backend:

```http
POST /web-connect/events/redeem_link
Authorization: Bearer <token with action:execute>
Content-Type: application/json

{"code":"K7RQ2M..."}
```

```json
{"data":{"playerId":42,"name":"Jane","identifiers":{"license":"license:...","steam":"steam:..."},"online":true}}
```

Codes expire after `LinkCodeTtlSeconds` (five minutes by default) and are consumed
on first use, so a code caught in a browser history or a referrer header is already
spent. Redeem it from your backend, never from browser JavaScript — the request
needs an API token. The feature is off by default; leave it off unless your site
implements the exchange.

### Direct and batch action API

Every registered action is also available as a direct endpoint. The URL selects
an allow-listed action; callers can never provide a resource export or event name:

```http
POST /api/givecar
Authorization: Bearer <token with action:execute>
Content-Type: application/json

{"playerId":42,"arguments":["adder"]}
```

Money and item examples use the same format:

```json
{"playerId":42,"arguments":[1000]}
```

Use `POST /api/batch` to connect multiple commands. A top-level `playerId` applies
to every command unless a command provides its own target:

```http
POST /api/batch
Authorization: Bearer <token with action:execute>
Content-Type: application/json
Idempotency-Key: purchase-8291

{
  "playerId": 42,
  "stopOnError": true,
  "commands": [
    {"name":"giveCar","arguments":["adder"]},
    {"name":"giveCash","arguments":[1000]},
    {"name":"giveItem","arguments":["phone",1]}
  ]
}
```

`batch` is a reserved action name so the endpoint cannot be shadowed; registering
an action called `batch` fails with `reserved_action_name`.

Commands may alternatively provide a full string such as
`{"action":"connect:giveBank:5000"}`. Batches execute sequentially and return
HTTP `207` when any command fails. They are not database transactions: an earlier
successful framework or paid-script operation cannot automatically be rolled back.
Keep `stopOnError` enabled for purchase/reward flows and use an idempotency key.

### Configure a paid or custom script

`Config.ActionConnectors` is an allow-list of adapters. The included VMS Garages
V2 example turns `connect:giveCar:adder` into:

```lua
exports['vms_garagesv2']:giveVehicle(source, playerId, 'vehicle', 'adder', plate)
```

It is declared without hard-coding VMS logic into the action engine:

```lua
{
    name = 'giveCar',
    resource = 'vms_garagesv2',
    export = 'giveVehicle',
    arguments = { '$source', '$playerId', 'vehicle', '$arg1', '$plate' }
}
```

Available placeholders are `$source`, `$playerId`, `$plate`, and `$arg1` through
`$arg9`. Literal values such as `vehicle` pass through unchanged. A request that
does not supply an argument the template references is rejected with
`missing_action_arguments`, so the target script is never called with a short
argument list. The default
connector calls a server export; set `kind = 'serverEvent'` or
`kind = 'clientEvent'` with an `event` field for scripts that expose events.

Never configure an export name or event name from an HTTP payload. Connector
targets must remain server-owned configuration so callers can invoke only the
actions you explicitly approve.

For more complicated integrations—including outfit systems or scripts needing
custom database work—register a handler from the resource that owns the script:

```lua
exports['web-connect']:RegisterAction({
    name = 'giveOutfit',
    description = 'Give a saved outfit from our clothing resource'
}, function(arguments, context)
    local outfitId = tonumber(arguments[1])
    if not outfitId then return { status = 422, error = 'invalid_outfit' } end

    local ok = exports['my_clothing']:giveOutfit(context.playerId, outfitId)
    if not ok then return { status = 409, error = 'outfit_not_given' } end
    return { status = 200, data = { outfitId = outfitId } }
end)
```

Client-only exports cannot be called by server Lua. Register a safe client event
inside an integration resource, call the client export there, and configure a
`clientEvent` connector. Validate all arguments again on the receiving client.

## Framework adapters

Set `Config.Framework` to `auto` (default), `standalone`, `esx`, `qbcore`,
`qbus`, `qbox`, or `vrp`. In auto mode, the resource detects running framework
resources and refreshes when one starts. Qbox is checked before QBCore because
Qbox servers can run QBCore compatibility resources.

Other server resources can use the normalized exports:

```lua
local framework = exports['web-connect']:GetFrameworkName()
local player = exports['web-connect']:GetPlayer(source)
local sent, reason = exports['web-connect']:Notify(source, 'Hello!', 'success', 5000)
```

`GetPlayer` returns `source`, `name`, normalized `identifiers`, `framework`, and
the native framework player object in `object`. On vRP it exposes the detected
`userId` in that object. Always check for `nil`, since players can disconnect at
any time.

## Add events safely

### Integrate from any server script

Any resource can register its own website-facing event at runtime. It does not
need to modify `web-connect`, know which framework is running, or be added to
`Config.Events`:

```lua
local ok, reason = exports['web-connect']:RegisterEvent(
    'tournament',
    'my-tournament:websiteStart'
)
assert(ok, reason)

AddEventHandler('my-tournament:websiteStart', function(payload, context)
    if type(payload.id) ~= 'string' or #payload.id > 50 then return end

    print(('Request came from %s through %s'):format(
        context.address,
        context.integration
    ))
    TriggerEvent('my-tournament:start', payload.id)
end)
```

Add `web-connect` as a dependency so registration happens after the bridge is
started:

```lua
-- fxmanifest.lua in my-tournament
dependency 'web-connect'
```

The website can now call `POST /web-connect/events/tournament`. Registrations are
owned by the calling resource, cannot overwrite another resource's route, and are
automatically removed when that resource stops. A resource can explicitly call
`UnregisterEvent(publicName)` and inspect `GetRegisteredEvents()` as well.

For scripts that prefer events over exports, trigger `web-connect:registerEvent`
or `web-connect:unregisterEvent`; an optional callback receives `success, reason`.
Every successful dispatch also emits `web-connect:eventDispatched` with the
public name, payload, and context, making logging, Discord, metrics, or audit
integrations easy to attach without changing event handlers.

`context` contains `address`, `apiEvent`, `framework`, and `integration` (the
resource that owns the route). Only registered names can be called. Treat every
payload as untrusted: validate types, lengths, identifiers, permissions, and game
state in every handler.

Static built-in routes can still be declared in `Config.Events`, which is useful
for simple server-specific mappings that do not own a separate resource.

### Typed handlers and API results

For new integrations, `RegisterHandler` adds schema validation, accurate OpenAPI
documentation, scoped authorization, timeouts, and a real HTTP result:

```lua
exports['web-connect']:RegisterHandler({
    name = 'start_race',
    summary = 'Start a configured race',
    scopes = { 'event:start_race' },
    timeout = 5000,
    schema = {
        type = 'object',
        required = { 'raceId' },
        additionalProperties = false,
        properties = {
            raceId = { type = 'string', minLength = 1, maxLength = 50 }
        }
    }
}, function(payload, context)
    local race = FindRace(payload.raceId)
    if not race then return { status = 404, error = 'race_not_found' } end
    StartRace(race)
    return { status = 200, data = { started = true, id = payload.raceId } }
end)
```

A handler may instead call the third `done(status, data, error)` argument later.
Requests time out automatically, and every response includes a `requestId` that
also appears in the handler context and `web-connect:requestCompleted` audit event.
For operations that must not run twice, send an `Idempotency-Key` header. Successful
responses are replayed and concurrent duplicates are rejected for five minutes. A
request that failed is not cached, so the same key can be retried once the caller
has corrected it. A partially successful batch (`207`) *is* cached, because some of
its commands did take effect.

## Configuration

| Setting | Default | Purpose |
| --- | --- | --- |
| `TokenConvar` | `web_connect_token` | Server convar containing the bearer token |
| `RoutePrefix` | `/web-connect` | Prefix for all routes |
| `Framework` | `auto` | Framework adapter or automatic detection |
| `MaxBodyBytes` | `65536` | Maximum JSON request size |
| `RequestTimeoutMs` | `10000` | Default typed-handler timeout |
| `DocsEnabled` | `true` | Serve OpenAPI and Scalar documentation |
| `ActionPrefix` | `connect` | Prefix accepted by action strings |
| `ActionApiPrefix` | `/api` | Prefix for direct and batch action endpoints |
| `MaxMoneyAction` | `1000000` | Maximum amount per built-in money action |
| `MaxItemAction` | `1000` | Maximum quantity per item action |
| `MaxBatchActions` | `10` | Maximum commands in one batch |
| `AuditMaxEntries` | `500` | Maximum persisted admin audit entries |
| `ActionConnectors` | VMS example | Allow-listed export/event adapters |
| `RateLimit.requests` | `120` | Requests per credential per window |
| `RateLimit.anonymousRequests` | `30` | Unauthenticated requests per address per window |
| `Website.Url` | unset | Site opened by `/connect` |
| `Website.Mode` | `tablet` | In-game screen, or `chat` to print the link |
| `Website.Command` | `connect` | Command players run to open the site |
| `Website.LinkCode` | `false` | Attach a single-use code identifying the player |
| `Events` | examples | Explicit public event allow-list |

Rate limiting keeps two buckets. Unauthenticated traffic — `/health`,
`/openapi.json`, `/docs`, and failed authentication — is metered per address, since
that is the only identity available. Authenticated traffic is metered per
credential, because a website makes every call from one backend address and
metering those by address would cap the whole site at one caller's budget. The OpenAPI document is rebuilt only when an
event or action is registered or removed, so repeated documentation requests do not
re-serialise it. The in-memory rate limiter resets on resource restart. For an
internet-facing production deployment, also enforce TLS, request limits, and IP
rules at a reverse proxy. Do not use a client event as the direct API target; let a validated server
handler decide whether and what to broadcast.

## Development

The behavioural suite loads the real resource modules into a Lua interpreter with
FiveM's natives replaced by controllable stubs, then drives them through the actual
HTTP handler. It covers authentication, scope matching, rate limiting, idempotency,
schema validation, body handling, the action and batch APIs, connector argument
substitution, audit recording, and the framework adapters.

```bash
sudo apt-get install -y lua5.4   # or the equivalent for your platform
npm test
```

`npm test` runs both the Node tests and the Lua suite, and fails if no Lua
interpreter is available.
