WebConnect = WebConnect or {}

local routes = {}

local function validPublicName(name)
    return type(name) == 'string'
        and #name <= 64
        and name:match('^[%w_-]+$') ~= nil
end

local function ownerName(owner)
    return owner or GetInvokingResource() or GetCurrentResourceName()
end

function WebConnect.RegisterEvent(publicName, serverEvent, owner)
    owner = ownerName(owner)
    if not validPublicName(publicName) then return false, 'invalid_public_name' end
    if type(serverEvent) ~= 'string' or serverEvent == '' or #serverEvent > 128 then
        return false, 'invalid_server_event'
    end

    local existing = routes[publicName]
    if existing and existing.owner ~= owner then return false, 'event_already_registered' end

    routes[publicName] = { event = serverEvent, owner = owner }
    return true
end


function WebConnect.UnregisterEvent(publicName, owner)
    owner = ownerName(owner)
    local existing = routes[publicName]
    if not existing then return false, 'event_not_registered' end
    if existing.owner ~= owner then return false, 'not_event_owner' end

    routes[publicName] = nil
    return true
end


function WebConnect.Dispatch(publicName, payload, context)
    local route = routes[publicName]
    if not route then return false, 'unknown_event' end

    context.integration = route.owner
    TriggerEvent(route.event, payload, context)
    TriggerEvent('web-connect:eventDispatched', publicName, payload, context)
    return true
end


function WebConnect.HasEvent(publicName)
    return routes[publicName] ~= nil
end


function WebConnect.ListEvents()
    local result = {}
    for publicName, route in pairs(routes) do
        result[publicName] = { event = route.event, owner = route.owner }
    end
    return result
end


for publicName, serverEvent in pairs(Config.Events) do
    local registered, reason = WebConnect.RegisterEvent(
        publicName,
        serverEvent,
        GetCurrentResourceName()
    )
    if not registered then
        print(('[web-connect] could not register configured event %q: %s'):format(publicName, reason))
    end
end


exports('RegisterEvent', function(publicName, serverEvent)
    return WebConnect.RegisterEvent(publicName, serverEvent, GetInvokingResource())
end)

exports('UnregisterEvent', function(publicName)
    return WebConnect.UnregisterEvent(publicName, GetInvokingResource())
end)

exports('GetRegisteredEvents', WebConnect.ListEvents)

-- Event-based registration supports resources that prefer not to call exports.
-- The optional callback receives (success, reason).
AddEventHandler('web-connect:registerEvent', function(publicName, serverEvent, callback)
    local registered, reason = WebConnect.RegisterEvent(publicName, serverEvent, GetInvokingResource())
    if type(callback) == 'function' then callback(registered, reason) end
end)

AddEventHandler('web-connect:unregisterEvent', function(publicName, callback)
    local removed, reason = WebConnect.UnregisterEvent(publicName, GetInvokingResource())
    if type(callback) == 'function' then callback(removed, reason) end
end)

AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() then return end
    for publicName, route in pairs(routes) do
        if route.owner == resource then routes[publicName] = nil end
    end
end)
