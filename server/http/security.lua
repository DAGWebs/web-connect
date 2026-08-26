local clients = {}

local function secureEquals(left, right)
    if type(left) ~= 'string' or type(right) ~= 'string' then return false end
    local different = #left ~ #right
    for index = 1, math.max(#left, #right) do
        different = different | ((left:byte(index) or 0) ~ (right:byte(index) or 0))
    end
    return different == 0
end

local function bearerToken(headers)
    local value = (headers or {}).authorization or (headers or {}).Authorization
    return type(value) == 'string' and value:match('^[Bb]earer%s+(.+)$') or nil
end

function WebConnect.Http.GetBearerToken()
    return GetConvar(Config.TokenConvar, '')
end

function WebConnect.Http.Authenticate(headers)
    local supplied = bearerToken(headers)
    if not supplied then return nil, 'unauthorized' end
    local configured = WebConnect.Http.GetBearerToken()
    if configured ~= '' and secureEquals(supplied, configured) then
        return { id = 'convar', name = 'server convar', scopes = { '*' } }
    end
    local ok, principal = pcall(function()
        return exports[GetCurrentResourceName()]:AuthenticateBearer(supplied)
    end)
    if ok and principal then return principal end
    if configured == '' then
        local checked, hasKeys = pcall(function() return exports[GetCurrentResourceName()]:HasBearerTokens() end)
        if not checked or not hasKeys then return nil, 'api_not_configured' end
    end
    return nil, 'unauthorized'
end


function WebConnect.Http.TokenConfigured()
    if WebConnect.Http.GetBearerToken() ~= '' then return true end
    local ok, value = pcall(function() return exports[GetCurrentResourceName()]:HasBearerTokens() end)
    return ok and value or false
end

function WebConnect.Http.HasScope(principal, required)
    for _, held in ipairs(principal.scopes or {}) do
        if held == '*' or held == required then return true end
        if held:sub(-1) == '*' and required:sub(1, #held - 1) == held:sub(1, -2) then return true end
    end
    return false
end

function WebConnect.Http.WithinRateLimit(address)
    local now = os.time()
    local client = clients[address]
    if not client or now - client.startedAt >= Config.RateLimit.windowSeconds then
        clients[address] = { startedAt = now, requests = 1 }
        return true
    end
    client.requests = client.requests + 1
    return client.requests <= Config.RateLimit.requests
end

CreateThread(function()
    while true do
        Wait(Config.RateLimit.windowSeconds * 1000)
        local cutoff = os.time() - Config.RateLimit.windowSeconds
        for address, client in pairs(clients) do
            if client.startedAt < cutoff then clients[address] = nil end
        end
    end
end)
