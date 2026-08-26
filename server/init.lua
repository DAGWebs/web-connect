CreateThread(function()
    Wait(0)
    if not WebConnect.Http.TokenConfigured() then
        WebConnect.Log(('WARNING: set convar %q or run webconnect_token create <name>'):format(Config.TokenConvar))
    else
        WebConnect.Log(('HTTP API ready under %s'):format(Config.RoutePrefix))
    end
end)
