-- A deliberately small subset of JSON Schema: enough to describe and enforce the
-- payloads this API accepts, and nothing that would need a full resolver.
local validate

local function matchesType(value, expected, path)
    if expected == nil then return true end

    -- OpenAPI 3.1 allows a union, e.g. { 'string', 'number' }.
    if type(expected) == 'table' then
        for _, candidate in ipairs(expected) do
            if matchesType(value, candidate, path) then return true end
        end
        return false, ('%s must be one of %s'):format(path, table.concat(expected, ', '))
    end

    if expected == 'object' or expected == 'array' then
        if type(value) ~= 'table' then return false, ('%s must be an %s'):format(path, expected) end
        return true
    end
    if expected == 'integer' then
        if type(value) ~= 'number' or math.tointeger(value) == nil then
            return false, path .. ' must be an integer'
        end
        return true
    end
    if expected == 'null' then
        if value ~= nil then return false, path .. ' must be null' end
        return true
    end
    if type(value) ~= expected then return false, ('%s must be a %s'):format(path, expected) end
    return true
end

local function isArray(value)
    local count = 0
    for key in pairs(value) do
        if type(key) ~= 'number' or key % 1 ~= 0 or key < 1 then return false end
        count = count + 1
    end
    return count == #value
end

validate = function(value, schema, path)
    path = path or '$'
    if not schema then return true end

    local ok, reason = matchesType(value, schema.type, path)
    if not ok then return false, reason end

    if schema.enum then
        local allowed = false
        for _, candidate in ipairs(schema.enum) do
            if value == candidate then allowed = true break end
        end
        if not allowed then return false, path .. ' is not an accepted value' end
    end

    if type(value) == 'string' then
        if schema.minLength and #value < schema.minLength then return false, path .. ' is too short' end
        if schema.maxLength and #value > schema.maxLength then return false, path .. ' is too long' end
        if schema.pattern and not value:match(schema.pattern) then
            return false, path .. ' has an invalid format'
        end
    end
    if type(value) == 'number' then
        if schema.minimum and value < schema.minimum then return false, path .. ' is too small' end
        if schema.maximum and value > schema.maximum then return false, path .. ' is too large' end
    end

    if schema.type == 'array' then
        if not isArray(value) then return false, path .. ' must be an array' end
        if schema.minItems and #value < schema.minItems then return false, path .. ' has too few items' end
        if schema.maxItems and #value > schema.maxItems then return false, path .. ' has too many items' end
        if schema.items then
            for index, item in ipairs(value) do
                local valid, itemReason = validate(item, schema.items, ('%s[%d]'):format(path, index))
                if not valid then return false, itemReason end
            end
        end
    end

    if schema.type == 'object' then
        for _, key in ipairs(schema.required or {}) do
            if value[key] == nil then return false, path .. '.' .. key .. ' is required' end
        end
        for key, child in pairs(schema.properties or {}) do
            if value[key] ~= nil then
                local valid, childReason = validate(value[key], child, path .. '.' .. key)
                if not valid then return false, childReason end
            end
        end
        if schema.additionalProperties == false then
            for key in pairs(value) do
                if not (schema.properties or {})[key] then return false, path .. '.' .. key .. ' is not allowed' end
            end
        end
    end

    return true
end

WebConnect.Validate = validate
