-- ActionbarSaveFix
-- Keeps item and macro buttons on your action bars on private/emulated servers
-- that fail to persist them. Spells are server-authoritative and never touched.
--
-- Re-arrange your bars freely; nothing needs saving by hand. The addon tracks
-- your layout and repairs it if the server drops it.
--
-- HOW IT WORKS
-- Two independent watchers detect changes:
--   * ACTIONBAR_SLOT_CHANGED -- the client's own event, fires with the changed
--     slot. Used to tell "the player just edited this" from "the server lost
--     this", which are otherwise indistinguishable.
--   * a slow 5s poll -- a safety net, because a server-side drop may not raise
--     any UI event at all.
-- Intent is recorded from player-driven changes and repaired when a change
-- arrives with no player action behind it.
--
-- PLACEMENT (the one genuinely non-obvious part)
-- In Classic Era, PlaceAction takes a SINGLE argument and drops whatever is on
-- the CURSOR into that slot. The retail-style PlaceAction(slot, type, id) form
-- is silently ignored, so it is a no-op that raises no error. There is no
-- cursor-free way to write an action slot in this client, so each placement is a
-- Pickup* + PlaceAction round-trip, which is why restore mutes SFX.
--
-- NOT FIGHTING THE PLAYER
-- A slot the player touched moments ago is protected from repair, and nothing
-- runs at all while the cursor is occupied -- mid-drag, the empty slot they
-- dragged from is in their hand, not lost, and touching the cursor there would
-- destroy the item they are moving.
--
-- Author: Space Bunny Free

local SV = "ActionbarSaveFix"

local MAX_SLOT = 120
local MACRO_LIMIT = 138      -- 1-36 account macros, 121-138 per-character macros
local RETRY_DELAYS = { 1.0, 3.0, 6.0, 12.0 }

local POLL_INTERVAL  = 5      -- safety net for drops that fire no UI event
local EVENT_DEBOUNCE = 0.4    -- coalesce the burst of events from one drag
local RECENT_TOUCH   = 3      -- do not repair a slot the player just touched
local FIRST_PASS     = 2      -- let the client build the bars before we judge them

-- Shared state. Declared up here because doRestore() runs below and needs to
-- re-trigger a deferred intent capture when it finishes.
local busy = false
local armed = false           -- player events are trustworthy only after pass 1
local pendingIntent = false
local checkPending = false
local recent = {}             -- slot -> time its protection expires

-- Forward declaration: doRestore() is defined earlier and needs to re-trigger
-- a deferred intent capture when it finishes.
local scheduleCheck

-- ---------------------------------------------------------------- utilities

local function db()
    local t = rawget(_G, SV)
    if type(t) ~= "table" then
        t = {}
        _G[SV] = t
    end
    if type(t.chars) ~= "table" then
        t.chars = {}
    end
    return t
end

-- out() speaks only when the player asked something with /abfix.
-- log() is for the automatic background work: silent unless VERBOSE is set,
-- so normal play prints nothing at all.
local VERBOSE = false   -- /abfix verbose on|off, for diagnosing later

local function out(fmt, ...)
    local s = fmt
    if select("#", ...) > 0 then
        local ok, r = pcall(string.format, fmt, ...)
        s = ok and r or fmt
    end
    print("|cff40ff90abfix|r " .. s)
end

local function log(fmt, ...)
    if not VERBOSE then
        return
    end
    out(fmt, ...)
end

-- In WoW's Lua, `time` is a callable table but `time.date` is NOT a field, so
-- guarding on it silently yields 0. Just try to call it.
local function now()
    if type(time) == "table" or type(time) == "function" then
        local ok, t = pcall(time)
        if ok and type(t) == "number" then
            return t
        end
    end
    return 0
end

local function later(delay, fn)
    if type(C_Timer) == "table" and type(C_Timer.After) == "function" then
        C_Timer.After(delay, fn)
        return
    end
    local t = CreateFrame("Frame")
    t:Show()
    t.__start = (type(GetTime) == "function") and GetTime() or 0
    t.__delay, t.__fn = delay, fn
    t:SetScript("OnUpdate", function(self)
        local tnow = (type(GetTime) == "function") and GetTime() or (self.__start + (self.__delay or 0))
        if (tnow - self.__start) >= (self.__delay or 0) then
            self:SetScript("OnUpdate", nil)
            local f = self.__fn
            self.__fn = nil
            if f then f() end
        end
    end)
