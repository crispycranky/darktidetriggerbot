-- File: Targeter/scripts/mods/Targeter/Targeter.lua
local mod = get_mod("Targeter")
if not mod then return end
mod.version = "Targeter 1.6.0"

mod:io_dofile("Targeter/scripts/mods/Targeter/Targeter_init")
mod:io_dofile("Targeter/scripts/mods/Targeter/core/util")
mod:io_dofile("Targeter/scripts/mods/Targeter/core/profiles")
mod:io_dofile("Targeter/scripts/mods/Targeter/core/game_mode")
mod:io_dofile("Targeter/scripts/mods/Targeter/core/ads")
mod:io_dofile("Targeter/scripts/mods/Targeter/core/gear")
mod:io_dofile("Targeter/scripts/mods/Targeter/core/templates")
mod:io_dofile("Targeter/scripts/mods/Targeter/core/state")
mod:io_dofile("Targeter/scripts/mods/Targeter/core/selection")
mod:io_dofile("Targeter/scripts/mods/Targeter/core/ui")
mod:io_dofile("Targeter/scripts/mods/Targeter/core/autofire")   -- ← new

mod.on_all_mods_loaded = function()
    mod:info(mod.version)
end

-- Per-frame update: drives the autofire trigger logic.
-- DMF calls mod.update(dt) each frame.
mod.update = function(dt)
    mod.autofire_update(dt)
end