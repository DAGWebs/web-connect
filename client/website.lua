local open = false

local function close()
    if not open then return end
    open = false
    SetNuiFocus(false, false)
    SendNUIMessage({ action = 'close' })
end

RegisterNetEvent('web-connect:openWebsite', function(payload)
    if type(payload) ~= 'table' or type(payload.url) ~= 'string' then return end
    open = true
    SetNuiFocus(true, true)
    SendNUIMessage({
        action = 'open',
        url = payload.url,
        title = payload.title or 'Website'
    })
end)

RegisterNetEvent('web-connect:closeWebsite', close)

RegisterNUICallback('close', function(_, complete)
    close()
    complete({ ok = true })
end)

-- The page handles Escape itself while it has focus. This covers the case where
-- focus was lost some other way and the overlay would otherwise stay up.
CreateThread(function()
    while true do
        if open then
            Wait(0)
            if IsControlJustReleased(0, 322) then close() end
        else
            Wait(250)
        end
    end
end)

AddEventHandler('onClientResourceStop', function(resource)
    if resource == GetCurrentResourceName() then close() end
end)
