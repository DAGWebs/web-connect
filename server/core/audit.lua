local RESOURCE = GetCurrentResourceName()
local FILE = 'data/audit.json'
local FLUSH_INTERVAL_MS = 5000
local entries = {}
local dirty = false

local function loadEntries()
    local contents = LoadResourceFile(RESOURCE, FILE)
    if not contents then return end
    local ok, document = pcall(json.decode, contents)
    if ok and type(document) == 'table' and type(document.entries) == 'table' then
        entries = document.entries
    end
end

local function flush()
    if not dirty then return end
    dirty = false
    local document = json.encode({ version = 1, entries = entries })
    if not SaveResourceFile(RESOURCE, FILE, document, #document) then
        WebConnect.Log(('unable to persist %s'):format(FILE))
    end
end

WebConnect.FlushAudit = flush

function WebConnect.RecordAudit(entry)
    entry.timestamp = os.date('!%Y-%m-%dT%H:%M:%SZ')
    entries[#entries + 1] = entry
    while #entries > Config.AuditMaxEntries do table.remove(entries, 1) end
    -- Re-encoding the whole log on every action would put a synchronous disk
    -- write on the main thread for each request, so writes are batched instead.
    dirty = true
    TriggerEvent('web-connect:audit', entry)
end

function WebConnect.GetAuditEntries(limit)
    limit = math.max(1, math.min(math.tointeger(tonumber(limit)) or Config.AuditDefaultView, 100))
    local result = {}
    for index = math.max(1, #entries - limit + 1), #entries do result[#result + 1] = entries[index] end
    return result
end

exports('GetAuditEntries', WebConnect.GetAuditEntries)
exports('FlushAudit', flush)
AddEventHandler('web-connect:recordAudit', WebConnect.RecordAudit)

AddEventHandler('onResourceStop', function(resource)
    if resource == RESOURCE then flush() end
end)

CreateThread(function()
    while true do
        Wait(FLUSH_INTERVAL_MS)
        flush()
    end
end)

loadEntries()
