fx_version 'cerulean'
game 'gta5'

author 'web-connect contributors'
description 'Authenticated HTTP bridge for triggering allow-listed FiveM server events'
version '1.2.0'

server_only 'yes'

server_scripts {
    'config.lua',
    'server/core/namespace.lua',
    'server/integrations/framework.lua',
    'server/core/registry.lua',
    'server/integrations/builtins.lua',
    'server/http/response.lua',
    'server/http/security.lua',
    'server/http/request.lua',
    'server/http/router.lua',
    'server/init.lua'
}
