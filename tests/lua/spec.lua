local harness = dofile('tests/lua/harness.lua')

local failures, passes = {}, 0
local function test(name, body)
    local ok, reason = pcall(body)
    if ok then
        passes = passes + 1
        print(('ok   - %s'):format(name))
    else
        failures[#failures + 1] = ('%s: %s'):format(name, reason)
        print(('FAIL - %s\n       %s'):format(name, reason))
    end
end

local function equal(actual, expected, label)
    if actual ~= expected then
        error(('%s: expected %s, got %s'):format(label or 'value', tostring(expected), tostring(actual)), 2)
    end
end

local function truthy(value, label)
    if not value then error((label or 'value') .. ' should be truthy', 2) end
end

-- Scope matching -----------------------------------------------------------

test('event:* grants every event scope', function()
    local runtime = harness.new()
    local principal = { scopes = { 'event:*' } }
    truthy(runtime.WebConnect.Http.HasScope(principal, 'event:announcement'))
    truthy(runtime.WebConnect.Http.HasScope(principal, 'event:notify_player'))
end)

test('legacy events:* is accepted as an alias for event:*', function()
    local runtime = harness.new()
    local principal = { scopes = { 'events:*' } }
    truthy(runtime.WebConnect.Http.HasScope(principal, 'event:announcement'))
end)

test('scopes do not leak across namespaces', function()
    local runtime = harness.new()
    equal(runtime.WebConnect.Http.HasScope({ scopes = { 'event:*' } }, 'action:execute'), false)
    equal(runtime.WebConnect.Http.HasScope({ scopes = { 'action:execute' } }, 'event:announcement'), false)
    equal(runtime.WebConnect.Http.HasScope({ scopes = { 'event:announcement' } }, 'event:notify_player'), false)
    truthy(runtime.WebConnect.Http.HasScope({ scopes = { '*' } }, 'event:announcement'))
end)

test('a route accepts any of its declared scopes', function()
    local runtime = harness.new()
    truthy(runtime.WebConnect.Http.HasAnyScope({ scopes = { 'action:execute' } }, { 'event:x', 'action:execute' }))
    equal(runtime.WebConnect.Http.HasAnyScope({ scopes = { 'event:x' } }, { 'action:execute' }), false)
end)

-- Event route --------------------------------------------------------------

test('a token created with the documented scope can dispatch events', function()
    local runtime = harness.new()
    local response = runtime.request('POST', '/web-connect/events/announcement', {
        headers = runtime.authorized({ 'event:*', 'action:execute' }),
        body = { message = 'hello' }
    })
    equal(response.status, 202, 'status')
    equal(response.body.data.accepted, true, 'accepted')
end)

test('missing, insufficient, unknown, malformed and invalid requests are rejected', function()
    local runtime = harness.new()

    equal(runtime.request('POST', '/web-connect/events/announcement', {
        body = { message = 'hello' }
    }).status, 401, 'no credentials')

    equal(runtime.request('POST', '/web-connect/events/announcement', {
        headers = runtime.authorized({ 'event:notify_player' }), body = { message = 'hello' }
    }).status, 403, 'wrong scope')

    equal(runtime.request('POST', '/web-connect/events/nope', {
        headers = runtime.authorized({ '*' }), body = {}
    }).status, 404, 'unknown event')

    equal(runtime.request('POST', '/web-connect/events/announcement', {
        headers = runtime.authorized({ '*' }), body = 'not json'
    }).status, 400, 'invalid json')

    equal(runtime.request('POST', '/web-connect/events/announcement', {
        headers = runtime.authorized({ '*' }), body = { message = '' }
    }).status, 422, 'schema violation')

    equal(runtime.request('POST', '/web-connect/events/announcement', {
        headers = runtime.authorized({ '*' }), body = { message = 'hi', nope = 1 }
    }).status, 422, 'additional property')
end)

test('the announcement handler broadcasts to every client', function()
    local runtime = harness.new()
    runtime.request('POST', '/web-connect/events/announcement', {
        headers = runtime.authorized({ '*' }), body = { message = 'race time' }
    })
    local last = runtime.clientEvents[#runtime.clientEvents]
    equal(last.name, 'chat:addMessage')
    equal(last.target, -1)
end)

-- Request body handling ----------------------------------------------------

test('a body delivered in one piece completes the request', function()
    local runtime = harness.new()
    equal(runtime.request('POST', '/web-connect/events/announcement', {
        headers = runtime.authorized({ '*' }), body = { message = 'single chunk' }
    }).status, 202)
end)

test('a body delivered in chunks completes the request', function()
    local runtime = harness.new()
    equal(runtime.request('POST', '/web-connect/events/announcement', {
        headers = runtime.authorized({ '*' }), body = { message = 'chunked' }, chunked = true
    }).status, 202)
end)

test('a request declaring no body is answered instead of hanging', function()
    local runtime = harness.new()
    local response = runtime.request('POST', '/web-connect/events/announcement', {
        headers = runtime.authorized({ '*' })
    })
    truthy(response.sent, 'response was sent')
    equal(response.status, 400, 'status')
end)

test('an oversized body is rejected on its declared length', function()
    local runtime = harness.new()
    local response = runtime.request('POST', '/web-connect/events/announcement', {
        headers = runtime.authorized({ '*' }),
        body = ('x'):rep(runtime.Config.MaxBodyBytes + 1)
    })
    equal(response.status, 413)
end)

-- Rate limiting ------------------------------------------------------------

test('unauthenticated routes are metered per address', function()
    local runtime = harness.new()
    local limit = runtime.Config.RateLimit.anonymousRequests
    local last
    for _ = 1, limit do last = runtime.request('GET', '/web-connect/health') end
    equal(last.status, 200, 'within limit')
    equal(runtime.request('GET', '/web-connect/health').status, 429, 'over limit')
    equal(runtime.request('GET', '/web-connect/openapi.json').status, 429, 'shared budget')

    runtime.now = runtime.now + runtime.Config.RateLimit.windowSeconds
    equal(runtime.request('GET', '/web-connect/health').status, 200, 'window reset')
end)

test('the address limit is per address', function()
    local runtime = harness.new()
    for _ = 1, runtime.Config.RateLimit.anonymousRequests + 1 do
        runtime.request('GET', '/web-connect/health', { address = '198.51.100.1' })
    end
    equal(runtime.request('GET', '/web-connect/health', { address = '198.51.100.2' }).status, 200)
end)

test('failed authentication is metered per address', function()
    local runtime = harness.new()
    local limit = runtime.Config.RateLimit.anonymousRequests
    local headers = { Authorization = 'Bearer wrong' }
    runtime.addToken('valid', { name = 'test', scopes = { '*' } })
    local last
    for _ = 1, limit do
        last = runtime.request('POST', '/web-connect/events/announcement', {
            headers = headers, body = { message = 'x' }
        })
    end
    equal(last.status, 401, 'rejected but still counted')
    equal(runtime.request('POST', '/web-connect/events/announcement', {
        headers = headers, body = { message = 'x' }
    }).status, 429, 'guessing is throttled')
end)

test('a credential is not capped by the address bucket it shares', function()
    local runtime = harness.new()
    local headers = runtime.authorized({ '*' })
    -- Every request arrives from one backend address, as the README instructs.
    local last
    for _ = 1, runtime.Config.RateLimit.anonymousRequests + 5 do
        last = runtime.request('POST', '/web-connect/events/announcement', {
            headers = headers, body = { message = 'x' }
        })
    end
    equal(last.status, 202, 'not throttled by the anonymous budget')
end)

test('a credential is capped by its own budget', function()
    local runtime = harness.new()
    local headers = runtime.authorized({ '*' })
    local last
    for _ = 1, runtime.Config.RateLimit.requests do
        last = runtime.request('POST', '/web-connect/events/announcement', {
            headers = headers, body = { message = 'x' }
        })
    end
    equal(last.status, 202, 'within its budget')
    equal(runtime.request('POST', '/web-connect/events/announcement', {
        headers = headers, body = { message = 'x' }
    }).status, 429, 'over its budget')

    -- A different credential from the same address is unaffected.
    equal(runtime.request('POST', '/web-connect/events/announcement', {
        headers = runtime.authorized({ '*' }), body = { message = 'x' }
    }).status, 202)
end)

-- Idempotency --------------------------------------------------------------

test('a successful response is replayed for a repeated key', function()
    local runtime = harness.new()
    local headers = runtime.authorized({ '*' })
    headers['Idempotency-Key'] = 'order-1'
    local first = runtime.request('POST', '/web-connect/events/announcement', {
        headers = headers, body = { message = 'once' }
    })
    local broadcasts = #runtime.clientEvents
    local second = runtime.request('POST', '/web-connect/events/announcement', {
        headers = headers, body = { message = 'once' }
    })
    equal(second.status, first.status, 'replayed status')
    equal(second.body.requestId, first.body.requestId, 'replayed body')
    equal(#runtime.clientEvents, broadcasts, 'handler did not run again')
end)

test('the idempotency key is looked up case-insensitively', function()
    local runtime = harness.new()
    local headers = runtime.authorized({ '*' })
    headers['idempotency-key'] = 'order-2'
    local first = runtime.request('POST', '/web-connect/events/announcement', {
        headers = headers, body = { message = 'once' }
    })
    local second = runtime.request('POST', '/web-connect/events/announcement', {
        headers = headers, body = { message = 'once' }
    })
    equal(second.body.requestId, first.body.requestId)
end)

test('a failed action does not pin its idempotency key', function()
    local runtime = harness.new()
    runtime.addPlayer(7)
    local headers = runtime.authorized({ '*' })
    headers['Idempotency-Key'] = 'retry-me'

    local failed = runtime.request('POST', '/api/givecash', {
        headers = headers, body = { playerId = 7, arguments = { -5 } }
    })
    equal(failed.status, 422, 'rejected amount')

    local retried = runtime.request('POST', '/api/givecash', {
        headers = headers, body = { playerId = 7, arguments = { -5 } }
    })
    truthy(retried.status ~= 409, 'retry is not blocked as in-progress')
    equal(retried.status, 422, 'retry is re-evaluated')
end)

-- Actions ------------------------------------------------------------------

test('money actions validate and cap the amount', function()
    local runtime = harness.new()
    runtime.addPlayer(3)
    local context = { playerId = 3, source = 3, principal = { name = 'test' } }
    equal(runtime.WebConnect.ExecuteAction('connect:giveCash:0', context).error, 'invalid_amount')
    equal(runtime.WebConnect.ExecuteAction('connect:giveCash:abc', context).error, 'invalid_amount')
    equal(runtime.WebConnect.ExecuteAction(
        ('connect:giveCash:%d'):format(runtime.Config.MaxMoneyAction + 1), context).error, 'invalid_amount')
    -- Standalone has no economy, so a valid amount reaches the adapter and is
    -- refused there rather than being silently accepted.
    equal(runtime.WebConnect.ExecuteAction('connect:giveCash:10', context).error, 'money_not_supported')
end)

test('unknown actions are refused', function()
    local runtime = harness.new()
    equal(runtime.WebConnect.ExecuteAction('connect:nope:1', { playerId = 1 }).error, 'unknown_action')
end)

test('batch is reserved so the endpoint cannot be shadowed', function()
    local runtime = harness.new()
    local ok, reason = runtime.WebConnect.RegisterAction({ name = 'batch' }, function() end)
    equal(ok, false)
    equal(reason, 'reserved_action_name')
end)

test('the kick action drops the player', function()
    local runtime = harness.new()
    runtime.addPlayer(9)
    local result = runtime.WebConnect.ExecuteAction('connect:kick:Maintenance', { playerId = 9, source = 9 })
    equal(result.status, 200)
    equal(runtime.droppedPlayers[1].source, 9)
    equal(runtime.droppedPlayers[1].reason, 'Maintenance')
end)

-- Connectors ---------------------------------------------------------------

local function garageRuntime(received)
    return harness.new({
        resourceStates = { test_garage = 'started' },
        exports = {
            test_garage = {
                giveVehicle = function(...)
                    received.count = select('#', ...)
                    received.values = { ... }
                    return true
                end
            }
        },
        configure = function(Config)
            Config.ActionConnectors = {
                {
                    name = 'giveCar',
                    resource = 'test_garage',
                    export = 'giveVehicle',
                    usage = 'giveCar:<model>',
                    arguments = { '$source', '$playerId', 'vehicle', '$arg1', '$plate' }
                }
            }
        end
    })
end

test('a connector receives every templated argument in order', function()
    local received = {}
    local runtime = garageRuntime(received)
    runtime.addPlayer(42)
    local result = runtime.WebConnect.ExecuteAction('connect:giveCar:adder', { playerId = 42, source = 42 })
    equal(result.status, 200, 'status')
    equal(received.count, 5, 'argument count')
    equal(received.values[1], 42, '$source')
    equal(received.values[2], 42, '$playerId')
    equal(received.values[3], 'vehicle', 'literal')
    equal(received.values[4], 'adder', '$arg1')
    truthy(type(received.values[5]) == 'string' and #received.values[5] == 8, '$plate')
end)

test('a missing connector argument is refused instead of truncating the call', function()
    local received = {}
    local runtime = garageRuntime(received)
    runtime.addPlayer(42)
    local result = runtime.WebConnect.ExecuteAction('connect:giveCar', { playerId = 42, source = 42 })
    equal(result.status, 422, 'status')
    equal(result.error, 'missing_action_arguments', 'error')
    equal(received.count, nil, 'target was never called')
end)

test('a connector whose resource is stopped reports unavailable', function()
    local received = {}
    local runtime = garageRuntime(received)
    runtime.resourceStates.test_garage = 'stopped'
    runtime.addPlayer(42)
    local result = runtime.WebConnect.ExecuteAction('connect:giveCar:adder', { playerId = 42, source = 42 })
    equal(result.status, 503)
    equal(result.error, 'integration_unavailable')
end)

-- Direct and batch action API ----------------------------------------------

test('the direct action API requires the action scope', function()
    local runtime = harness.new()
    runtime.addPlayer(5)
    equal(runtime.request('POST', '/api/givecash', {
        headers = runtime.authorized({ 'event:*' }), body = { playerId = 5, arguments = { 10 } }
    }).status, 403)
end)

test('a batch reports 207 when a command fails and honours stopOnError', function()
    local received = {}
    local runtime = garageRuntime(received)
    runtime.addPlayer(42)
    local response = runtime.request('POST', '/api/batch', {
        headers = runtime.authorized({ 'action:execute' }),
        body = {
            playerId = 42,
            stopOnError = true,
            commands = {
                { name = 'giveCar', arguments = { 'adder' } },
                { name = 'giveCash', arguments = { 1000 } },
                { name = 'giveCar', arguments = { 'sultan' } }
            }
        }
    })
    equal(response.status, 207, 'status')
    equal(#response.body.data, 2, 'stopped after the failure')
    equal(response.body.data[1].status, 200, 'first command ran')
    truthy(response.body.data[2].error ~= nil, 'second command failed')
end)

test('a batch larger than the configured maximum is refused', function()
    local runtime = harness.new()
    runtime.addPlayer(42)
    local commands = {}
    for index = 1, runtime.Config.MaxBatchActions + 1 do
        commands[index] = { name = 'giveCash', arguments = { 1 } }
    end
    equal(runtime.request('POST', '/api/batch', {
        headers = runtime.authorized({ 'action:execute' }),
        body = { playerId = 42, commands = commands }
    }).status, 422)
end)

test('an action for an offline player is refused', function()
    local runtime = harness.new()
    equal(runtime.request('POST', '/api/givecash', {
        headers = runtime.authorized({ 'action:execute' }), body = { playerId = 999, arguments = { 10 } }
    }).status, 404)
end)

-- Typed handlers -----------------------------------------------------------

test('a handler that never completes times out', function()
    local runtime = harness.new()
    runtime.WebConnect.Register({
        name = 'slow', summary = 'never finishes', timeout = 1000,
        handler = function() end
    }, nil, 'web-connect')

    local response
    local captured = runtime.request('POST', '/web-connect/events/slow', {
        headers = runtime.authorized({ '*' }), body = {}
    })
    response = captured
    equal(response.sent, false, 'no response yet')
    runtime.advance(1000)
    equal(response.status, 504, 'timed out')
    equal(response.body.error, 'handler_timeout', 'error code')
end)

test('a handler error is reported as 500, not as a crash', function()
    local runtime = harness.new()
    runtime.WebConnect.Register({
        name = 'boom', summary = 'throws',
        handler = function() error('kaboom') end
    }, nil, 'web-connect')
    local response = runtime.request('POST', '/web-connect/events/boom', {
        headers = runtime.authorized({ '*' }), body = {}
    })
    equal(response.status, 500)
    equal(response.body.error, 'handler_error')
end)

test('request duration is measured in elapsed milliseconds', function()
    local runtime = harness.new()
    local durations = {}
    runtime.env.AddEventHandler('web-connect:requestCompleted', function(_, _, durationMs)
        durations[#durations + 1] = durationMs
    end)
    runtime.WebConnect.Register({
        name = 'delayed', summary = 'completes later', timeout = 5000,
        handler = function(_, _, done)
            runtime.env.SetTimeout(250, function() done(200, { ok = true }) end)
        end
    }, nil, 'web-connect')

    runtime.request('POST', '/web-connect/events/delayed', {
        headers = runtime.authorized({ '*' }), body = {}
    })
    runtime.advance(250)
    equal(durations[1], 250)
end)

-- Audit --------------------------------------------------------------------

test('audit writes are batched and flushed, not written per action', function()
    local runtime = harness.new()
    runtime.addPlayer(4)
    runtime.WebConnect.ExecuteAction('connect:giveCash:5', { playerId = 4, source = 4 })
    equal(runtime.files['data/audit.json'], nil, 'nothing written yet')

    runtime.WebConnect.FlushAudit()
    truthy(runtime.files['data/audit.json'], 'flushed to disk')
    local saved = runtime.WebConnect.GetAuditEntries(10)
    equal(saved[#saved].action, 'giveCash')
end)

test('the audit log records which administrator ran a command', function()
    local runtime = harness.new()
    runtime.addPlayer(11, 'AdminJane')
    runtime.allowAce(11)
    runtime.commands.connect.handler(11, { '11', 'giveCash', '25' })
    local entries = runtime.WebConnect.GetAuditEntries(5)
    local last = entries[#entries]
    equal(last.actor.name, 'AdminJane', 'actor name')
    equal(last.actor.id, 'player:11', 'actor id')
end)

test('the audit log is capped at the configured size', function()
    local runtime = harness.new()
    runtime.Config.AuditMaxEntries = 3
    for index = 1, 6 do
        runtime.WebConnect.RecordAudit({ action = 'test' .. index, status = 200 })
    end
    local entries = runtime.WebConnect.GetAuditEntries(100)
    equal(#entries, 3, 'entry count')
    equal(entries[1].action, 'test4', 'oldest kept')
end)

test('connect is left restricted when the website uses another name', function()
    local runtime = harness.new({
        configure = function(Config) Config.Website.Command = 'website' end
    })
    equal(runtime.commands.connect.restricted, true, 'admin command stays restricted')
    equal(runtime.commands.website.restricted, false, 'players can open the site')
end)

test('connect is unrestricted when it also opens the website', function()
    local runtime = harness.new()
    equal(runtime.commands.connect.restricted, false, 'every player may run it')
    equal(runtime.commands.website, nil, 'no second command is registered')
end)

test('administrator subcommands are gated even when connect is unrestricted', function()
    local runtime = harness.new()
    runtime.addPlayer(20, 'Nosy')
    runtime.addPlayer(21, 'Victim')

    runtime.commands.connect.handler(20, { '21', 'giveCash', '1000' })
    equal(#runtime.WebConnect.GetAuditEntries(50), 0, 'nothing was executed')
    local refusal = runtime.clientEvents[#runtime.clientEvents]
    truthy(refusal[1].args[2]:match('not allowed'), 'the player was told why')

    runtime.commands.connect.handler(20, { 'logs' })
    equal(#runtime.WebConnect.GetAuditEntries(50), 0, 'the audit log stays private')
    runtime.commands.connect.handler(20, { 'list' })
    equal(#runtime.WebConnect.GetAuditEntries(50), 0, 'the action list stays private')

    runtime.allowAce(20)
    runtime.commands.connect.handler(20, { 'list' })
    truthy(#runtime.WebConnect.GetAuditEntries(50) > 0, 'an administrator gets through')
end)

-- OpenAPI ------------------------------------------------------------------

test('the OpenAPI document is cached until the registry changes', function()
    local runtime = harness.new()
    local first = runtime.WebConnect.Http.OpenApi('/web-connect')
    equal(runtime.WebConnect.Http.OpenApi('/web-connect'), first, 'served from cache')

    runtime.WebConnect.Register({ name = 'fresh', event = 'x:fresh' }, nil, 'web-connect')
    local second = runtime.WebConnect.Http.OpenApi('/web-connect')
    truthy(second ~= first, 'rebuilt after registration')
    truthy(second.paths['/web-connect/events/fresh'], 'new route documented')
end)

test('registered actions appear in the documented action API', function()
    local runtime = harness.new()
    local document = runtime.WebConnect.Http.OpenApi('/web-connect')
    truthy(document.paths['/api/givecash'], 'giveCash documented')
    truthy(document.paths['/api/batch'], 'batch documented')
end)

-- Framework adapters -------------------------------------------------------

local function qbcoreRuntime(calls)
    local player = {
        Functions = {
            AddMoney = function(account, amount) calls[#calls + 1] = { account, amount } return true end,
            AddItem = function() return false end
        }
    }
    return harness.new({
        resourceStates = { ['qb-core'] = 'started' },
        exports = {
            ['qb-core'] = {
                GetCoreObject = function()
                    return { Functions = { GetPlayer = function() return player end } }
                end
            }
        }
    })
end

test('a successful framework call reports no failure reason', function()
    local calls = {}
    local runtime = qbcoreRuntime(calls)
    runtime.addPlayer(2)
    runtime.WebConnect.RefreshFramework()
    equal(runtime.WebConnect.FrameworkName(), 'qbcore', 'detected framework')

    local ok, reason = runtime.WebConnect.AddMoney(2, 'cash', 500, 'test')
    equal(ok, true, 'accepted')
    equal(reason, nil, 'no reason on success')
    equal(calls[1][1], 'cash')
    equal(calls[1][2], 500)
end)

test('a rejected framework call reports the reason', function()
    local calls = {}
    local runtime = qbcoreRuntime(calls)
    runtime.addPlayer(2)
    runtime.WebConnect.RefreshFramework()
    local ok, reason = runtime.WebConnect.AddItem(2, 'lockpick', 1)
    equal(ok, false)
    equal(reason, 'inventory_rejected')
end)

test('qbox is preferred over a qbcore compatibility resource', function()
    local runtime = harness.new({ resourceStates = { ['qb-core'] = 'started', qbx_core = 'started' } })
    runtime.WebConnect.RefreshFramework()
    equal(runtime.WebConnect.FrameworkName(), 'qbox')
end)

-- Registry ownership -------------------------------------------------------

test('a resource cannot overwrite or unregister another resource route', function()
    local runtime = harness.new()
    truthy(runtime.WebConnect.Register({ name = 'owned', event = 'a:owned' }, nil, 'resource-a'))
    local ok, reason = runtime.WebConnect.Register({ name = 'owned', event = 'b:owned' }, nil, 'resource-b')
    equal(ok, false, 'overwrite refused')
    equal(reason, 'event_already_registered')

    local removed, removeReason = runtime.WebConnect.UnregisterEvent('owned', 'resource-b')
    equal(removed, false, 'unregister refused')
    equal(removeReason, 'not_event_owner')
    truthy(runtime.WebConnect.UnregisterEvent('owned', 'resource-a'), 'owner may unregister')
end)

test('routes are removed when their owning resource stops', function()
    local runtime = harness.new()
    runtime.WebConnect.Register({ name = 'temporary', event = 'a:temp' }, nil, 'resource-a')
    truthy(runtime.WebConnect.HasEvent('temporary'))
    runtime.fire('onResourceStop', 'resource-a')
    equal(runtime.WebConnect.HasEvent('temporary'), false)
end)

test('public names are validated', function()
    local runtime = harness.new()
    equal(select(2, runtime.WebConnect.Register({ name = 'bad name', event = 'x' })), 'invalid_public_name')
    equal(select(2, runtime.WebConnect.Register({ name = 'ok' })), 'invalid_server_event')
end)

-- Schema -------------------------------------------------------------------

test('schema validation covers types, bounds and unknown keys', function()
    local runtime = harness.new()
    local schema = {
        type = 'object', required = { 'id' }, additionalProperties = false,
        properties = {
            id = { type = 'integer', minimum = 1 },
            label = { type = 'string', minLength = 1, maxLength = 4 }
        }
    }
    truthy(runtime.WebConnect.Validate({ id = 1, label = 'abcd' }, schema))
    equal(runtime.WebConnect.Validate({}, schema), false, 'missing required')
    equal(runtime.WebConnect.Validate({ id = 0 }, schema), false, 'below minimum')
    equal(runtime.WebConnect.Validate({ id = 1.5 }, schema), false, 'not an integer')
    equal(runtime.WebConnect.Validate({ id = 1, label = 'abcde' }, schema), false, 'too long')
    equal(runtime.WebConnect.Validate({ id = 1, extra = true }, schema), false, 'unknown key')
end)


test('an online player on a standalone server reports a capability error', function()
    local runtime = harness.new()
    runtime.addPlayer(6)
    local ok, reason = runtime.WebConnect.AddMoney(6, 'cash', 100)
    equal(ok, false)
    equal(reason, 'money_not_supported', 'not player_not_found')
    equal(select(2, runtime.WebConnect.AddItem(6, 'lockpick', 1)), 'inventory_not_supported')
    equal(select(2, runtime.WebConnect.SetJob(6, 'police', 1)), 'job_not_supported')
end)

test('an offline player is still reported as not found', function()
    local runtime = harness.new()
    equal(select(2, runtime.WebConnect.AddMoney(404, 'cash', 100)), 'player_not_found')
end)

test('a framework player who is not loaded is reported distinctly', function()
    local runtime = harness.new({
        resourceStates = { ['qb-core'] = 'started' },
        exports = {
            ['qb-core'] = {
                GetCoreObject = function()
                    return { Functions = { GetPlayer = function() return nil end } }
                end
            }
        }
    })
    runtime.addPlayer(8)
    runtime.WebConnect.RefreshFramework()
    equal(select(2, runtime.WebConnect.AddMoney(8, 'cash', 100)), 'player_not_loaded')
end)


test('the action API validates its payload', function()
    local runtime = harness.new()
    runtime.addPlayer(5)
    local headers = runtime.authorized({ 'action:execute' })

    equal(runtime.request('POST', '/api/givecash', {
        headers = headers, body = { playerId = 5, arguments = { key = 'value' } }
    }).status, 422, 'arguments must be an array')

    equal(runtime.request('POST', '/api/givecash', {
        headers = headers, body = { playerId = 5, arguments = { { nested = true } } }
    }).status, 422, 'arguments must be scalars')

    equal(runtime.request('POST', '/api/givecash', {
        headers = headers, body = { playerId = 5, arguments = { 10 }, extra = 'no' }
    }).status, 422, 'unknown properties are refused')

    equal(runtime.request('POST', '/api/givecash', {
        headers = headers, body = { arguments = { 10 } }
    }).status, 422, 'playerId is required')
end)

test('a batch validates each command', function()
    local runtime = harness.new()
    runtime.addPlayer(5)
    local headers = runtime.authorized({ 'action:execute' })

    equal(runtime.request('POST', '/api/batch', {
        headers = headers, body = { playerId = 5, commands = { { name = 'giveCash', arguments = 'nope' } } }
    }).status, 422, 'arguments must be an array')

    equal(runtime.request('POST', '/api/batch', {
        headers = headers, body = { playerId = 5, commands = {} }
    }).status, 422, 'at least one command')

    equal(runtime.request('POST', '/api/batch', {
        headers = headers, body = { playerId = 5 }
    }).status, 422, 'commands is required')
end)

test('action names are validated rather than stripped', function()
    local runtime = harness.new()
    equal(select(2, runtime.WebConnect.RegisterAction({ name = 'give$Cash' }, function() end)), 'invalid_action')
    equal(select(2, runtime.WebConnect.RegisterAction({ name = '' }, function() end)), 'invalid_action')
    -- Punctuation used to be stripped, so this resolved to the registered giveCash.
    equal(runtime.WebConnect.ExecuteAction('connect:give$Cash:10', { playerId = 1 }).error, 'unknown_action')
    -- Case is still folded, which is what the lowercase /api/<action> paths rely on.
    runtime.addPlayer(1)
    equal(runtime.WebConnect.ExecuteAction('connect:GIVECASH:10', { playerId = 1 }).error, 'money_not_supported')
end)

test('the schema validates arrays, enums and patterns', function()
    local runtime = harness.new()
    local validate = runtime.WebConnect.Validate

    local list = { type = 'array', minItems = 1, maxItems = 2, items = { type = 'integer' } }
    truthy(validate({ 1, 2 }, list))
    equal(validate({}, list), false, 'below minItems')
    equal(validate({ 1, 2, 3 }, list), false, 'above maxItems')
    equal(validate({ 'a' }, list), false, 'wrong item type')
    equal(validate({ key = 1 }, list), false, 'not an array')

    truthy(validate('success', { type = 'string', enum = { 'success', 'error' } }))
    equal(validate('other', { type = 'string', enum = { 'success', 'error' } }), false)

    truthy(validate('AB12', { type = 'string', pattern = '^%u%u%d%d$' }))
    equal(validate('nope', { type = 'string', pattern = '^%u%u%d%d$' }), false)

    truthy(validate(5, { type = { 'string', 'number' } }), 'union type')
    truthy(validate('five', { type = { 'string', 'number' } }), 'union type')
    equal(validate(true, { type = { 'string', 'number' } }), false, 'outside the union')
end)

test('registering a handler does not mutate the caller definition', function()
    local runtime = harness.new()
    local definition = { name = 'typed', summary = 'test' }
    runtime.exports['web-connect'].RegisterHandler(definition, function() end)
    equal(definition.handler, nil, 'the caller table is untouched')
    truthy(runtime.WebConnect.HasEvent('typed'))
end)


-- Website ------------------------------------------------------------------

local function websiteRuntime(overrides)
    return harness.new({
        configure = function(Config)
            Config.Website.Url = 'https://example.com'
            for key, value in pairs(overrides or {}) do Config.Website[key] = value end
        end
    })
end

test('/connect with no arguments opens the website for the player', function()
    local runtime = websiteRuntime()
    runtime.addPlayer(30)
    runtime.commands.connect.handler(30, {})

    local opened
    for _, event in ipairs(runtime.clientEvents) do
        if event.name == 'web-connect:openWebsite' then opened = event end
    end
    truthy(opened, 'the tablet was opened')
    equal(opened.target, 30, 'for the player who ran it')
    equal(opened[1].url, 'https://example.com/', 'at the configured site')
end)

test('chat mode sends the link instead of the tablet', function()
    local runtime = websiteRuntime({ Mode = 'chat' })
    runtime.addPlayer(31)
    runtime.commands.connect.handler(31, {})

    local last = runtime.clientEvents[#runtime.clientEvents]
    equal(last.name, 'chat:addMessage')
    equal(last[1].args[2], 'https://example.com/')
end)

test('a path may be chosen but a different site may not', function()
    local runtime = websiteRuntime()
    runtime.addPlayer(32)

    equal(runtime.WebConnect.BuildWebsiteUrl('/store', 32), 'https://example.com/store', 'path')
    equal(runtime.WebConnect.BuildWebsiteUrl('store', 32), 'https://example.com/store', 'leading slash added')
    equal(runtime.WebConnect.BuildWebsiteUrl('/shop?item=1', 32), 'https://example.com/shop?item=1', 'query kept')

    for _, hostile in ipairs({
        'https://evil.example/steal',
        '//evil.example/steal',
        '/../../etc/passwd',
        'javascript:alert(1)',
        '/ok\r\nX-Injected: 1'
    }) do
        equal(select(2, runtime.WebConnect.BuildWebsiteUrl(hostile, 32)), 'invalid_path',
            ('refused %q'):format(hostile))
    end
end)

test('the website action opens a page for a player', function()
    local runtime = websiteRuntime()
    runtime.addPlayer(33)
    local response = runtime.request('POST', '/api/openwebsite', {
        headers = runtime.authorized({ 'action:execute' }),
        body = { playerId = 33, arguments = { '/store' } }
    })
    equal(response.status, 200, 'status')

    local opened
    for _, event in ipairs(runtime.clientEvents) do
        if event.name == 'web-connect:openWebsite' then opened = event end
    end
    equal(opened[1].url, 'https://example.com/store')
end)

test('the website action refuses a hostile path', function()
    local runtime = websiteRuntime()
    runtime.addPlayer(34)
    local response = runtime.request('POST', '/api/openwebsite', {
        headers = runtime.authorized({ 'action:execute' }),
        body = { playerId = 34, arguments = { 'https://evil.example' } }
    })
    equal(response.status, 422)
    equal(response.body.error, 'invalid_path')
end)

test('a disabled website restores the restricted connect command', function()
    local runtime = websiteRuntime({ Enabled = false })
    runtime.addPlayer(35)
    equal(select(2, runtime.WebConnect.OpenWebsite(35, '/')), 'website_disabled')
    equal(runtime.commands.connect.restricted, true, 'connect is administrator-only again')
end)

test('link codes are single use and expire', function()
    local runtime = websiteRuntime({ LinkCode = true, LinkCodeTtlSeconds = 60 })
    runtime.addPlayer(36, 'Linker')

    local url = runtime.WebConnect.BuildWebsiteUrl('/', 36)
    local code = url:match('code=([%u%d]+)$')
    truthy(code, 'the url carries a code')

    local entry = runtime.WebConnect.RedeemLinkCode(code)
    equal(entry.playerId, 36, 'identifies the player')
    equal(entry.name, 'Linker', 'carries the name')
    truthy(entry.identifiers.license, 'carries identifiers')
    equal(runtime.WebConnect.RedeemLinkCode(code), nil, 'a code redeems only once')

    local second = runtime.WebConnect.BuildWebsiteUrl('/', 36):match('code=([%u%d]+)$')
    runtime.now = runtime.now + 61
    equal(runtime.WebConnect.RedeemLinkCode(second), nil, 'an expired code is refused')
end)

test('link codes are only issued when enabled', function()
    local runtime = websiteRuntime({ LinkCode = false })
    runtime.addPlayer(37)
    equal(runtime.WebConnect.BuildWebsiteUrl('/', 37), 'https://example.com/', 'no code appended')
end)

test('the redeem endpoint exchanges a code over the API', function()
    local runtime = websiteRuntime({ LinkCode = true })
    runtime.addPlayer(38, 'Linker')
    local code = runtime.WebConnect.BuildWebsiteUrl('/', 38):match('code=([%u%d]+)$')

    local response = runtime.request('POST', '/web-connect/events/redeem_link', {
        headers = runtime.authorized({ 'action:execute' }),
        body = { code = code }
    })
    equal(response.status, 200, 'status')
    equal(response.body.data.playerId, 38, 'player')
    equal(response.body.data.online, true, 'still connected')

    equal(runtime.request('POST', '/web-connect/events/redeem_link', {
        headers = runtime.authorized({ 'action:execute' }), body = { code = code }
    }).status, 404, 'a replayed code is refused')
end)

test('the redeem endpoint requires the action scope', function()
    local runtime = websiteRuntime({ LinkCode = true })
    equal(runtime.request('POST', '/web-connect/events/redeem_link', {
        headers = runtime.authorized({ 'event:*' }), body = { code = 'ABCDEFGH' }
    }).status, 403)
end)

test('redeeming is unavailable when link codes are off', function()
    local runtime = websiteRuntime({ LinkCode = false })
    local response = runtime.request('POST', '/web-connect/events/redeem_link', {
        headers = runtime.authorized({ 'action:execute' }), body = { code = 'ABCDEFGH' }
    })
    equal(response.status, 404)
    equal(response.body.error, 'link_codes_disabled')
end)

print(('\n%d passed, %d failed'):format(passes, #failures))
if #failures > 0 then os.exit(1) end
