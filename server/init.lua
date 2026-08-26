CreateThread(function()
    Wait(0)
    if GetConvar(Config.TokenConvar, '') == '' then
        WebConnect.Log(('WARNING: set convar %q before using the HTTP API'):format(Config.TokenConvar))
    else
        WebConnect.Log(('HTTP API ready under %s'):format(Config.RoutePrefix))
    end
end)
