-- The client requires main.lua at the plugin root. All implementation lives in src/.
local shutdown = require("src/main").start()

-- Keep the client lifecycle hook at the entry point; the app owns its cleanup.
function PluginShutdown()
    shutdown()
end
