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
server/http/request.lua        Request body and JSON parsing
server/http/response.lua       JSON response formatting
server/http/security.lua       Authentication and rate limiting
server/http/router.lua         HTTP routes only
server/integrations/framework.lua  Framework detection and normalized exports
server/integrations/builtins.lua   Included announcement/notification handlers
server/init.lua                Startup checks
examples/                      Copyable integration examples
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

## API

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

## Configuration

| Setting | Default | Purpose |
| --- | --- | --- |
| `TokenConvar` | `web_connect_token` | Server convar containing the bearer token |
| `RoutePrefix` | `/web-connect` | Prefix for all routes |
| `Framework` | `auto` | Framework adapter or automatic detection |
| `MaxBodyBytes` | `65536` | Maximum JSON request size |
| `RateLimit` | 30 requests / 60 seconds | Per-address request limit |
| `Events` | examples | Explicit public event allow-list |

The in-memory rate limiter resets on resource restart. For an internet-facing
production deployment, also enforce TLS, request limits, and IP rules at a reverse
proxy. Do not use a client event as the direct API target; let a validated server
handler decide whether and what to broadcast.
