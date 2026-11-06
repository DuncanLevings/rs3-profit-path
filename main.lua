-- The client requires main.lua at the plugin root. All implementation lives in src/.
local shutdown = require("src/main").start()

-- The client calls this when the plugin is disabled or reloaded.
function PluginShutdown()
    shutdown()
end
