local RESOURCE = GetCurrentResourceName()
local prefix = Config.RoutePrefix:gsub('/+$', '')
local escapedPrefix = prefix:gsub('([^%w])', '%%%1')

local function reject(response, status, errorCode)
    WebConnect.Http.Respond(response, status, { error = errorCode })
end

SetHttpHandler(function(request, response)
    local path = WebConnect.Http.PathOnly(request.path)

    if request.method == 'GET' and path == prefix .. '/health' then
        WebConnect.Http.Respond(response, 200, { ok = true, resource = RESOURCE })
        return
    end

    local publicName = path:match('^' .. escapedPrefix .. '/events/([%w_-]+)$')
    if request.method ~= 'POST' or not publicName then
        reject(response, 404, 'not_found')
        return
    end

    local authenticated, authError = WebConnect.Http.Authenticated(request.headers)
    if not authenticated then
        local status = authError == 'api_not_configured' and 503 or 401
        if status == 503 then
            WebConnect.Log(('refusing API request: convar %q is not configured'):format(Config.TokenConvar))
        end
        reject(response, status, authError)
        return
    end

    local address = request.address or 'unknown'
    if not WebConnect.Http.WithinRateLimit(address) then
        reject(response, 429, 'rate_limit_exceeded')
        return
    end

    if not WebConnect.HasEvent(publicName) then
        reject(response, 404, 'unknown_event')
        return
    end

    WebConnect.Http.ReadBody(request, response, function(raw)
        local payload = WebConnect.Http.DecodeObject(raw)
        if not payload then
            reject(response, 400, 'invalid_json')
            return
        end

        local dispatched, reason = WebConnect.Dispatch(publicName, payload, {
            address = address,
            apiEvent = publicName,
            framework = WebConnect.FrameworkName()
        })

        if not dispatched then
            reject(response, 404, reason)
            return
        end

        if Config.Debug then WebConnect.Log(('accepted API event %q from %s'):format(publicName, address)) end
        WebConnect.Http.Respond(response, 202, { accepted = true, event = publicName })
    end)
end)
