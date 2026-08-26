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
Config.RequestTimeoutMs = 10000
Config.DocsEnabled = true
Config.RateLimit = {
    requests = 30,
    windowSeconds = 60
}

-- Integrations --------------------------------------------------------------

-- Public API names are explicitly mapped to local server events. Never accept an
-- arbitrary event name from a remote caller.
Config.Events = {
    announcement = {
        event = 'web-connect:announcement',
        summary = 'Broadcast an announcement',
        schema = {
            type = 'object',
            required = { 'message' },
            additionalProperties = false,
            properties = {
                message = { type = 'string', minLength = 1, maxLength = 500 },
                title = { type = 'string', minLength = 1, maxLength = 500 }
            }
        }
    },
    notify_player = {
        event = 'web-connect:notifyPlayer',
        summary = 'Notify one online player',
        schema = {
            type = 'object',
            required = { 'playerId', 'message' },
            additionalProperties = false,
            properties = {
                playerId = { type = 'integer', minimum = 1 },
                message = { type = 'string', minLength = 1, maxLength = 500 },
                type = { type = 'string', maxLength = 30 },
                duration = { type = 'integer', minimum = 1000, maximum = 30000 }
            }
        }
    }
}

Config.Debug = false

-- Actions -------------------------------------------------------------------

-- Website payloads can use strings such as `connect:giveCash:1000` and
-- `connect:giveCar:adder`. Only actions registered below or by another resource
-- can execute; this is intentionally not an arbitrary export/event executor.
Config.ActionPrefix = 'connect'
Config.MaxMoneyAction = 1000000
Config.MaxItemAction = 1000

-- Declarative adapters make paid, free, and custom scripts usable without
-- changing web-connect. Argument tokens: $source, $playerId, $arg1..$arg9,
-- $plate. The VMS example calls giveVehicle(source, owner, type, model, plate).
Config.ActionConnectors = {
    {
        name = 'giveCar',
        resource = 'vms_garagesv2',
        export = 'giveVehicle',
        minArguments = 1,
        maxArguments = 1,
        usage = 'giveCar:<model>',
        arguments = { '$source', '$playerId', 'vehicle', '$arg1', '$plate' },
        description = 'Give a vehicle through VMS Garages V2'
    }
}
