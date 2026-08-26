local clients = {}

-- Scopes are canonically `event:<name>` and `action:execute`. `events:*` was
-- documented as the grant-everything event scope in earlier versions, so it is
-- accepted as an alias for `event:*` rather than silently authorising nothing.
local scopeAliases = {
    ['events:*'] = 'event:*',
    ['events:'] = 'event:'
}

local function secureEquals(left, right)
    if type(left) ~= 'string' or type(right) ~= 'string' then return false end
    local different = #left ~ #right
    for index = 1, math.max(#left, #right) do
        different = different | ((left:byte(index) or 0) ~ (right:byte(index) or 0))
    end
    return different == 0
end

-- FiveM does not normalise header casing, so look the name up case-insensitively.
function WebConnect.Http.Header(headers, name)
    if type(headers) ~= 'table' then return nil end
    local wanted = name:lower()
    for key, value in pairs(headers) do
        if type(key) == 'string' and key:lower() == wanted then return value end
    end
    return nil
end

local function bearerToken(headers)
    local value = WebConnect.Http.Header(headers, 'authorization')
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

function WebConnect.Http.NormalizeScope(scope)
    if type(scope) ~= 'string' then return nil end
    return scopeAliases[scope] or scope
end

function WebConnect.Http.HasScope(principal, required)
    required = WebConnect.Http.NormalizeScope(required)
    if not required then return false end
    for _, granted in ipairs((principal or {}).scopes or {}) do
        local held = WebConnect.Http.NormalizeScope(granted)
        if held then
            if held == '*' or held == required then return true end
            -- `a:*` grants every scope beginning with `a:`.
            if held:sub(-1) == '*' and required:sub(1, #held - 1) == held:sub(1, -2) then return true end
        end
    end
    return false
end

-- A route may declare several acceptable scopes; holding any one is enough.
function WebConnect.Http.HasAnyScope(principal, required)
    if type(required) ~= 'table' or #required == 0 then return true end
    for _, scope in ipairs(required) do
        if WebConnect.Http.HasScope(principal, scope) then return true end
    end
    return false
end

-- Two buckets. Unauthenticated traffic is limited per address, because that is
-- the only identity available. Authenticated traffic is limited per credential:
-- a website's requests all arrive from one backend address, so metering those by
-- address would cap the entire site at one caller's budget.
function WebConnect.Http.WithinRateLimit(key, limit)
    local now = os.time()
    local client = clients[key]
    if not client or now - client.startedAt >= Config.RateLimit.windowSeconds then
        clients[key] = { startedAt = now, requests = 1 }
        return true
    end
    client.requests = client.requests + 1
    return client.requests <= limit
end

function WebConnect.Http.WithinAddressRateLimit(address)
    return WebConnect.Http.WithinRateLimit('address:' .. tostring(address), Config.RateLimit.anonymousRequests)
end

function WebConnect.Http.WithinPrincipalRateLimit(principal)
    return WebConnect.Http.WithinRateLimit('principal:' .. tostring(principal.id), Config.RateLimit.requests)
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
