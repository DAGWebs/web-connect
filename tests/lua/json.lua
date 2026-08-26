-- Minimal JSON codec standing in for FiveM's `json` global inside tests.
local json = {}

local escapes = { ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f',
    ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }

local function quote(value)
    return '"' .. value:gsub('[%c"\\]', function(character)
        return escapes[character] or ('\\u%04x'):format(character:byte())
    end) .. '"'
end

local function isArray(value)
    local count = 0
    for key in pairs(value) do
        if type(key) ~= 'number' or key % 1 ~= 0 or key < 1 then return false end
        count = count + 1
    end
    return count == #value and count > 0
end

local function encode(value)
    local kind = type(value)
    if value == nil then return 'null' end
    if kind == 'boolean' then return tostring(value) end
    if kind == 'number' then
        if value ~= value or value == math.huge or value == -math.huge then return 'null' end
        if math.type(value) == 'integer' then return tostring(value) end
        return ('%.14g'):format(value)
    end
    if kind == 'string' then return quote(value) end
    if kind ~= 'table' then error('cannot encode ' .. kind) end

    local parts = {}
    if isArray(value) then
        for index = 1, #value do parts[index] = encode(value[index]) end
        return '[' .. table.concat(parts, ',') .. ']'
    end
    for key, item in pairs(value) do
        if type(key) == 'string' or type(key) == 'number' then
            parts[#parts + 1] = quote(tostring(key)) .. ':' .. encode(item)
        end
    end
    return '{' .. table.concat(parts, ',') .. '}'
end

local decodeValue

local function skipSpace(text, position)
    local _, stop = text:find('^[ \t\r\n]*', position)
    return stop + 1
end

local function decodeString(text, position)
    position = position + 1
    local buffer = {}
    while true do
        local character = text:sub(position, position)
        if character == '' then error('unterminated string') end
        if character == '"' then return table.concat(buffer), position + 1 end
        if character == '\\' then
            local escaped = text:sub(position + 1, position + 1)
            local map = { n = '\n', t = '\t', r = '\r', b = '\b', f = '\f',
                ['"'] = '"', ['\\'] = '\\', ['/'] = '/' }
            if escaped == 'u' then
                buffer[#buffer + 1] = utf8.char(tonumber(text:sub(position + 2, position + 5), 16))
                position = position + 6
            else
                buffer[#buffer + 1] = map[escaped] or escaped
                position = position + 2
            end
        else
            buffer[#buffer + 1] = character
            position = position + 1
        end
    end
end

decodeValue = function(text, position)
    position = skipSpace(text, position)
    local character = text:sub(position, position)

    if character == '"' then return decodeString(text, position) end
    if character == '{' then
        local result = {}
        position = skipSpace(text, position + 1)
        if text:sub(position, position) == '}' then return result, position + 1 end
        while true do
            local key, value
            position = skipSpace(text, position)
            key, position = decodeString(text, position)
            position = skipSpace(text, position)
            if text:sub(position, position) ~= ':' then error('expected :') end
            value, position = decodeValue(text, position + 1)
            result[key] = value
            position = skipSpace(text, position)
            local delimiter = text:sub(position, position)
            if delimiter == '}' then return result, position + 1 end
            if delimiter ~= ',' then error('expected , or }') end
            position = position + 1
        end
    end
    if character == '[' then
        local result = {}
        position = skipSpace(text, position + 1)
        if text:sub(position, position) == ']' then return result, position + 1 end
        while true do
            local value
            value, position = decodeValue(text, position)
            result[#result + 1] = value
            position = skipSpace(text, position)
            local delimiter = text:sub(position, position)
            if delimiter == ']' then return result, position + 1 end
            if delimiter ~= ',' then error('expected , or ]') end
            position = position + 1
        end
    end
    if text:sub(position, position + 3) == 'true' then return true, position + 4 end
    if text:sub(position, position + 4) == 'false' then return false, position + 5 end
    if text:sub(position, position + 3) == 'null' then return nil, position + 4 end

    local number = text:match('^-?%d+%.?%d*[eE]?[-+]?%d*', position)
    if number and number ~= '' then
        return tonumber(number), position + #number
    end
    error('unexpected character at ' .. position .. ': ' .. character)
end

json.encode = encode
function json.decode(text)
    if type(text) ~= 'string' then error('expected string') end
    local value = decodeValue(text, 1)
    return value
end

return json
