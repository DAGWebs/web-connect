local clients = {}

local function secureEquals(left, right)
    if type(left) ~= 'string' or type(right) ~= 'string' then return false end

    local different = #left ~ #right
    local length = math.max(#left, #right)
    for index = 1, length do
        different = different | ((left:byte(index) or 0) ~ (right:byte(index) or 0))
    end
    return different == 0
end

local function bearerToken(headers)
    local value = headers.authorization or headers.Authorization
    if type(value) ~= 'string' then return nil end
    return value:match('^[Bb]earer%s+(.+)$')
end

function WebConnect.Http.Authenticated(headers)
    local configuredToken = GetConvar(Config.TokenConvar, '')
    if configuredToken == '' then return false, 'api_not_configured' end
    if not secureEquals(bearerToken(headers or {}), configuredToken) then
        return false, 'unauthorized'
    end
    return true
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
