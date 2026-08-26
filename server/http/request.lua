function WebConnect.Http.PathOnly(path)
    return (path or '/'):match('^[^?]*')
end

function WebConnect.Http.DecodeObject(raw)
    local ok, payload = pcall(json.decode, raw)
    if not ok or type(payload) ~= 'table' then return nil end
    return payload
end

-- FiveM may hand the body over as a single chunk or as a stream terminated by an
-- empty chunk. Completing on Content-Length keeps both shapes working, and a
-- request declaring no body completes immediately instead of hanging until the
-- client gives up.
function WebConnect.Http.ReadBody(request, response, callback)
    local declared = math.tointeger(tonumber(WebConnect.Http.Header(request.headers, 'content-length')))
    if declared and declared > Config.MaxBodyBytes then
        WebConnect.Http.Respond(response, 413, { error = 'request_too_large' })
        return
    end
    if declared == 0 then
        callback('')
        return
    end

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
        if chunk ~= '' and not (declared and received >= declared) then return end

        finished = true
        callback(table.concat(chunks))
    end)
end
