local website = Config.Website or { Enabled = false }
local codes = {}

local function baseUrl()
    return (website.Url or ''):gsub('/+$', '')
end

-- A caller may choose a path on the configured site. It may not choose a site:
-- anything with a scheme, an authority, or a parent-directory escape is refused,
-- so the in-game browser can only ever be pointed at the server's own origin.
local function safePath(value)
    if value == nil or value == '' then return '/' end
    if type(value) ~= 'string' or #value > 200 then return nil end
    if not value:match('^/') then value = '/' .. value end
    if value:match('^//') then return nil end
    if value:match('%.%.') then return nil end
    if not value:match('^[%w%-%._~/%?=&%%+#]+$') then return nil end
    return value
end

local function newCode()
    local alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'
    local parts = {}
    for index = 1, 24 do
        local position = math.random(1, #alphabet)
        parts[index] = alphabet:sub(position, position)
    end
    return table.concat(parts)
end

local function pruneCodes()
    local now = os.time()
    for code, entry in pairs(codes) do
        if entry.expiresAt <= now then codes[code] = nil end
    end
end

local function issueCode(playerId)
    local player = WebConnect.GetPlayer(playerId)
    if not player then return nil end
    pruneCodes()
    local code = newCode()
    codes[code] = {
        playerId = playerId,
        name = player.name,
        identifiers = player.identifiers,
        expiresAt = os.time() + (tonumber(website.LinkCodeTtlSeconds) or 300)
    }
    return code
end

function WebConnect.RedeemLinkCode(code)
    pruneCodes()
    local entry = codes[code]
    if not entry then return nil end
    -- Single use: redeeming consumes the code whether or not the player is still
    -- connected, so a leaked code cannot be replayed.
    codes[code] = nil
    if entry.expiresAt <= os.time() then return nil end
    return entry
end

function WebConnect.BuildWebsiteUrl(path, playerId)
    local url = baseUrl()
    if url == '' then return nil, 'website_not_configured' end
    local safe = safePath(path)
    if not safe then return nil, 'invalid_path' end
    url = url .. safe

    if website.LinkCode and playerId then
        local code = issueCode(playerId)
        if code then
            url = url .. (url:find('%?') and '&' or '?') .. 'code=' .. code
        end
    end
    return url
end

-- Opens the site for one player. Used by `/connect`, and registered as an action
-- so the website itself can push a page to someone in game.
function WebConnect.OpenWebsite(playerId, path)
    if not website.Enabled then return false, 'website_disabled' end
    if not WebConnect.GetPlayer(playerId) then return false, 'player_not_found' end

    local url, reason = WebConnect.BuildWebsiteUrl(path, playerId)
    if not url then return false, reason end

    if website.Mode == 'chat' then
        TriggerClientEvent('chat:addMessage', playerId, {
            color = { 255, 180, 0 },
            args = { website.Title or 'WEBSITE', url }
        })
        return true, nil, url
    end

    TriggerClientEvent('web-connect:openWebsite', playerId, {
        url = url,
        title = website.Title or 'Website'
    })
    return true, nil, url
end

function WebConnect.CloseWebsite(playerId)
    TriggerClientEvent('web-connect:closeWebsite', playerId)
end

WebConnect.RegisterAction({
    name = 'openWebsite',
    aliases = { 'website' },
    usage = 'openWebsite:<path>',
    description = 'Open the server website on the player screen'
}, function(arguments, context)
    -- Rejoin with ':' so query strings survive the action-string split.
    local path = #arguments > 0 and table.concat(arguments, ':') or '/'
    local ok, reason = WebConnect.OpenWebsite(context.playerId, path)
    if not ok then
        return { status = reason == 'invalid_path' and 422 or 409, error = reason }
    end
    return { status = 200, data = { opened = true, path = path } }
end)

WebConnect.Register({
    name = 'redeem_link',
    summary = 'Exchange a single-use link code for the player it identifies',
    description = 'Lets the website sign in the player who ran the in-game command.',
    scopes = { 'action:execute' },
    schema = {
        type = 'object', required = { 'code' }, additionalProperties = false,
        properties = { code = { type = 'string', minLength = 8, maxLength = 64 } }
    },
    handler = function(payload)
        if not website.LinkCode then return { status = 404, error = 'link_codes_disabled' } end
        local entry = WebConnect.RedeemLinkCode(payload.code)
        if not entry then return { status = 404, error = 'unknown_or_expired_code' } end
        return {
            status = 200,
            data = {
                playerId = entry.playerId,
                name = entry.name,
                identifiers = entry.identifiers,
                online = WebConnect.GetPlayer(entry.playerId) ~= nil
            }
        }
    end
}, nil, GetCurrentResourceName())

exports('OpenWebsite', WebConnect.OpenWebsite)
exports('CloseWebsite', WebConnect.CloseWebsite)
exports('RedeemLinkCode', WebConnect.RedeemLinkCode)
