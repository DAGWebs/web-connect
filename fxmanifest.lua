fx_version 'cerulean'
game 'gta5'

author 'web-connect contributors'
description 'Authenticated HTTP bridge for triggering allow-listed FiveM server events'
version '2.3.0'

server_only 'yes'

server_scripts {
    'server/token-manager.js',
    'config.lua',
    'server/core/namespace.lua',
    'server/core/schema.lua',
    'server/integrations/framework.lua',
    'server/core/registry.lua',
    'server/core/audit.lua',
    'server/core/actions.lua',
    'server/integrations/builtins.lua',
    'server/integrations/actions.lua',
    'server/http/response.lua',
    'server/http/security.lua',
    'server/http/idempotency.lua',
    'server/http/request.lua',
    'server/http/openapi.lua',
    'server/http/router.lua',
    'server/init.lua'
}
