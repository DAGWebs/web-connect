local function actionContext(payload, requestContext)
    local playerId = math.tointeger(tonumber(payload.playerId))
    if not playerId or not WebConnect.GetPlayer(playerId) then return nil end
    return {
        playerId = playerId,
        source = playerId,
        request = requestContext,
        principal = requestContext.principal
    }
end

local function moneyAction(account)
    return function(arguments, context)
        local amount = math.tointeger(tonumber(arguments[1]))
        if not amount or amount <= 0 or amount > Config.MaxMoneyAction then
            return { status = 422, error = 'invalid_amount' }
        end
        local ok, reason = WebConnect.AddMoney(context.playerId, account, amount, 'web-connect')
        if not ok then return { status = 409, error = reason } end
        return { status = 200, data = { account = account, amount = amount, playerId = context.playerId } }
    end
end

WebConnect.RegisterAction({
    name = 'giveCash', aliases = { 'giveMoney' }, usage = 'giveCash:<amount>',
    description = 'Add cash to an online player'
}, moneyAction('cash'))
WebConnect.RegisterAction({
    name = 'giveBank', usage = 'giveBank:<amount>', description = 'Add bank money to an online player'
}, moneyAction('bank'))
WebConnect.RegisterAction({
    name = 'giveCrypto', usage = 'giveCrypto:<amount>', description = 'Add crypto to an online player'
}, moneyAction('crypto'))

WebConnect.RegisterAction({
    name = 'notify', usage = 'notify:<message>', description = 'Show a notification to an online player'
}, function(arguments, context)
    local message = table.concat(arguments, ':')
    if message == '' or #message > 500 then return { status = 422, error = 'invalid_message' } end
    local ok, reason = WebConnect.Notify(context.playerId, message, 'inform', 5000)
    if not ok then return { status = 409, error = reason } end
    return { status = 200, data = { notified = true } }
end)

WebConnect.RegisterAction({
    name = 'giveItem', usage = 'giveItem:<item>:<amount>', description = 'Add an inventory item to a player'
}, function(arguments, context)
    local item = arguments[1]
    local amount = math.tointeger(tonumber(arguments[2] or 1))
    if not item or not item:match('^[%w_%-]+$') or not amount or amount < 1 or amount > Config.MaxItemAction then
        return { status = 422, error = 'invalid_item' }
    end
    local ok, reason = WebConnect.AddItem(context.playerId, item, amount)
    if not ok then return { status = 409, error = reason } end
    return { status = 200, data = { item = item, amount = amount } }
end)

WebConnect.RegisterAction({
    name = 'setJob', usage = 'setJob:<job>:<grade>', description = 'Set a player framework job and grade'
}, function(arguments, context)
    local job = arguments[1]
    local grade = math.tointeger(tonumber(arguments[2] or 0))
    if not job or not job:match('^[%w_%-]+$') or not grade or grade < 0 then
        return { status = 422, error = 'invalid_job' }
    end
    local ok, reason = WebConnect.SetJob(context.playerId, job, grade)
    if not ok then return { status = 409, error = reason } end
    return { status = 200, data = { job = job, grade = grade } }
end)

WebConnect.RegisterAction({
    name = 'kick', usage = 'kick:<reason>', description = 'Disconnect a player with a reason'
}, function(arguments, context)
    local reason = table.concat(arguments, ':')
    if reason == '' or #reason > 250 then return { status = 422, error = 'invalid_reason' } end
    DropPlayer(context.playerId, reason)
    return { status = 200, data = { kicked = true } }
end)

local plateLetters = 'ABCDEFGHIJKLMNPQRSTUVWXYZ'