end

local function charKey()
    local name = type(UnitName) == "function" and UnitName("player") or "?"
    local realm = type(GetRealmName) == "function" and GetRealmName() or "?"
    return tostring(realm) .. "/" .. tostring(name)
end

local function inCombat()
    return type(InCombatLockdown) == "function" and InCombatLockdown() and true or false
end

local function nowSec()
    if type(GetTime) == "function" then
        return GetTime()
    end
    return 0
end

local BAR_NAMES = {
    [1] = "MainMenu",
    [2] = "MultiBarBottomLeft",
    [3] = "MultiBarBottomRight",
    [4] = "MultiBarRight",
    [5] = "MultiBarLeft",
    [6] = "Stance",
    [7] = "BonusAction",
}

local function slotLabel(slot)
    if slot > 72 then
        return ("Stance%d"):format(slot - 72)
    end
    local barIndex = math.floor((slot - 1) / 12) + 1
    local within = ((slot - 1) % 12) + 1
    return ("%s%d"):format(BAR_NAMES[barIndex] or ("Bar" .. barIndex), within)
end

local function labelList(slots)
    local names = {}
    for i = 1, math.min(#slots, 6) do
        names[i] = slotLabel(slots[i])
    end
    if #slots > 6 then
        names[#names + 1] = ("+%d more"):format(#slots - 6)
    end
    return table.concat(names, ", ")
end

-- ------------------------------------------------------------- reading bars

local function getInfo(slot)
    if type(GetActionInfo) ~= "function" then
        return nil
    end
    local t, id = GetActionInfo(slot)
    return t, id
end

local function isOurs(t)
    return t == "item" or t == "macro"
end

local function macroName(id)
    if type(GetMacroInfo) ~= "function" then
        return nil
    end
    local ok, name = pcall(GetMacroInfo, id)
    if ok and type(name) == "string" then
        return name
    end
    return nil
end

local function scan()
    local found = {}
    for slot = 1, MAX_SLOT do
        local t, id = getInfo(slot)
        if isOurs(t) then
            local entry = { t = t, id = id }
            if t == "macro" then
                entry.name = macroName(id)
            end
            found[slot] = entry
        end
    end
    return found
end

local function macroIndexByName(name)
    if type(GetMacroInfo) ~= "function" or type(name) ~= "string" then
        return nil
    end
    for i = 1, MACRO_LIMIT do
        local ok, got = pcall(GetMacroInfo, i)
        if ok and got == name then
            return i
        end
    end
    return nil
end

local function resolveMacroIndex(entry)
    if type(entry.name) == "string" then
        local byName = macroIndexByName(entry.name)
        if byName then
            return byName
        end
    end
    if type(entry.id) == "number" then
        return entry.id
    end
    return nil
end

-- Identity of an action across sessions. Macros are matched by name because
-- their indices shift; items by itemID.
local function actionKey(entry)
    if entry.t == "macro" then
        return "macro:" .. tostring(entry.name or entry.id)
    end
    return tostring(entry.t) .. ":" .. tostring(entry.id)
end

-- Merge the live action bars into the snapshot WITHOUT ever discarding it.
--
-- The snapshot is a record of what the player WANTS on the bars. An empty bar
-- is precisely the damage we exist to repair, so a scan result must never be
-- allowed to overwrite the snapshot -- doing so on logout erases the very
-- record the next login needs and the repair silently stops working forever.
--
-- Two things are still reconciled so the snapshot stays accurate:
--   * new / changed slots are learned
--   * an action that now lives in a different slot drops its stale old slot,
--     otherwise a drag from slot 49 to slot 50 would be restored twice.
local function reconcile(store)
    local current = scan()

    local liveAt = {}
    for slot, entry in pairs(current) do
        local k = actionKey(entry)
        if liveAt[k] == nil then
            liveAt[k] = slot
        end
    end

    local moved, learned = 0, 0

    for slot, entry in pairs(store.slots) do
        if type(entry) == "table" then
            local live = liveAt[actionKey(entry)]
            if live ~= nil and live ~= slot then
                store.slots[slot] = nil
                moved = moved + 1
            end
        end
    end

    for slot, entry in pairs(current) do
        local known = store.slots[slot]
        if type(known) ~= "table" or known.t ~= entry.t or known.id ~= entry.id
           or known.name ~= entry.name then
            store.slots[slot] = entry
            learned = learned + 1
        end
    end

    return current, moved, learned
end

local function countSlots(t)
    local n = 0
    for _ in pairs(t) do
        n = n + 1
    end
    return n
end

-- High-water mark of how many slots this character has ever had tracked.
-- If the snapshot ever drops to zero while this says otherwise, the snapshot
-- was wiped by something external and there is nothing left to repair from.
-- That used to happen silently and looked like "detection is broken".
local function trackCount(store)
    local n = countSlots(store.slots)
    if type(store.peak) ~= "number" or n > store.peak then
        store.peak = n
    end
    return n, store.peak
end

-- ------------------------------------------------------------------- saving

local function save()
    local key = charKey()
    local store = db().chars[key]
    if type(store) ~= "table" then
        store = {}
        db().chars[key] = store
    end
    store.slots = scan()
    store.key = key
    store.savedAt = now()
    store.peak = countSlots(store.slots)   -- seed the wipe-detection baseline
    db().saved = key
    return store
end

-- ---------------------------------------------------------------- restoring

-- Restoring plays the "Pick Up / Put Down" sound (SoundEntries type 9) because
-- every placement is a cursor round-trip: PickupItem/PickupMacro then
-- PlaceAction. There is no cursor-free API for writing an action bar slot in
-- 1.14, so the sound is muted for the duration of the placement instead.
--
-- SetSoundOption/SetSoundOptionChannel do NOT exist in this client (verified
-- against the binary); the CVar route is the only lever. Everything below runs
-- inside a single frame, so the mute window is imperceptible.
local function soundMode()
    local d = db()
    if type(d.sound) ~= "string" or
       (d.sound ~= "off" and d.sound ~= "sfx" and d.sound ~= "all") then
        d.sound = "sfx"
    end
    return d.sound
end

local function withMutedSound(fn)
    local mode = soundMode()
    if mode == "off" or type(SetCVar) ~= "function" or type(GetCVar) ~= "function" then
        return fn()
    end

    local cvar = (mode == "all") and "Sound_EnableAllSound" or "Sound_EnableSFX"
    local okPrev, prev = pcall(GetCVar, cvar)
    if not okPrev or type(prev) ~= "string" then
        return fn()
    end

    if not pcall(SetCVar, cvar, "0") then
        return fn()          -- secure CVar, cannot mute here: just place
    end

    local ok, err = pcall(fn)
    pcall(SetCVar, cvar, prev)         -- always put it back
    if not ok then
        error(err, 0)
    end
end

-- True while the player is physically holding something (mid drag-and-drop).
-- Everything must stand down during this: the source slot is empty because the
-- action is in their hand, not because it was lost, and calling ClearCursor()
-- would destroy the very thing they are dragging.
local function cursorBusy()
    if type(GetCursorInfo) == "function" then
        local ok, info = pcall(GetCursorInfo)
        if ok and info then
            return true
        end
    end
    return false
end

local function clearCursor()
    if type(ClearCursor) == "function" then
        pcall(ClearCursor)
    end
end

-- Classic Era has no "put this action on the cursor" call that takes an action
-- descriptor, so we stage the action on the cursor first and then drop it in.
local function loadCursor(entry)
    if entry.t == "macro" then
        local idx = resolveMacroIndex(entry)
        if idx and type(PickupMacro) == "function" then
            pcall(PickupMacro, idx)
            return true
        end
        return false
    end

    if type(entry.id) == "number" then
        -- Prefer a bag/equipped copy; PickupItem refuses unknown itemIDs.
        if type(PickupItem) == "function" then
            pcall(PickupItem, entry.id)
            return true
        end
    end
    return false
end

local function placeAction(slot, entry)
    if type(PlaceAction) ~= "function" then
        return false
    end
    if inCombat() then
        return false
    end
    -- Never touch the cursor while the player is holding something.
    if cursorBusy() then
        return false
    end

    clearCursor()
    if not loadCursor(entry) then
        return false
    end

    -- The Classic signature: PlaceAction(slot). Cursor -> slot.
    --
    -- Deliberately NOT recorded in `recent`: our own placement also raises
    -- ACTIONBAR_SLOT_CHANGED, and marking it would make a repaired slot look
    -- player-touched.
    pcall(PlaceAction, slot)
    local t = getInfo(slot)
    if t then
        return true
    end

    -- Defensive fallback for a retail-flavored API stub, harmless on Classic.
    local at = (entry.t == "macro") and "macro" or "item"
    pcall(PlaceAction, slot, at, entry.id)
    t = getInfo(slot)
    if t then
        return true
    end

    clearCursor()
    return false
end

-- A repair pass is in flight. Player-driven "intent" capture must not run
-- while we are the ones moving icons, or our own repair would be mistaken for
-- the player rearranging their bars and could wipe the intent we are restoring.
local busy = false

local function doRestore(chain)
    chain = chain or RETRY_DELAYS

    local store = db().chars[charKey()]
    if type(store) ~= "table" or type(store.slots) ~= "table" then
        return
    end

    if inCombat() then
        log("in combat, postponing restore")
        later(5, function() doRestore(chain) end)
        return
    end

    busy = true

    -- Never repair a slot the player touched moments ago. They cleared it or
    -- are mid-drag; either way it is not damage.
    local tnow = nowSec()
    local restored, failed, skipped = {}, {}, {}
    -- One mute window for the whole pass, so restoring 8 slots does not stutter
    -- the sound 8 times over.
    withMutedSound(function()
        for slot in pairs(store.slots) do
            if not getInfo(slot) then
                local exp = recent[slot]
                if exp and exp > tnow then
                    skipped[#skipped + 1] = slot
                else
                    local entry = store.slots[slot]
                    if type(entry) == "table" and placeAction(slot, entry) then
                        restored[#restored + 1] = slot
                    else
                        failed[#failed + 1] = slot
                    end
                end
            end
        end
    end)

    table.sort(restored)
    table.sort(failed)
    table.sort(skipped)

    if #restored > 0 then
        log("restored %d slot(s): %s", #restored, labelList(restored))
    end

    local delay = table.remove(chain, 1)
    if #failed > 0 and delay then
        log("%d slot(s) still empty, retrying in %.0fs: %s", #failed, delay, labelList(failed))
        later(delay, function() doRestore(chain) end)
        return
    end

    busy = false

    -- A player edit may have been queued while we were busy. runCheck skips
    -- while busy, so replay it now rather than dropping the change silently.
    if pendingIntent then
        scheduleCheck(false)
    elseif #skipped > 0 then
        -- Re-check once the protection windows lapse, so slots we deliberately
        -- left alone are re-examined rather than forgotten.
        scheduleCheck(false)
    end

    if #failed > 0 then
        log("could not restore %d slot(s): %s", #failed, labelList(failed))
        log("check the items are in your bags, then run /abfix restore")
    end
end

-- ------------------------------------------------------------- change watch

local pollTicker

-- nextFreeDelay() finds the soonest slot whose protection expires.
local function nextFreeDelay()
    local best
    local tnow = nowSec()
    for _, exp in pairs(recent) do
        if exp > tnow and (best == nil or exp < best) then
            best = exp
        end
    end
    if best then
        return math.max(0.5, best - tnow + 0.2)
    end
    return nil
end
-- The player deliberately rearranged things: the live layout IS the intent,
-- including slots they emptied. This is what makes "mess around freely" work.
-- The player deliberately rearranged things: the live layout IS the intent.
-- This is what makes "mess around freely" work with no manual save.
--
-- Removals are decided PER SLOT, not all-or-nothing. A slot that vanished and
-- carries a fresh player touch is intentionally cleared; a slot that vanished
-- without one is damage and must stay in the intent so it gets repaired.
-- Judging the whole bar at once could not tell those two cases apart when they
-- happen at the same time (player clears one slot while the proxy drops another).
local function adoptLive(store)
    local current = scan()
    local tnow = nowSec()

    local changed, cleared = 0, 0
    for slot in pairs(store.slots) do
        if current[slot] == nil then
            local exp = recent[slot]
            if exp and exp > tnow then
                store.slots[slot] = nil      -- player cleared it -- respect that
                cleared = cleared + 1
            end
            -- else: no player touch, so this is damage. Keep the intent entry
            -- and let the repair pass put it back.
        end
    end

    for slot, entry in pairs(current) do
        local known = store.slots[slot]
        if type(known) ~= "table" or known.t ~= entry.t or known.id ~= entry.id
           or known.name ~= entry.name then
            changed = changed + 1
        end
        store.slots[slot] = entry
    end

    store.savedAt = now()
    trackCount(store)
    return changed + cleared, cleared
end

local function runCheck(quiet)
    if busy then
        -- A repair is in flight. doRestore re-triggers us when it finishes if a
        -- player edit is still queued, so dropping through here is safe.
        return
    end

    if cursorBusy() then
        -- The player is mid-drag: the empty slot they dragged from is in their
        -- hand, not lost. Stand down completely -- repairing now would both
        -- fight them and ClearCursor() would destroy what they are holding.
        scheduleCheck(false, 0.4)
        return
    end

    local store = db().chars[charKey()]
    if type(store) ~= "table" or type(store.slots) ~= "table" then
        store = save()
        armed = true
        log("baseline captured: %d item/macro slot(s) tracked for %s",
            countSlots(store.slots), charKey())
        return
    end

    -- Intent wins over the poller: if a player edit is queued, this pass learns
    -- it rather than "repairing" the very slot they just emptied.
    local playerDriven = pendingIntent and armed
    pendingIntent = false

    if playerDriven then
        local changedCount, cleared = adoptLive(store)
        if changedCount > 0 then
            if cleared > 0 then
                log("tracked your changes: %d cleared, %d tracked", cleared,
                    countSlots(store.slots))
            else
                log("tracked your changes: %d slot(s) now tracked", countSlots(store.slots))
            end
        end
    else
        local _, moved, learned = reconcile(store)
        store.savedAt = now()
        if (moved + learned) > 0 and not quiet then
            log("picked up %d change(s) from the bars", moved + learned)
        end
    end

    -- From here on, player-driven events are trustworthy.
    armed = true

    local total, peak = trackCount(store)
    if total == 0 and peak > 0 then
        log("WARNING: snapshot is empty but %d slot(s) were tracked before", peak)
        log("re-place your items and run /abfix learn to re-seed it")
        return
    end

    -- A slot the player touched moments ago is empty on purpose. Never repair
    -- it inside its protection window; that was the "it puts the item straight
    -- back" symptom.
    local tnow = nowSec()
    local missing, held = {}, {}
    for slot in pairs(store.slots) do
        if not getInfo(slot) then
            local exp = recent[slot]
            if exp and exp > tnow then
                held[#held + 1] = slot
            else
                missing[#missing + 1] = slot
            end
        end
    end
    table.sort(missing)
    table.sort(held)

    if #missing > 0 then
        log("%d of %d slot(s) gone, repairing: %s", #missing, total, labelList(missing))
        doRestore()
    elseif #held > 0 then
        local d = nextFreeDelay()
        if d then
            scheduleCheck(false, d)
        end
    elseif not quiet then
        log("bars match: %d/%d slot(s) in place", total, total)
    end
end

scheduleCheck = function(intent, delay)
    if intent then
        pendingIntent = true
    end
    if checkPending then
        return
    end
    checkPending = true
    later(delay or EVENT_DEBOUNCE, function()
        checkPending = false
        runCheck(true)
    end)
end

-- ------------------------------------------------------------------ events

local loggedIn = false

local function beginWatching()
    pollTicker = nil
    if type(C_Timer) == "table" and type(C_Timer.NewTicker) == "function" then
        pollTicker = C_Timer.NewTicker(POLL_INTERVAL, function()
            if busy or inCombat() then
                return
            end
            -- Never let the poller race a queued player edit.
            scheduleCheck(false)
        end)
    end
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
frame:RegisterEvent("PLAYER_LEAVING_WORLD")
frame:RegisterEvent("ACTIONBAR_SLOT_CHANGED")
frame:SetScript("OnEvent", function(_, event, arg1)
    if event == "ACTIONBAR_SLOT_CHANGED" then
        -- Our own repairs raise this event too. While busy we are the cause of
        -- the change, so it must not be mistaken for the player editing, and it
        -- must not arm their protection window (that would make a repaired slot
        -- look deliberately cleared).
        if not busy and loggedIn then
            if type(arg1) == "number" then
                recent[arg1] = nowSec() + RECENT_TOUCH
            end
            -- Before the first pass the bar state is not trustworthy as intent,
            -- so those events are ignored rather than learned from.
            if armed then
                scheduleCheck(true)
            end
        end
        return
    end

    if event == "PLAYER_LOGIN" then
        loggedIn = true
        armed = false
        pendingIntent = false
        later(FIRST_PASS, function()
            beginWatching()
            runCheck(false)
        end)
        return
    end

    if event == "PLAYER_LEAVING_WORLD" then
        -- Fires on logout AND on teleport / instance loads. Merge only: a scan
        -- taken now can be mid-teardown and empty, which would wipe the intent.
        local store = db().chars[charKey()]
        if type(store) == "table" and type(store.slots) == "table" then
            local _, moved, learned = reconcile(store)
            store.leftAt = now()
            local total, peak = trackCount(store)
            log("leaving world: %d slot(s) tracked (learned %d, moved %d)",
                total, learned, moved)
            if total == 0 and peak > 0 then
                log("WARNING: snapshot was wiped externally")
            end
        end
        return
    end

    if not loggedIn then
        return
    end

    if event == "PLAYER_ENTERING_WORLD" and arg1 == false then
        return
    end

    -- Zone change / teleport / instance load. Re-verify, but do not trust the
    -- freshly loaded bar state as intent: the server may already have dropped
    -- things by the time we look.
    armed = false
    later(FIRST_PASS, function() runCheck(false) end)
end)

-- ------------------------------------------------------------ slash command

SLASH_ABFIX1 = "/abfix"
SlashCmdList.ABFIX = function(msg)
    -- Split into the command word and the remainder. Note: taking only the first
    -- return of a chained gsub leaves `cmd` as the WHOLE message, so
    -- "/abfix drop 49" would never match any branch and fall through to help.
    local raw = tostring(msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    local cmd, rest = raw:match("^(%S+)%s*(.*)$")
    if not cmd then
        cmd, rest = "", ""
    end

    if cmd == "" then
        out("learn | drop <slot> | sync | verbose <on|off> | sound <off|sfx|all> | restore | status | forget")
        return
    end

    if cmd == "learn" then
        local store = save()
        out("snapshot overwritten with %d slot(s)", countSlots(store.slots))

    elseif cmd == "drop" then
        -- The snapshot is append-only, so a slot the player cleared on purpose
        -- would be repaired forever. This is the explicit way to stop that.
        local slot = tonumber(rest or "")
        local store = db().chars[charKey()]
        if not slot or type(store) ~= "table" or type(store.slots) ~= "table" then
            out("usage: /abfix drop <slot number>")
        else
            local entry = store.slots[slot]
            if entry then
                store.slots[slot] = nil
                out("dropped %s (%s) from the snapshot", slotLabel(slot),
                    tostring(entry.name or entry.id))
            else
                out("%s is not tracked", slotLabel(slot))
            end
        end

    elseif cmd == "verbose" then
        if rest == "on" then
            VERBOSE = true
            out("background logging on")
        elseif rest == "off" then
            VERBOSE = false
            out("background logging off")
        else
            out("background logging is %s", VERBOSE and "on" or "off")
        end

    elseif cmd == "sound" then
        if rest == "" then
            local m = soundMode()
            local live = "?"
            if type(GetCVar) == "function" then
                local cvar = (m == "all") and "Sound_EnableAllSound" or "Sound_EnableSFX"
                local ok, v = pcall(GetCVar, cvar)
                if ok then live = tostring(v) end
            end
            out("restore sound: %s (mute %s, currently %s)", m, m, live)
        elseif rest == "off" or rest == "sfx" or rest == "all" then
            db().sound = rest
            out("restore sound set to %s", rest)
        else
            out("usage: /abfix sound off | sfx | all")
        end

    elseif cmd == "sync" then
        -- debug: force a reconcile + repair pass, as if the poller ran
        pendingIntent = false
        runCheck(false)

    elseif cmd == "restore" then
        out("attempting restore")
        doRestore()

    elseif cmd == "forget" then
        db().chars[charKey()] = nil
        out("cleared saved slots for %s", charKey())

    elseif cmd == "status" then
        local store = db().chars[charKey()]
        local slots = {}
        if type(store) == "table" and type(store.slots) == "table" then
            slots = store.slots
        end
        local saved, present, missing = 0, 0, {}
        for slot in pairs(slots) do
            saved = saved + 1
            if getInfo(slot) then
                present = present + 1
            else
                missing[#missing + 1] = slot
            end
        end
        table.sort(missing)
        out("%s: saved=%d present=%d missing=%d", charKey(), saved, present, #missing)
        if #missing > 0 then
            out("missing: %s", labelList(missing))
        end

    else
        out("learn | drop <slot> | sync | verbose <on|off> | sound <off|sfx|all> | restore | status | forget")
    end
end

-- Silent on load by design: the addon works on its own, and /abfix with no
-- arguments prints the command list whenever you want a reminder.