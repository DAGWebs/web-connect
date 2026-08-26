local actions = {}

-- `/api/batch` is the batch endpoint, so an action of that name would register
-- successfully and then be permanently unreachable over HTTP.
local reservedNames = { batch = true }

-- Lookups only fold case. Stripping unexpected characters instead would mean
-- `give$Cash` silently resolved to the registered `giveCash`.
local function lookupKey(name)
    return type(name) == 'string' and name:lower() or nil
end

local function validActionName(name)
    return type(name) == 'string' and name ~= '' and #name <= 64
        and name:match('^[%w_%-]+$') ~= nil
end

local function register(definition, handler, owner)
    if type(definition) == 'string' then definition = { name = definition } end
    if not validActionName(definition.name) or type(handler) ~= 'function' then
        return false, 'invalid_action'
    end
    local name = lookupKey(definition.name)
    if reservedNames[name] then return false, 'reserved_action_name' end
    owner = owner or GetInvokingResource() or GetCurrentResourceName()
    if actions[name] and actions[name].owner ~= owner then return false, 'action_already_registered' end
    actions[name] = {
        name = definition.name,
        handler = handler,
        owner = owner,
        description = definition.description or 'No description provided',
        usage = definition.usage or definition.name
    }
    for _, alias in ipairs(definition.aliases or {}) do
        local aliasName = validActionName(alias) and lookupKey(alias) or nil
        if aliasName and not reservedNames[aliasName] then
            actions[aliasName] = actions[name]
        end
    end
    WebConnect.BumpRevision()
    return true
end

local function split(value)
    local result = {}
    for part in value:gmatch('[^:]+') do result[#result + 1] = part end
    return result
end

function WebConnect.ParseAction(value)
    if type(value) ~= 'string' or #value > 256 then return nil, 'invalid_action_string' end
    local parts = split(value)
    if parts[1] and parts[1]:lower() == Config.ActionPrefix:lower() then table.remove(parts, 1) end
    local name = lookupKey(table.remove(parts, 1))
    if not name or not actions[name] then return nil, 'unknown_action' end
    return { name = name, arguments = parts, registration = actions[name] }
end

function WebConnect.ExecuteAction(value, context)
    local parsed, reason = WebConnect.ParseAction(value)
    if not parsed then
        WebConnect.RecordAudit({
            action = value, playerId = context.playerId, actor = context.principal,
            requestId = context.request and context.request.requestId, status = 400, error = reason
        })
        return { status = 400, error = reason }
    end
    context.action = parsed.name
    context.actionOwner = parsed.registration.owner
    local ok, result = pcall(parsed.registration.handler, parsed.arguments, context)
    if not ok then
        WebConnect.Log(('action %q failed: %s'):format(parsed.name, result))
        result = { status = 500, error = 'action_failed' }
    end
    result = result or { status = 200, data = { completed = true, action = parsed.name } }
    WebConnect.RecordAudit({
        action = parsed.registration.name,
        arguments = parsed.arguments,
        playerId = context.playerId,
        actor = context.principal,
        requestId = context.request and context.request.requestId,
        status = result.status or 200,
        error = result.error
    })
    return result
end

function WebConnect.ListActions()
    local result, seen = {}, {}
    for _, action in pairs(actions) do
        if not seen[action] then
            seen[action] = true
            result[#result + 1] = {
                name = action.name,
                description = action.description,
                usage = Config.ActionPrefix .. ':' .. action.usage,
                owner = action.owner
            }
        end
    end
    table.sort(result, function(left, right) return left.name:lower() < right.name:lower() end)
    return result
end

exports('RegisterAction', function(definition, handler)
    return register(definition, handler, GetInvokingResource())
end)

exports('ExecuteAction', function(action, context)
    return WebConnect.ExecuteAction(action, context or {})
end)
exports('GetActions', WebConnect.ListActions)

AddEventHandler('onResourceStop', function(resource)
    local removed = false
    for name, action in pairs(actions) do
        if action.owner == resource then
            actions[name] = nil
            removed = true
        end
    end
    if removed then WebConnect.BumpRevision() end
end)

WebConnect.RegisterAction = register
