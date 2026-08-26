function WebConnect.Http.PathOnly(path)
    return (path or '/'):match('^[^?]*')
end

function WebConnect.Http.DecodeObject(raw)
    local ok, payload = pcall(json.decode, raw)
    if not ok or type(payload) ~= 'table' then return nil end
    return payload
end

function WebConnect.Http.ReadBody(request, response, callback)
    local received = 0
    local chunks = {}
    local finished = false

    request.setDataHandler(function(chunk)
        if finished then return end
        chunk = chunk or ''
        received = received + #chunk

        if received > Config.MaxBodyBytes then
            finished = true
            WebConnect.Http.Respond(response, 413, { error = 'request_too_large' })
            return
        end

        chunks[#chunks + 1] = chunk
        if chunk ~= '' then return end

        finished = true
        callback(table.concat(chunks))
    end)
end
