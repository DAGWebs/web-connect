local function validMessage(value)
    return type(value) == 'string' and #value > 0 and #value <= 500
end

AddEventHandler('web-connect:announcement', function(payload)
    if not validMessage(payload.message) then return end
    local title = validMessage(payload.title) and payload.title or 'EVENT'
    TriggerClientEvent('chat:addMessage', -1, {
        color = { 255, 180, 0 },
        args = { title, payload.message }
    })
end)

AddEventHandler('web-connect:notifyPlayer', function(payload)
    local numericPlayerId = tonumber(payload.playerId)
    local playerId = numericPlayerId and math.tointeger(numericPlayerId)
    if not playerId or not validMessage(payload.message) then return end

    local notificationType = type(payload.type) == 'string' and payload.type or 'inform'
    local duration = tonumber(payload.duration) or 5000
    duration = math.max(1000, math.min(math.tointeger(duration) or 5000, 30000))
    WebConnect.Notify(playerId, payload.message, notificationType, duration)
end)
