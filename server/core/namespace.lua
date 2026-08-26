WebConnect = WebConnect or {}
WebConnect.Http = WebConnect.Http or {}

function WebConnect.Log(message)
    print(('[%s] %s'):format(GetCurrentResourceName(), message))
end
