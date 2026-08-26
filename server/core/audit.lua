local RESOURCE = GetCurrentResourceName()
local FILE = 'data/audit.json'
local entries = {}

local function loadEntries()
    local contents = LoadResourceFile(RESOURCE, FILE)
    if not contents then return end
    local ok, document = pcall(json.decode, contents)
    if ok and type(document) == 'table' and type(document.entries) == 'table' then
        entries = document.entries
    end
end

local function persist()
    local document = json.encode({ version = 1, entries = entries })
    if not SaveResourceFile(RESOURCE, FILE, document, #document) then
        WebConnect.Log(('unable to persist %s'):format(FILE))
    end
end

function WebConnect.RecordAudit(entry)
    entry.timestamp = os.date('!%Y-%m-%dT%H:%M:%SZ')
    entries[#entries + 1] = entry
    while #entries > Config.AuditMaxEntries do table.remove(entries, 1) end
    persist()
    TriggerEvent('web-connect:audit', entry)
end

function WebConnect.GetAuditEntries(limit)
    limit = math.max(1, math.min(math.tointeger(tonumber(limit)) or Config.AuditDefaultView, 100))
    local result = {}
    for index = math.max(1, #entries - limit + 1), #entries do result[#result + 1] = entries[index] end
    return result
end

exports('GetAuditEntries', WebConnect.GetAuditEntries)
AddEventHandler('web-connect:recordAudit', WebConnect.RecordAudit)

loadEntries()