local function randomPlate()
    local prefix = {}
    for index = 1, 3 do
        local position = math.random(1, #plateLetters)
        prefix[index] = plateLetters:sub(position, position)
    end
    return ('%s%05d'):format(table.concat(prefix), math.random(0, 99999))
end

-- Returns the substituted values plus their count. A missing `$argN` must be
-- reported rather than left as a nil hole: `table.unpack` would then stop at the
-- hole and silently call the target script with the wrong arity.
local function connectorArguments(template, arguments, context)
    local result = {}
    for index, value in ipairs(template) do
        if value == '$source' then result[index] = context.source
        elseif value == '$playerId' then result[index] = context.playerId
        elseif value == '$plate' then result[index] = randomPlate()
        else
            local argumentIndex = type(value) == 'string' and value:match('^%$arg(%d)$')
            if argumentIndex then
                local supplied = arguments[tonumber(argumentIndex)]
                if supplied == nil then return nil, 'missing_action_arguments' end
                result[index] = supplied
            else
                result[index] = value
            end
        end
    end
    return result, #template
end

for _, connector in ipairs(Config.ActionConnectors) do
    WebConnect.RegisterAction({
        name = connector.name,
        description = connector.description,
        usage = connector.usage or (connector.name .. ':<arguments>')
    }, function(arguments, context)
        if connector.minArguments and #arguments < connector.minArguments then
            return { status = 422, error = 'missing_action_arguments' }
        end
        if connector.maxArguments and #arguments > connector.maxArguments then
            return { status = 422, error = 'too_many_action_arguments' }
        end
        if connector.resource and GetResourceState(connector.resource) ~= 'started' then
            return { status = 503, error = 'integration_unavailable' }
        end
        local values, count = connectorArguments(connector.arguments, arguments, context)
        if not values then return { status = 422, error = count } end
        if connector.kind == 'serverEvent' then
            TriggerEvent(connector.event, table.unpack(values, 1, count))
            return { status = 202, data = { accepted = true } }
        end
        if connector.kind == 'clientEvent' then
            TriggerClientEvent(connector.event, context.playerId, table.unpack(values, 1, count))
            return { status = 202, data = { accepted = true } }
        end
        -- FiveM's export proxy always consumes a `self` argument, so the target
        -- has to be passed explicitly; dot-calling it silently drops $source.
        local ok, result = pcall(function()
            local target = exports[connector.resource]
            return target[connector.export](target, table.unpack(values, 1, count))
        end)
        if not ok then
            WebConnect.Log(('%s:%s failed: %s'):format(connector.resource, connector.export, result))
            return { status = 500, error = 'integration_failed' }
        end
        return { status = 200, data = { completed = true, result = result } }
    end)
end

WebConnect.Register({
    name = 'execute_action',
    summary = 'Execute an allow-listed player action',
    description = 'Runs connect:action:argument strings through framework or script adapters.',
    scopes = { 'action:execute' },
    schema = {
        type = 'object', required = { 'playerId', 'action' }, additionalProperties = false,
        properties = {
            playerId = { type = 'integer', minimum = 1 },
            action = { type = 'string', minLength = 1, maxLength = 256 }
        }
    },
    handler = function(payload, requestContext)
        local context = actionContext(payload, requestContext)
        if not context then return { status = 404, error = 'player_not_found' } end
        return WebConnect.ExecuteAction(payload.action, context)
    end
}, nil, GetCurrentResourceName())

RegisterCommand('connect', function(source, arguments)
    local subcommand = (arguments[1] or ''):lower()
    local actor = source == 0
        and { id = 'console', name = 'console' }
        or { id = ('player:%d'):format(source), name = GetPlayerName(source) or ('player:%d'):format(source) }
    local function reply(message)
        if source == 0 then WebConnect.Log(message)
        else TriggerClientEvent('chat:addMessage', source, { args = { 'WEB CONNECT', message } }) end
    end
    if subcommand == 'logs' then
        for _, entry in ipairs(WebConnect.GetAuditEntries(arguments[2])) do
            local entryActor = entry.actor and (entry.actor.name or entry.actor.id) or 'unknown'
            reply(('%s | %s | player %s | %s | HTTP %s%s'):format(
                entry.timestamp,
                entryActor,
                entry.playerId or '-',
                entry.action or '-',
                entry.status or '-',
                entry.error and (' | ' .. entry.error) or ''
            ))
        end
        WebConnect.RecordAudit({ action = 'admin:logs', actor = actor, status = 200 })
        return
    end
    if subcommand == 'help' or subcommand == 'list' or subcommand == '' then
        reply('Usage: /connect <playerId> <action> [arguments]')
        reply('Admin: /connect list | /connect logs [limit]')
        for _, action in ipairs(WebConnect.ListActions()) do
            reply(('%s - %s'):format(action.usage, action.description))
        end
        WebConnect.RecordAudit({ action = 'admin:list', actor = actor, status = 200 })
        return
    end
    local playerId = math.tointeger(tonumber(table.remove(arguments, 1)))
    if not playerId or not WebConnect.GetPlayer(playerId) then
        WebConnect.RecordAudit({ action = table.concat(arguments, ':'), playerId = playerId, actor = actor, status = 404, error = 'player_not_found' })
        reply('Failed: player_not_found')
        return
    end
    local action = Config.ActionPrefix .. ':' .. table.concat(arguments, ':')
    local result = WebConnect.ExecuteAction(action, { playerId = playerId, source = playerId, principal = actor })
    local message = result.error and ('Failed: ' .. result.error) or 'Action completed.'
    reply(message)
end, true)
