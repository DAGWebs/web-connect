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

function WebConnect.FrameworkStatus()
    return {
        name = selected,
        ready = selected == 'standalone' or selected == 'qbox' or selected == 'vrp' or core ~= nil,
        capabilities = { players = true, notifications = true }
    }
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

-- An online player with no framework object means one of two different things:
-- a standalone server has no economy/inventory at all, while on a framework the
-- player record simply is not loaded yet. Reporting both as `player_not_found`
-- told the caller the player was offline when they were not.
local function frameworkPlayer(source, unsupported)
    local wrapped = WebConnect.GetPlayer(source)
    if not wrapped then return nil, 'player_not_found' end
    if not wrapped.object then
        return nil, selected == 'standalone' and unsupported or 'player_not_loaded'
    end
    return wrapped.object
end

function WebConnect.AddMoney(source, account, amount, reason)
    local player, reasonCode = frameworkPlayer(source, 'money_not_supported')
    if not player then return false, reasonCode end

    if selected == 'esx' then
        if account == 'cash' then player.addMoney(amount, reason)
        else player.addAccountMoney(account, amount, reason) end
        return true
    end
    if selected == 'qbcore' or selected == 'qbus' or selected == 'qbox' then
        if player.Functions and player.Functions.AddMoney then
            if player.Functions.AddMoney(account, amount, reason) == false then
                return false, 'money_rejected'
            end
            return true
        end
        return false, 'money_not_supported'
    end
    if selected == 'vrp' and player.userId and account == 'cash' then
        local ok = pcall(function() exports.vrp:giveMoney(player.userId, amount) end)
        if not ok then return false, 'money_not_supported' end
        return true
    end
    return false, 'money_not_supported'
end

function WebConnect.AddItem(source, item, amount)
    local player, reasonCode = frameworkPlayer(source, 'inventory_not_supported')
    if not player then return false, reasonCode end
    if selected == 'esx' and player.addInventoryItem then
        player.addInventoryItem(item, amount)
        return true
    end
    if (selected == 'qbcore' or selected == 'qbus' or selected == 'qbox')
        and player.Functions and player.Functions.AddItem then
        if player.Functions.AddItem(item, amount) == false then
            return false, 'inventory_rejected'
        end
        return true
    end
    return false, 'inventory_not_supported'
end

function WebConnect.SetJob(source, job, grade)
    local player, reasonCode = frameworkPlayer(source, 'job_not_supported')
    if not player then return false, reasonCode end
    if selected == 'esx' and player.setJob then
        player.setJob(job, grade)
        return true
    end
    if (selected == 'qbcore' or selected == 'qbus' or selected == 'qbox')
        and player.Functions and player.Functions.SetJob then
        if player.Functions.SetJob(job, grade) == false then
            return false, 'job_rejected'
        end
        return true
    end
    return false, 'job_not_supported'
end

exports('GetFrameworkName', WebConnect.FrameworkName)
exports('GetFrameworkStatus', WebConnect.FrameworkStatus)
exports('GetPlayer', WebConnect.GetPlayer)
exports('Notify', WebConnect.Notify)
exports('AddMoney', WebConnect.AddMoney)
exports('AddItem', WebConnect.AddItem)
exports('SetJob', WebConnect.SetJob)

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

AddEventHandler('onResourceStop', function(resource)
    if Config.Framework ~= 'auto' then return end
    for _, names in pairs(resourceNames) do
        for _, name in ipairs(names) do
            if resource == name then
                SetTimeout(0, WebConnect.RefreshFramework)
                return
            end
        end
    end
end)
