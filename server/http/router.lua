local RESOURCE = GetCurrentResourceName()
local prefix = Config.RoutePrefix:gsub('/+$', '')
local escapedPrefix = prefix:gsub('([^%w])', '%%%1')
local actionPrefix = Config.ActionApiPrefix:gsub('/+$', '')
local escapedActionPrefix = actionPrefix:gsub('([^%w])', '%%%1')
local requestCounter = 0

local function requestId()
    requestCounter = requestCounter + 1
    return ('%x-%x-%x'):format(os.time(), GetGameTimer(), requestCounter)
end

local function reject(response, status, errorCode, id, details)
    WebConnect.Http.Respond(response, status, { error = errorCode, requestId = id, details = details })
end

local function actionString(name, arguments)
    local parts = { Config.ActionPrefix, name }
    for _, value in ipairs(arguments or {}) do
        if type(value) ~= 'string' and type(value) ~= 'number' then return nil end
        parts[#parts + 1] = tostring(value)
    end
    return table.concat(parts, ':')
end

local function runApiAction(command, defaultPlayerId, principal, requestContext)
    if type(command) ~= 'table' then return { status = 422, error = 'invalid_command' } end
    local playerId = math.tointeger(tonumber(command.playerId or defaultPlayerId))
    if not playerId or not WebConnect.GetPlayer(playerId) then
        return { status = 404, error = 'player_not_found' }
    end
    local value = command.action
    if command.name then value = actionString(command.name, command.arguments) end
    if not value then return { status = 422, error = 'invalid_action_arguments' } end
    return WebConnect.ExecuteAction(value, {
        playerId = playerId,
        source = playerId,
        principal = { id = principal.id, name = principal.name },
        request = requestContext
    })
end

SetHttpHandler(function(request, response)
    local id = requestId()
    local path = WebConnect.Http.PathOnly(request.path)

    if request.method == 'GET' and path == prefix .. '/health' then
        WebConnect.Http.Respond(response, 200, {
            ok = true, resource = RESOURCE, version = GetResourceMetadata(RESOURCE, 'version', 0),
            framework = WebConnect.FrameworkStatus(), tokenConfigured = WebConnect.Http.TokenConfigured(),
            registeredEvents = WebConnect.CountEvents(), requestId = id
        })
        return
    end

    if Config.DocsEnabled and request.method == 'GET' and path == prefix .. '/openapi.json' then
        WebConnect.Http.Respond(response, 200, WebConnect.Http.OpenApi(prefix))
        return
    end
    if Config.DocsEnabled and request.method == 'GET' and (path == prefix .. '/docs' or path == prefix .. '/docs/') then
        WebConnect.Http.RespondHtml(response, 200, WebConnect.Http.ScalarPage(prefix))
        return
    end

    if request.method == 'GET' and path == prefix .. '/actions' then
        local principal, authError = WebConnect.Http.Authenticate(request.headers)
        if not principal then
            reject(response, authError == 'api_not_configured' and 503 or 401, authError, id)
            return
        end
        if not WebConnect.Http.HasScope(principal, 'action:execute') then
            reject(response, 403, 'insufficient_scope', id)
            return
        end
        WebConnect.Http.Respond(response, 200, { data = WebConnect.ListActions(), requestId = id })
        return
    end

    local directAction = path:match('^' .. escapedActionPrefix .. '/([%w_-]+)$')
    if request.method == 'POST' and directAction then
        local address = request.address or 'unknown'
        if not WebConnect.Http.WithinRateLimit(address) then reject(response, 429, 'rate_limit_exceeded', id) return end
        local principal, authError = WebConnect.Http.Authenticate(request.headers)
        if not principal then reject(response, authError == 'api_not_configured' and 503 or 401, authError, id) return end
        if not WebConnect.Http.HasScope(principal, 'action:execute') then reject(response, 403, 'insufficient_scope', id) return end

        WebConnect.Http.ReadBody(request, response, function(raw)
            local payload = WebConnect.Http.DecodeObject(raw)
            if not payload then reject(response, 400, 'invalid_json', id) return end
            local requestContext = { requestId = id, address = address, apiEvent = 'action:' .. directAction }

            if directAction:lower() == 'batch' then
                if type(payload.commands) ~= 'table' or #payload.commands < 1
                    or #payload.commands > Config.MaxBatchActions then
                    reject(response, 422, 'invalid_batch', id)
                    return
                end
                local headers = request.headers or {}
                local idempotencyId, cached = WebConnect.Http.IdempotencyLookup(
                    principal, 'api:batch', headers['idempotency-key'] or headers['Idempotency-Key']
                )
                if cached then
                    if cached.pending then reject(response, 409, 'request_in_progress', id) return end
                    WebConnect.Http.Respond(response, cached.status, cached.body)
                    return
                end
                local results, status = {}, 200
                for index, command in ipairs(payload.commands) do
                    local result = runApiAction(command, payload.playerId, principal, requestContext)
                    results[index] = result
                    if (result.status or 500) >= 400 then status = 207 end
                    if payload.stopOnError and (result.status or 500) >= 400 then break end
                end
                local body = { data = results, requestId = id }
                WebConnect.Http.IdempotencyFinish(idempotencyId, status, body)
                WebConnect.Http.Respond(response, status, body)
                return
            end

            local headers = request.headers or {}
            local idempotencyId, cached = WebConnect.Http.IdempotencyLookup(
                principal, 'api:' .. directAction, headers['idempotency-key'] or headers['Idempotency-Key']
            )
            if cached then
                if cached.pending then reject(response, 409, 'request_in_progress', id) return end
                WebConnect.Http.Respond(response, cached.status, cached.body)
                return
            end
            local result = runApiAction({
                name = directAction,
                arguments = payload.arguments,
                playerId = payload.playerId
            }, nil, principal, requestContext)
            local body = result.error
                and { error = result.error, details = result.data, requestId = id }
                or { data = result.data, requestId = id }
            WebConnect.Http.IdempotencyFinish(idempotencyId, result.status or 200, body)
            WebConnect.Http.Respond(response, result.status or 200, body)
        end)
        return
    end

    local publicName = path:match('^' .. escapedPrefix .. '/events/([%w_-]+)$')
    if request.method ~= 'POST' or not publicName then reject(response, 404, 'not_found', id) return end

    local address = request.address or 'unknown'
    if not WebConnect.Http.WithinRateLimit(address) then reject(response, 429, 'rate_limit_exceeded', id) return end

    local principal, authError = WebConnect.Http.Authenticate(request.headers)
    if not principal then
        reject(response, authError == 'api_not_configured' and 503 or 401, authError, id)
        return
    end

    local route = WebConnect.GetRoute(publicName)
    if not route then reject(response, 404, 'unknown_event', id) return end
    local requiredScope = route.scopes[1] or ('event:' .. publicName)
    if not WebConnect.Http.HasScope(principal, requiredScope) then reject(response, 403, 'insufficient_scope', id) return end

    WebConnect.Http.ReadBody(request, response, function(raw)
        local payload = WebConnect.Http.DecodeObject(raw)
        if not payload then reject(response, 400, 'invalid_json', id) return end
        local valid, validationError = WebConnect.Validate(payload, route.schema)
        if not valid then reject(response, 422, 'validation_failed', id, validationError) return end

        local headers = request.headers or {}
        local idempotencyId, cached = WebConnect.Http.IdempotencyLookup(
            principal,
            publicName,
            headers['idempotency-key'] or headers['Idempotency-Key']
        )
        if cached then
            if cached.pending then reject(response, 409, 'request_in_progress', id) return end
            WebConnect.Http.Respond(response, cached.status, cached.body)
            return
        end

        local context = {
            requestId = id, address = address, apiEvent = publicName,
            framework = WebConnect.FrameworkName(), principal = { id = principal.id, name = principal.name }
        }
        local startedAt = os.clock()
        WebConnect.Dispatch(publicName, payload, context, function(status, data, errorCode)
            local durationMs = math.floor((os.clock() - startedAt) * 1000)
            TriggerEvent('web-connect:requestCompleted', id, status, durationMs, context)
            local body = errorCode
                and { error = errorCode, requestId = id, details = data }
                or { data = data, requestId = id }
            WebConnect.Http.IdempotencyFinish(idempotencyId, status, body)
            WebConnect.Http.Respond(response, status, body)
        end)
    end)
end)
