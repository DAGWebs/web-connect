-- This file demonstrates how another server resource can consume a custom API
-- event. Copy the handler into that resource; this file is not loaded here.

local registered, reason = exports['web-connect']:RegisterEvent(
    'start_race',
    'my-races:websiteStart'
)
assert(registered, ('Could not register web event: %s'):format(reason or 'unknown'))

AddEventHandler('my-races:websiteStart', function(payload, context)
    -- Validate every field before handing data to your own race resource.
    if type(payload.trackId) ~= 'string' then return end
    print(('Race request received through %s'):format(context.integration))
    TriggerEvent('my-races:start', payload.trackId)
end)

-- Other resources can use the normalized adapter without knowing the framework.
local player = exports['web-connect']:GetPlayer(1)
if player then
    exports['web-connect']:Notify(player.source, 'Welcome!', 'success', 5000)
end
