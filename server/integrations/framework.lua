WebConnect = WebConnect or {}

local selected = 'standalone'
local core

local resourceNames = {
    qbox = { 'qbx_core' },
    qbcore = { 'qb-core' },
    qbus = { 'qbus', 'qbus-core' },
    esx = { 'es_extended' },
    vrp = { 'vrp' }
}

local function running(resource)
    local state = GetResourceState(resource)
    return state == 'started' or state == 'starting'
end

local function detect()
    if Config.Framework ~= 'auto' then return Config.Framework:lower() end

    for _, framework in ipairs({ 'qbox', 'qbcore', 'qbus', 'esx', 'vrp' }) do
        for _, resource in ipairs(resourceNames[framework]) do
            if running(resource) then return framework end
        end
    end
    return 'standalone'
end

local function loadCore(framework)
    if framework == 'esx' then
        local ok, value = pcall(function() return exports.es_extended:getSharedObject() end)
        return ok and value or nil
    end

    if framework == 'qbcore' then
        local ok, value = pcall(function() return exports['qb-core']:GetCoreObject() end)
        return ok and value or nil
    end

    if framework == 'qbus' then
        for _, resource in ipairs(resourceNames.qbus) do
            if running(resource) then
                local ok, value = pcall(function() return exports[resource]:GetCoreObject() end)
                if ok then return value end
            end
        end
    end

    return nil
end

function WebConnect.RefreshFramework()
    selected = detect()
    core = loadCore(selected)
    print(('[web-connect] framework adapter: %s'):format(selected))
end

function WebConnect.FrameworkName()
    return selected
end

local function identifiers(source)
    local result = {}
    for _, identifier in ipairs(GetPlayerIdentifiers(source)) do
        local kind = identifier:match('^([^:]+):')
        if kind then result[kind] = identifier end
    end
    return result
end

function WebConnect.GetPlayer(source)
    source = tonumber(source)
    if not source or not GetPlayerName(source) then return nil end

    local player
    if selected == 'esx' and core then
        player = core.GetPlayerFromId(source)
    elseif (selected == 'qbcore' or selected == 'qbus') and core then
        player = core.Functions.GetPlayer(source)
    elseif selected == 'qbox' then
        local ok, value = pcall(function() return exports.qbx_core:GetPlayer(source) end)
        if ok then player = value end
    elseif selected == 'vrp' then
        local ok, value = pcall(function() return exports.vrp:getUserId(source) end)
        if ok then player = { userId = value } end
    end

    return {
        source = source,
        name = GetPlayerName(source),
        identifiers = identifiers(source),
        framework = selected,
        object = player
    }
end

function WebConnect.Notify(source, message, notificationType, duration)
    if not WebConnect.GetPlayer(source) then return false, 'player_not_found' end

    notificationType = notificationType or 'inform'
    duration = duration or 5000
    if selected == 'esx' then
        TriggerClientEvent('esx:showNotification', source, message, notificationType, duration)
    elseif selected == 'qbcore' or selected == 'qbus' then
        TriggerClientEvent('QBCore:Notify', source, message, notificationType, duration)
    elseif selected == 'qbox' then
        TriggerClientEvent('ox_lib:notify', source, {
            description = message,
            type = notificationType,
            duration = duration
        })
    else
        TriggerClientEvent('chat:addMessage', source, {
            color = { 255, 180, 0 },
            args = { 'EVENT', message }
        })
    end
    return true
end

exports('GetFrameworkName', WebConnect.FrameworkName)
exports('GetPlayer', WebConnect.GetPlayer)
exports('Notify', WebConnect.Notify)

AddEventHandler('onResourceStart', function(resource)
    if resource == GetCurrentResourceName() then
        WebConnect.RefreshFramework()
        return
    end

    if Config.Framework == 'auto' then
        for _, names in pairs(resourceNames) do
            for _, name in ipairs(names) do
                if resource == name then WebConnect.RefreshFramework() return end
            end
        end
    end
end)
