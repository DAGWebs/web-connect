local function eventPaths(prefix)
    local paths = {}
    for publicName, route in pairs(WebConnect.ListEvents()) do
        paths[prefix .. '/events/' .. publicName] = {
            post = {
                operationId = 'dispatch_' .. publicName,
                summary = route.summary,
                description = route.description,
                tags = route.tags,
                security = { { bearerAuth = {} } },
                parameters = {
                    {
                        name = 'Idempotency-Key', ['in'] = 'header', required = false,
                        description = 'Prevents duplicate execution for five minutes.',
                        schema = { type = 'string', maxLength = 128 }
                    }
                },
                requestBody = {
                    required = true,
                    content = {
                        ['application/json'] = {
                            schema = route.schema
                        }
                    }
                },
                responses = {
                    ['202'] = { description = 'Event accepted' },
                    ['400'] = { description = 'Invalid JSON payload' },
                    ['409'] = { description = 'A request with this idempotency key is still running' },
                    ['401'] = { description = 'Invalid or missing bearer token' },
                    ['403'] = { description = 'API key lacks the required scope' },
                    ['404'] = { description = 'Event is not registered' },
                    ['413'] = { description = 'Request body is too large' },
                    ['422'] = { description = 'Payload failed schema validation' },
                    ['429'] = { description = 'Rate limit exceeded' },
                    ['500'] = { description = 'Integration handler failed' },
                    ['504'] = { description = 'Integration handler timed out' }
                }
            }
        }
    end
    return paths
end

local function actionPaths(prefix)
    local paths = {}
    for _, action in ipairs(WebConnect.ListActions()) do
        paths[prefix .. '/' .. action.name:lower()] = {
            post = {
                summary = action.description,
                description = 'Usage: ' .. action.usage,
                tags = { 'Actions' },
                security = { { bearerAuth = {} } },
                requestBody = {
                    required = true,
                    content = { ['application/json'] = { schema = {
                        type = 'object', required = { 'playerId' },
                        properties = {
                            playerId = { type = 'integer', minimum = 1 },
                            arguments = { type = 'array', items = { type = { 'string', 'number' } } }
                        }
                    } } }
                },
                responses = { ['200'] = { description = 'Action result' }, ['422'] = { description = 'Invalid arguments' } }
            }
        }
    end
    paths[prefix .. '/batch'] = {
        post = {
            summary = 'Execute multiple actions for one or more players',
            tags = { 'Actions' }, security = { { bearerAuth = {} } },
            responses = { ['200'] = { description = 'All actions completed' }, ['207'] = { description = 'One or more actions failed' } }
        }
    }
    return paths
end

local cachedRevision, cachedPrefix, cachedDocument

local function buildDocument(prefix)
    local paths = eventPaths(prefix)
    for path, operation in pairs(actionPaths(Config.ActionApiPrefix:gsub('/+$', ''))) do paths[path] = operation end
    paths[prefix .. '/health'] = {
        get = {
            summary = 'Check API availability',
            tags = { 'System' },
            responses = { ['200'] = { description = 'Resource is running' } }
        }
    }
    paths[prefix .. '/actions'] = {
        get = {
            summary = 'List available connect actions',
            tags = { 'Actions' },
            security = { { bearerAuth = {} } },
            responses = { ['200'] = { description = 'Available action names, usage, and descriptions' } }
        }
    }

    return {
        openapi = '3.1.0',
        info = {
            title = 'web-connect API',
            version = GetResourceMetadata(GetCurrentResourceName(), 'version', 0) or 'development',
            description = 'Authenticated website-to-FiveM event bridge.'
        },
        paths = paths,
        components = {
            securitySchemes = {
                bearerAuth = { type = 'http', scheme = 'bearer', bearerFormat = 'token' }
            }
        }
    }
end

-- The document only changes when an event or action is registered or removed,
-- so it is rebuilt on registry changes rather than on every unauthenticated
-- request to /openapi.json.
function WebConnect.Http.OpenApi(prefix)
    local revision = WebConnect.Revision()
    if cachedDocument and cachedRevision == revision and cachedPrefix == prefix then
        return cachedDocument
    end
    cachedDocument = buildDocument(prefix)
    cachedRevision = revision
    cachedPrefix = prefix
    return cachedDocument
end

function WebConnect.Http.ScalarPage(prefix)
    local specificationUrl = prefix .. '/openapi.json'
    return ([=[<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>web-connect API documentation</title>
</head>
<body>
  <script id="api-reference" data-url="%s"></script>
  <script src="https://cdn.jsdelivr.net/npm/@scalar/api-reference"></script>
</body>
</html>]=]):format(specificationUrl)
end
