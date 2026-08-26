local routes = {}

local function validPublicName(name)
    return type(name) == 'string' and #name <= 64 and name:match('^[%w_-]+$') ~= nil
end

local function ownerName(owner)
    return owner or GetInvokingResource() or GetCurrentResourceName()
end

local function normalize(definition, serverEvent, owner)
    if type(definition) == 'string' then
        definition = { name = definition, event = serverEvent }
    end
    if type(definition) ~= 'table' then return nil, 'invalid_definition' end
    if not validPublicName(definition.name) then return nil, 'invalid_public_name' end
    if definition.handler == nil and (type(definition.event) ~= 'string' or definition.event == '') then
        return nil, 'invalid_server_event'
    end

    return {
        name = definition.name,
        event = definition.event,
        handler = definition.handler,
        owner = ownerName(owner),
        summary = definition.summary or ('Dispatch the %s event'):format(definition.name),
        description = definition.description,
        tags = definition.tags or { 'Events' },
        schema = definition.schema or { type = 'object', additionalProperties = true },
        scopes = definition.scopes or { 'event:' .. definition.name },
        timeout = math.max(100, math.min(tonumber(definition.timeout) or Config.RequestTimeoutMs, 30000))
    }
end

function WebConnect.Register(definition, serverEvent, owner)
    local route, reason = normalize(definition, serverEvent, owner)
    if not route then return false, reason end
    local existing = routes[route.name]
    if existing and existing.owner ~= route.owner then return false, 'event_already_registered' end
    routes[route.name] = route
    WebConnect.BumpRevision()
    TriggerEvent('web-connect:eventRegistered', route.name, route.owner)
    return true
end

function WebConnect.UnregisterEvent(publicName, owner)
    owner = ownerName(owner)
    local existing = routes[publicName]
    if not existing then return false, 'event_not_registered' end
    if existing.owner ~= owner then return false, 'not_event_owner' end
    routes[publicName] = nil
    WebConnect.BumpRevision()
    TriggerEvent('web-connect:eventUnregistered', publicName, owner)
    return true
end

function WebConnect.GetRoute(publicName)
    return routes[publicName]
end

function WebConnect.Dispatch(publicName, payload, context, complete)
    local route = routes[publicName]
    if not route then complete(404, nil, 'unknown_event') return end
    context.integration = route.owner

    if route.handler then
        local finished = false
        local function done(status, data, errorCode)
            if finished then return end
            finished = true
            complete(status or 200, data, errorCode)
        end
        SetTimeout(route.timeout, function() done(504, nil, 'handler_timeout') end)
        local ok, result = pcall(route.handler, payload, context, done)
        if not ok then done(500, nil, 'handler_error')
        elseif result ~= nil then done(result.status, result.data, result.error) end
    else
        TriggerEvent(route.event, payload, context)
        complete(202, { accepted = true, event = publicName })
    end
    TriggerEvent('web-connect:eventDispatched', publicName, payload, context)
end

function WebConnect.HasEvent(publicName) return routes[publicName] ~= nil end

function WebConnect.ListEvents()
    local result = {}
    for name, route in pairs(routes) do
        result[name] = {
            event = route.event, owner = route.owner, summary = route.summary,
            description = route.description, tags = route.tags, schema = route.schema,
            scopes = route.scopes
        }
    end
    return result
end

function WebConnect.CountEvents()
    local count = 0
    for _ in pairs(routes) do count = count + 1 end
    return count
end

for publicName, configured in pairs(Config.Events) do
    local definition = configured
    if type(configured) == 'table' then
        definition.name = definition.name or publicName
    else
        definition = publicName
    end
    local ok, reason = WebConnect.Register(definition, configured, GetCurrentResourceName())
    if not ok then WebConnect.Log(('could not register %q: %s'):format(publicName, reason)) end
end

exports('RegisterEvent', function(name, event) return WebConnect.Register(name, event, GetInvokingResource()) end)
exports('RegisterHandler', function(definition, handler)
    definition.handler = handler
    return WebConnect.Register(definition, nil, GetInvokingResource())
end)
exports('UnregisterEvent', function(name) return WebConnect.UnregisterEvent(name, GetInvokingResource()) end)
exports('GetRegisteredEvents', WebConnect.ListEvents)

AddEventHandler('web-connect:registerEvent', function(name, event, callback)
    local ok, reason = WebConnect.Register(name, event, GetInvokingResource())
    if type(callback) == 'function' then callback(ok, reason) end
end)

AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() then return end
    local removed = false
    for name, route in pairs(routes) do
        if route.owner == resource then
            routes[name] = nil
            removed = true
        end
    end
    if removed then WebConnect.BumpRevision() end
end)
