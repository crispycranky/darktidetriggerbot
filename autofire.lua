-- File: Targeter/scripts/mods/Targeter/core/autofire.lua
-- Automatic fire trigger: injects shoot input when Targeter's crosshair
-- detects a valid target. Supports both normal and charged weapons.
--
-- Normal weapons:  inject action_one_pressed + action_one_hold for one frame.
-- Charged weapons: player holds M1 to charge. When charge threshold is met
--                  AND a valid target is detected, the mod releases M1 for
--                  one frame to fire, then the player can re-hold to recharge.

local mod = get_mod("Targeter")
if not mod then return end

-- ── internal state ───────────────────────────────────────────────────────────
local _cooldown_remaining = 0
local _was_on_target      = false
local _diag_throttle_t    = 0

-- Tracks whether M2 is currently held by the real player input.
local _m2_held            = false
local _was_wielding_ranged = false  -- tracks wield state to detect swap

-- Forward declaration so the input hook can call it before it is defined.
local _is_valid_target

-- Normal weapon injection.
local _inject_fire        = false

-- Charged weapon: when true, override action_one_hold to false for one frame
-- to release the shot. The player's real M1 input is restored the next frame.
local _inject_release     = false

-- ── debug helper ─────────────────────────────────────────────────────────────
local function _dbg(...)
    if not mod:get("autofire_debug") then return end
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
    mod:echo("[AF] " .. table.concat(parts, " "))
end

-- ── input hook ───────────────────────────────────────────────────────────────
local function _input_hook(func, self, action_name)
    local value = func(self, action_name)

    -- Track real M2 state from player input.
    if action_name == "action_two_hold" and not _inject_release then
        _m2_held = value
    end

    -- Cancel any pending injection the moment the target is lost.
    -- The hook runs before autofire_update each frame, so without this check
    -- an injection armed on the previous frame would still fire.
    local valid_target = _is_valid_target and _is_valid_target()
    if not valid_target then
        _inject_fire    = false
        _inject_release = false
    end

    -- Normal weapon: single-frame press.
    if _inject_fire then
        if action_name == "action_one_pressed" then
            _inject_fire = false
            return true
        end
        if action_name == "action_one_hold" then
            return true
        end
    end

    -- Charged weapon release: drop M1 for one frame to fire.
    if _inject_release then
        if action_name == "action_one_hold" then
            _inject_release = false     -- consume — one frame only
            return false                -- drop the hold → weapon fires
        end
        if action_name == "action_one_release" then
            return true                 -- explicit release event on same frame
        end
    end

    return value
end

mod:hook(CLASS.InputService, "_get",          _input_hook)
mod:hook(CLASS.InputService, "_get_simulate", _input_hook)

-- ── weapon helpers ────────────────────────────────────────────────────────────

local function _is_wielding_ranged()
    if mod._carried_ranged_template and mod._last_wielded_slot == "slot_secondary" then
        return true
    end

    local pm = Managers and Managers.player
    local player = pm and pm:local_player_safe(1)
    local unit = player and player.player_unit
    if not unit then return false end

    local weapon_ext = ScriptUnit.has_extension(unit, "weapon_system")
    if not weapon_ext then return false end

    local inventory = weapon_ext._inventory_component
    if not inventory then return false end

    if inventory.wielded_slot ~= "slot_secondary" then return false end

    local weapons = weapon_ext._weapons
    local ranged = weapons and weapons.slot_secondary
    local tpl = ranged and ranged.weapon_template
    if tpl then
        mod._carried_ranged_template = tpl
        mod._last_wielded_slot = "slot_secondary"
        return true
    end

    return false
end

local function _is_charged_weapon()
    local tpl = mod._carried_ranged_template
    if not tpl then return false end

    -- A weapon is "charged" only if it has an action whose kind is explicitly
    -- a charge mechanic. "aim" and "zoom" are standard ADS and do not count —
    -- many non-charged lasguns have those. Only overload_charge and charge
    -- indicate a weapon that fires on M1 release after holding to charge.
    local actions = tpl.actions
    if actions then
        for _, action in pairs(actions) do
            local kind = type(action) == "table" and action.kind
            if kind == "overload_charge" or kind == "charge" then
                return true
            end
        end
    end

    -- Explicit name-based override for known charged families where the action
    -- table kind doesn't expose "charge" or "overload_charge" directly.
    local name = tpl.name or ""
    if string.find(name, "lasgun_p2") then return true end

    return false
end

-- Returns the current charge level (0-1) from the weapon's charge component.
local function _get_charge_level()
    local pm = Managers and Managers.player
    local player = pm and pm:local_player_safe(1)
    local unit = player and player.player_unit
    if not unit then return 0 end

    local weapon_ext = ScriptUnit.has_extension(unit, "weapon_system")
    if not weapon_ext then return 0 end

    local charge_module = weapon_ext._action_module_charge_component
    if charge_module then
        return charge_module.charge_level or 0
    end

    return 0
