Config = {}

-- Authentication ------------------------------------------------------------

-- Set this with `set web_connect_token "a-long-random-secret"` in server.cfg.
-- Keeping secrets out of resource files prevents them from being committed.
Config.TokenConvar = 'web_connect_token'

-- HTTP ----------------------------------------------------------------------

-- The route prefix served on the same host and TCP endpoint as the FiveM server.
Config.RoutePrefix = '/web-connect'

-- auto, standalone, esx, qbcore, qbus, qbox, or vrp. Auto-detection prefers
-- Qbox over QBCore when both compatibility resources are running.
Config.Framework = 'auto'

Config.MaxBodyBytes = 64 * 1024
Config.RateLimit = {
    requests = 30,
    windowSeconds = 60
}

-- Integrations --------------------------------------------------------------

-- Public API names are explicitly mapped to local server events. Never accept an
-- arbitrary event name from a remote caller.
Config.Events = {
    announcement = 'web-connect:announcement',
    notify_player = 'web-connect:notifyPlayer'
}

Config.Debug = false
