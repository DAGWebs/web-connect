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
server/http/request.lua        Request body and JSON parsing
server/http/response.lua       JSON response formatting
server/http/security.lua       Authentication and rate limiting
server/http/idempotency.lua    Duplicate-request protection
server/http/openapi.lua        Live OpenAPI schema and Scalar page
server/http/router.lua         HTTP routes only
server/integrations/framework.lua  Framework detection and normalized exports
server/integrations/builtins.lua   Included announcement/notification handlers
server/integrations/actions.lua    Money, commands, and configured connectors
server/init.lua                Startup checks
server/token-manager.js        Secure token generation and persistence
data/                          Runtime token storage (secret is git-ignored)
examples/                      Copyable integration examples
tests/                         Automated Node/runtime contract tests
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
webconnect_token create website events:*,action:execute
```

An authorized administrator can also run `/webconnect_token create website events:*,action:execute`
in game.
Grant access to the restricted command in `server.cfg`:

```cfg
add_ace group.admin command.webconnect_token allow
```

The command uses Node's cryptographic random generator to create a 256-bit token,
stores only its SHA-256 hash in `data/tokens.json`, and shows the secret only once
to the command issuer. The file is git-ignored; protect it like any credential
database and include it in secure backups.

Create narrowly scoped credentials for separate integrations, then list or revoke
them without affecting other callers:

```text
webconnect_token create race-site event:start_race 90
webconnect_token create control-panel event:announcement,event:notify_player
webconnect_token list
webconnect_token revoke race-site
```

The `events:*` or `*` scope grants access to every registered event. Prefer
individual `event:<public-name>` scopes whenever possible.

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
when the selected framework lacks a compatible operation. Configure or register a
custom action rather than silently changing a database table.

Grant the restricted command with:

```cfg
add_ace group.admin command.connect allow
```

The player must be online and `42` is their current server ID. The command and
HTTP endpoint use the same parser and action registry.

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
`$arg9`. Literal values such as `vehicle` pass through unchanged. The default
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
For operations that must not run twice, send an `Idempotency-Key` header. Completed
responses are replayed and concurrent duplicates are rejected for five minutes.

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
| `MaxMoneyAction` | `1000000` | Maximum amount per built-in money action |
| `ActionConnectors` | VMS example | Allow-listed export/event adapters |
| `RateLimit` | 30 requests / 60 seconds | Per-address request limit |
| `Events` | examples | Explicit public event allow-list |

The in-memory rate limiter resets on resource restart. For an internet-facing
production deployment, also enforce TLS, request limits, and IP rules at a reverse
proxy. Do not use a client event as the direct API target; let a validated server
handler decide whether and what to broadcast.
