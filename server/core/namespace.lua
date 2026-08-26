WebConnect = WebConnect or {}
WebConnect.Http = WebConnect.Http or {}

-- Bumped whenever the event or action registry changes so derived documents
-- (the OpenAPI schema) can be cached instead of rebuilt per request.
local revision = 0

function WebConnect.BumpRevision()
    revision = revision + 1
    return revision
end

function WebConnect.Revision()
    return revision
end

function WebConnect.Log(message)
    print(('[%s] %s'):format(GetCurrentResourceName(), message))
end
