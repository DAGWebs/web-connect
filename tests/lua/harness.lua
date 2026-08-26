-- Loads the real resource files into a fresh environment with the FiveM natives
-- they depend on replaced by controllable stubs, so tests exercise shipped code.
local json = dofile('tests/lua/json.lua')

local MODULES = {
    'config.lua',
    'server/core/namespace.lua',
    'server/core/schema.lua',
    'server/integrations/framework.lua',
    'server/core/registry.lua',
    'server/core/audit.lua',
    'server/core/actions.lua',
    'server/integrations/builtins.lua',
    'server/integrations/actions.lua',
    'server/http/response.lua',
    'server/http/security.lua',
    'server/http/idempotency.lua',
    'server/http/request.lua',
    'server/http/openapi.lua',
    'server/http/router.lua'
}

local harness = {}

function harness.new(options)
    options = options or {}
    local runtime = {
        now = 1700000000,
        gameTimer = 0,
        players = {},
        convars = {},
        resourceStates = {},
        files = {},
        tokens = {},
        events = {},
        commands = {},
        clientEvents = {},
        droppedPlayers = {},
        timers = {},
        threads = {},
        exports = { ['web-connect'] = {} },
        log = {}
    }

    local function fire(name, ...)
        for _, handler in ipairs(runtime.events[name] or {}) do handler(...) end
    end
    runtime.fire = fire

    -- FiveM's export proxy always receives the proxy table as `self`, so both
    -- `exports.res:method(a)` and `exports.res.method(a)` drop the first value.
    local exportsTable = setmetatable({}, {
        __call = function(_, name, callback)
            runtime.exports['web-connect'][name] = callback
        end,
        __index = function(_, resource)
            local proxy = {}
            return setmetatable(proxy, {
                __index = function(_, method)
                    return function(_, ...)
                        local registered = (runtime.exports[resource] or {})[method]
                        if not registered then
                            error(('no export %s:%s'):format(resource, method), 2)
                        end
                        return registered(...)
                    end
                end
            })
        end
    })

    local env = {
        assert = assert, error = error, ipairs = ipairs, next = next, pairs = pairs,
        pcall = pcall, select = select, setmetatable = setmetatable, getmetatable = getmetatable,
        rawget = rawget, rawset = rawset, tonumber = tonumber, tostring = tostring,
        type = type, unpack = table.unpack, xpcall = xpcall, utf8 = utf8,
        math = math, string = string, table = table, json = json,
        print = function(...)
            local parts = {}
            for index = 1, select('#', ...) do parts[index] = tostring((select(index, ...))) end
            runtime.log[#runtime.log + 1] = table.concat(parts, '\t')
        end,
        os = {
            time = function() return runtime.now end,
            date = os.date,
            clock = os.clock
        },
        exports = exportsTable,

        GetCurrentResourceName = function() return 'web-connect' end,
        GetInvokingResource = function() return nil end,
        GetResourceState = function(resource) return runtime.resourceStates[resource] or 'missing' end,
        GetResourceMetadata = function() return '2.3.0' end,
        GetConvar = function(name, fallback) return runtime.convars[name] or fallback end,
        GetGameTimer = function() return runtime.gameTimer end,
        GetPlayerName = function(source) return runtime.players[math.tointeger(tonumber(source)) or -1] end,
        GetPlayerIdentifiers = function(source)
            return { ('license:%s'):format(source), ('steam:%s'):format(source) }
        end,
        DropPlayer = function(source, reason)
            runtime.droppedPlayers[#runtime.droppedPlayers + 1] = { source = source, reason = reason }
        end,

        LoadResourceFile = function(_, name) return runtime.files[name] end,
        SaveResourceFile = function(_, name, data)
            runtime.files[name] = data
            return true
        end,

        AddEventHandler = function(name, handler)
            runtime.events[name] = runtime.events[name] or {}
            table.insert(runtime.events[name], handler)
        end,
        RegisterNetEvent = function() end,
        TriggerEvent = fire,
        TriggerClientEvent = function(name, target, ...)
            runtime.clientEvents[#runtime.clientEvents + 1] = { name = name, target = target, ... }
        end,
        RegisterCommand = function(name, handler, restricted)
            runtime.commands[name] = { handler = handler, restricted = restricted }
        end,
        SetHttpHandler = function(handler) runtime.httpHandler = handler end,

        -- Every CreateThread in the resource is a `while true do Wait() end`
        -- maintenance loop; the work they do is reachable directly instead.
        CreateThread = function(callback) runtime.threads[#runtime.threads + 1] = callback end,
        Wait = function() end,
        SetTimeout = function(delay, callback)
            table.insert(runtime.timers, { dueAt = runtime.gameTimer + delay, callback = callback })
        end
    }
    env._G = env

    runtime.exports['web-connect'].AuthenticateBearer = function(secret)
        local record = runtime.tokens[secret]
        if not record then return nil end
        return { id = record.id, name = record.name, scopes = record.scopes }
    end
    runtime.exports['web-connect'].HasBearerTokens = function()
        return next(runtime.tokens) ~= nil
    end

    if options.exports then
        for resource, methods in pairs(options.exports) do
            runtime.exports[resource] = runtime.exports[resource] or {}
            for name, callback in pairs(methods) do runtime.exports[resource][name] = callback end
        end
    end
    if options.resourceStates then
        for resource, state in pairs(options.resourceStates) do runtime.resourceStates[resource] = state end
    end

    for _, module in ipairs(MODULES) do
        local chunk, reason = loadfile(module, 't', env)
        if not chunk then error(('could not load %s: %s'):format(module, reason)) end
        chunk()
        -- Lets a test adjust configuration before the modules that read it load.
        if module == 'config.lua' and options.configure then options.configure(env.Config) end
    end

    runtime.env = env
    runtime.WebConnect = env.WebConnect
    runtime.Config = env.Config

    function runtime.addToken(secret, definition)
        runtime.tokens[secret] = {
            id = definition.id or definition.name,
            name = definition.name,
            scopes = definition.scopes
        }
    end

    function runtime.addPlayer(source, name)
        runtime.players[source] = name or ('Player%d'):format(source)
    end

    function runtime.advance(milliseconds)
        runtime.gameTimer = runtime.gameTimer + milliseconds
        local due = {}
        local remaining = {}
        for _, timer in ipairs(runtime.timers) do
            if timer.dueAt <= runtime.gameTimer then due[#due + 1] = timer else remaining[#remaining + 1] = timer end
        end
        runtime.timers = remaining
        for _, timer in ipairs(due) do timer.callback() end
    end

    -- `chunked` splits the body and terminates with the empty sentinel; the
    -- default delivers it in one piece the way a single-shot data handler does.
    function runtime.request(method, path, options)
        options = options or {}
        local body = options.body
        if type(body) == 'table' then body = json.encode(body) end

        local headers = {}
        for key, value in pairs(options.headers or {}) do headers[key] = value end
        if body and headers['Content-Length'] == nil and options.omitContentLength ~= true then
            headers['Content-Length'] = tostring(#body)
        end

        local captured = { sent = false }
        local response = {
            writeHead = function(status, responseHeaders)
                captured.status = status
                captured.headers = responseHeaders
            end,
            send = function(payload)
                captured.sent = true
                captured.raw = payload
                local ok, decoded = pcall(json.decode, payload)
                captured.body = ok and decoded or nil
            end
        }

        local request = {
            method = method,
            path = path,
            address = options.address or '203.0.113.10',
            headers = headers,
            setDataHandler = function(callback)
                if options.chunked and body and #body > 1 then
                    local middle = math.floor(#body / 2)
                    callback(body:sub(1, middle))
                    callback(body:sub(middle + 1))
                    callback('')
                else
                    callback(body or '')
                end
            end
        }

        runtime.httpHandler(request, response)
        return captured
    end

    function runtime.authorized(scopes)
        local secret = 'secret-' .. tostring(#runtime.log) .. tostring(runtime.now)
        runtime.addToken(secret, { name = 'test', scopes = scopes })
        return { Authorization = 'Bearer ' .. secret }
    end

    return runtime
end

return harness
