local entries = {}
local ttlSeconds = 300

local function composite(principal, eventName, key)
    if type(key) ~= 'string' or key == '' or #key > 128 then return nil end
    return principal.id .. ':' .. eventName .. ':' .. key
end

function WebConnect.Http.IdempotencyLookup(principal, eventName, key)
    local id = composite(principal, eventName, key)
    if not id then return nil, nil end
    local entry = entries[id]
    if entry and entry.expiresAt > os.time() then return id, entry end
    entries[id] = { pending = true, expiresAt = os.time() + ttlSeconds }
    return id, nil
end

-- Only successful outcomes are replayed. Caching a failure would pin the key to
-- an error for the rest of the window, so a caller could never retry a request
-- that never took effect in the first place.
function WebConnect.Http.IdempotencyFinish(id, status, body)
    if not id then return end
    if (status or 500) >= 400 then
        entries[id] = nil
        return
    end
    entries[id] = { status = status, body = body, expiresAt = os.time() + ttlSeconds }
end

CreateThread(function()
    while true do
        Wait(ttlSeconds * 1000)
        local now = os.time()
        for id, entry in pairs(entries) do
            if entry.expiresAt <= now then entries[id] = nil end
        end
    end
end)
