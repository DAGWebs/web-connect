function WebConnect.Http.Respond(response, status, body)
    response.writeHead(status, {
        ['Content-Type'] = 'application/json; charset=utf-8',
        ['Cache-Control'] = 'no-store',
        ['X-Content-Type-Options'] = 'nosniff'
    })
    response.send(json.encode(body))
end

function WebConnect.Http.RespondHtml(response, status, body)
    response.writeHead(status, {
        ['Content-Type'] = 'text/html; charset=utf-8',
        ['Cache-Control'] = 'no-store',
        ['X-Content-Type-Options'] = 'nosniff'
    })
    response.send(body)
end
