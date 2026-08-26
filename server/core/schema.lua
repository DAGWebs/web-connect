local function validate(value, schema, path)
    path = path or '$'
    if not schema then return true end
    local expected = schema.type
    if expected == 'object' and type(value) ~= 'table' then return false, path .. ' must be an object' end
    if expected == 'array' and type(value) ~= 'table' then return false, path .. ' must be an array' end
    if expected == 'string' and type(value) ~= 'string' then return false, path .. ' must be a string' end
    if expected == 'number' and type(value) ~= 'number' then return false, path .. ' must be a number' end
    if expected == 'integer' and (type(value) ~= 'number' or math.tointeger(value) == nil) then return false, path .. ' must be an integer' end
    if expected == 'boolean' and type(value) ~= 'boolean' then return false, path .. ' must be a boolean' end

    if type(value) == 'string' then
        if schema.minLength and #value < schema.minLength then return false, path .. ' is too short' end
        if schema.maxLength and #value > schema.maxLength then return false, path .. ' is too long' end
    end
    if type(value) == 'number' then
        if schema.minimum and value < schema.minimum then return false, path .. ' is too small' end
        if schema.maximum and value > schema.maximum then return false, path .. ' is too large' end
    end
    if expected == 'object' then
        for _, key in ipairs(schema.required or {}) do
            if value[key] == nil then return false, path .. '.' .. key .. ' is required' end
        end
        for key, child in pairs(schema.properties or {}) do
            if value[key] ~= nil then
                local ok, reason = validate(value[key], child, path .. '.' .. key)
                if not ok then return false, reason end
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