end

-- Returns true if M1 is currently being held by the player (real input).
local function _m1_held(func, self)
    return func(self, "action_one_hold")
end

_is_valid_target = function()
    local state = mod.crosshair_state
    local mode  = mod:get("autofire_target_mode") or "any"

    if mode == "weakspot" then
        return state == "weakspot_locked"
    elseif mode == "body" then
        return state == "target_locked"
    else
        return state == "target_locked" or state == "weakspot_locked"
    end
end

local function _clear_injections()
    _inject_fire    = false
    _inject_release = false
    _m2_held        = false
end

-- ── per-frame update ──────────────────────────────────────────────────────────
-- Toggle: flip the enabled setting on each press.
function mod.autofire_toggle()
    local current = mod:get("autofire_enabled")
    mod:set("autofire_enabled", not current, true)
    mod:echo("[AF] Auto-Fire " .. (not current and "ON" or "OFF"))
end





function mod.autofire_update(dt)
    -- ADS (M2 hold) overrides the toggle — autofire active while the player
    -- is physically holding M2, read directly from real input in the hook.
    local enabled = mod:get("autofire_enabled") or _m2_held

    if not enabled then
        _cooldown_remaining = 0
        _was_on_target      = false
        _clear_injections()
        return
    end

    if mod:get("autofire_debug") then
        local t = Managers.time and Managers.time:time("main") or 0
        if t > _diag_throttle_t + 2.0 then
            _diag_throttle_t = t
            local charge = _get_charge_level()
            mod:echo("[AF] ranged=" .. tostring(_is_wielding_ranged())
                .. " charged=" .. tostring(_is_charged_weapon())
                .. " charge_level=" .. string.format("%.2f", charge)
                .. " crosshair=" .. tostring(mod.crosshair_state)
                .. " valid=" .. tostring(_is_valid_target())
                .. " cooldown=" .. string.format("%.2f", _cooldown_remaining))
        end
    end

    local wielding_ranged = _is_wielding_ranged()

    if not wielding_ranged then
        -- While melee is out, keep _was_on_target in sync with the crosshair
        -- state so there is no stale edge when swapping back to ranged.
        _was_on_target      = _is_valid_target()
        _cooldown_remaining = 0
        _clear_injections()
        _was_wielding_ranged = false
        return
    end

    _was_wielding_ranged = true

    if Managers.ui and Managers.ui:using_input() then
        _clear_injections()
        return
    end

    local on_target  = _is_valid_target()
    local is_charged = _is_charged_weapon()
    local fire_mode  = mod:get("autofire_mode") or "always"

    -- ── charged weapon ────────────────────────────────────────────────────────
    if is_charged then
        -- Clear queue immediately if target is lost.
        if not on_target then
            _cooldown_remaining = 0
            _inject_release     = false
            _was_on_target      = false
            return
        end

        local charge = _get_charge_level()
        local threshold = (mod:get("autofire_charge_threshold") or 95) / 100

        if _cooldown_remaining > 0 then
            _cooldown_remaining = _cooldown_remaining - dt
            _was_on_target = on_target
            return
        end

        local should_fire = false
        if fire_mode == "edge" then
            should_fire = on_target and not _was_on_target
        else
            should_fire = on_target
        end

        -- Only release when: on a valid target AND weapon is sufficiently charged.
        if should_fire and charge >= threshold then
            _dbg("FIRE (charged release) charge=" .. string.format("%.2f", charge)
                .. " crosshair=" .. tostring(mod.crosshair_state))
            _inject_release = true
            local cooldown = mod:get("autofire_cooldown") or 0.3
            _cooldown_remaining = math.max(cooldown, 0.05)
        end

        _was_on_target = on_target
        return
    end

    -- ── normal weapon ─────────────────────────────────────────────────────────
    -- Clear queue immediately if target is lost.
    if not on_target then
        _cooldown_remaining = 0
        _inject_fire        = false
        _was_on_target      = false
        return
    end

    if _cooldown_remaining > 0 then
        _cooldown_remaining = _cooldown_remaining - dt
        return
    end

    local should_fire = false
    if fire_mode == "edge" then
        should_fire = on_target and not _was_on_target
    else
        should_fire = on_target
    end

    _was_on_target = on_target

    if should_fire then
        _dbg("FIRE (normal) crosshair=" .. tostring(mod.crosshair_state))
        _inject_fire = true
        local cooldown = mod:get("autofire_cooldown") or 0.1
        _cooldown_remaining = math.max(cooldown, 0.05)
    end
end