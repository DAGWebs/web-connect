CreateThread(function()
    Wait(0)
    if not WebConnect.Http.TokenConfigured() then
        WebConnect.Log(('WARNING: set convar %q or run webconnect_token create <name>'):format(Config.TokenConvar))
    else
        WebConnect.Log(('HTTP API ready under %s'):format(Config.RoutePrefix))
    end

    local website = Config.Website
    if website and website.Enabled then
        if not website.Url or website.Url == '' or website.Url:find('example%.com') then
            WebConnect.Log('WARNING: Config.Website.Url is unset; /connect has nowhere to go')
        elseif not website.Url:match('^https://') then
            WebConnect.Log('WARNING: Config.Website.Url is not https; the in-game browser may refuse it')
        end
    end
end)
