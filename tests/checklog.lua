-- Programmatic checker for the WeirdLoot core trace (WeirdLootDebugLog).
--
-- The in-game logger (Debug.lua) persists a structured record per core command/transition
-- to the WeirdLootDebugLog SavedVariable. This script asserts that trace against the core's
-- intended behaviors, so an in-game test run can be verified mechanically instead of by eye.
--
-- Usage:
--   luajit tests/checklog.lua <path/to/SavedVariables/WeirdLoot.lua>   # check a real run
--   luajit tests/checklog.lua --demo                                   # drive the real core
--                                                                      # and self-check + a
--                                                                      # negative teeth test
--
-- Exit code is 0 when every invariant holds, 1 otherwise (CI-friendly).

local STATE_NEW, STATE_IDLE, STATE_PENDING = "new", "idle", "pending"
local STATE_ROLLING, STATE_RESOLVED, STATE_SKIPPED = "rolling", "resolved", "skipped"

-- ---------------------------------------------------------------------------
-- the checker: records (array) -> (ok, violations)
-- Tracking is scoped per session segment (lot ids restart "L:1" each login).
-- ---------------------------------------------------------------------------
local function checkRecords(records)
    local V, notes = {}, {}
    local function fail(inv, rec, msg)
        V[#V + 1] = { inv = inv, seq = rec and rec.seq, ev = rec and rec.ev, msg = msg }
    end
    local function note(rec, msg)
        notes[#notes + 1] = { seq = rec and rec.seq, msg = msg }
    end

    local lastSeq = nil
    local state, minted, owed = {}, {}, {}   -- per-id, reset on each session segment

    local function resetSegment()
        state, minted, owed = {}, {}, {}
    end

    for _, rec in ipairs(records) do
        local ev, id = rec.ev, rec.id

        -- A. global monotonic seq
        if lastSeq and rec.seq and rec.seq <= lastSeq then
            fail("monotonic-seq", rec, string.format("seq %s not > previous %s", tostring(rec.seq), tostring(lastSeq)))
        end
        if rec.seq then lastSeq = rec.seq end

        if ev == "session" or ev == "reset" then
            -- segment boundary: a new login (session) or a ledger Reset (Start/Clear Session)
            -- legitimately restarts lot ids at L:1, so clear per-id tracking here.
            resetSegment()
        elseif ev == "mark" then
            -- segment label only
        elseif ev == "mint" then
            -- A duplicate mint id can only arise from a ledger Reset (the core's seq strictly
            -- increments within one instance). If we reach here with the id already minted, a
            -- reset happened that was not recorded (e.g. a log captured before reset logging) --
            -- treat it as an implicit segment boundary and note it, rather than a false failure.
            if minted[id] then
                note(rec, "implicit segment boundary at " .. tostring(id) .. " (no reset/session record before it)")
                resetSegment()
            end
            minted[id] = true
            state[id] = rec.state or STATE_NEW
        elseif ev == "grow" or ev == "shrink" or ev == "retire" or ev == "remove" then
            -- count adjustments: id (when present) must already exist
            if id and not minted[id] then fail("mint-before-use", rec, ev .. " on unminted " .. tostring(id)) end
        elseif ev == "surface" then
            if not minted[id] then fail("mint-before-use", rec, "surface on unminted " .. tostring(id))
            else
                local s = state[id]
                if s ~= STATE_NEW and s ~= STATE_IDLE and s ~= STATE_SKIPPED then
                    fail("legal-transition", rec, string.format("surface from %s (want new/idle/skipped)", tostring(s)))
                end
                state[id] = STATE_PENDING
            end
        elseif ev == "skip" then
            if state[id] ~= STATE_PENDING then fail("legal-transition", rec, "skip from " .. tostring(state[id])) end
            state[id] = STATE_SKIPPED
        elseif ev == "startRoll" then
            if state[id] ~= STATE_PENDING then fail("legal-transition", rec, "startRoll from " .. tostring(state[id])) end
            state[id] = STATE_ROLLING
        elseif ev == "cancel" then
            if state[id] ~= STATE_ROLLING then fail("legal-transition", rec, "cancel from " .. tostring(state[id])) end
            state[id] = STATE_PENDING
        elseif ev == "response" then
            if rec.ok then
                if not minted[id] then fail("mint-before-use", rec, "response on unminted " .. tostring(id)) end
                -- F. an accepted response must never land on a resolved (not-yet-unlocked) lot
                if state[id] == STATE_RESOLVED then
                    fail("no-response-after-resolve", rec, "accepted response on resolved " .. tostring(id) .. " (stale-roll)")
                end
            end
        elseif ev == "resolve" then
            if not minted[id] then fail("mint-before-use", rec, "resolve on unminted " .. tostring(id)) end
            if state[id] == STATE_RESOLVED then fail("legal-transition", rec, "resolve of already-resolved " .. tostring(id)) end
            state[id] = STATE_RESOLVED
            local awards = rec.awards or {}
            -- E. one award per copy
            if rec.count and #awards ~= rec.count then
                fail("awards-eq-count", rec, string.format("%d award(s) for count %d", #awards, rec.count))
            end
            local o = 0
            for _, a in ipairs(awards) do if a.state == "owed" then o = o + 1 end end
            owed[id] = o
        elseif ev == "unlock" then
            if state[id] ~= STATE_RESOLVED then fail("legal-transition", rec, "unlock from " .. tostring(state[id])) end
            state[id] = STATE_IDLE
            owed[id] = 0
        elseif ev == "deliver" then
            -- G. delivery only against an owed award produced by a prior resolve
            if (owed[id] or 0) <= 0 then
                fail("deliver-needs-owed", rec, "deliver on " .. tostring(id) .. " with no outstanding owed award")
            else
                owed[id] = owed[id] - 1
            end
        end
    end

    return #V == 0, V, notes
end

-- ---------------------------------------------------------------------------
-- reporting
-- ---------------------------------------------------------------------------
local INVARIANTS = {
    "monotonic-seq", "mint-before-use", "legal-transition",
    "awards-eq-count", "no-response-after-resolve", "deliver-needs-owed",
}

local function report(label, records)
    local counts = {}
    for _, r in ipairs(records) do counts[r.ev] = (counts[r.ev] or 0) + 1 end
    local evParts = {}
    for ev, n in pairs(counts) do evParts[#evParts + 1] = ev .. "=" .. n end
    table.sort(evParts)
    print(string.format("[%s] %d record(s): %s", label, #records, table.concat(evParts, " ")))

    local ok, V, notes = checkRecords(records)
    local byInv = {}
    for _, v in ipairs(V) do byInv[v.inv] = (byInv[v.inv] or 0) + 1 end
    for _, inv in ipairs(INVARIANTS) do
        local n = byInv[inv] or 0
        print(string.format("  %-28s %s", inv, n == 0 and "ok" or ("FAIL (" .. n .. ")")))
    end
    for _, v in ipairs(V) do
        print(string.format("  ! seq=%s %s [%s] %s", tostring(v.seq), tostring(v.ev), v.inv, v.msg))
    end
    for _, nt in ipairs(notes or {}) do
        print(string.format("  ~ seq=%s note: %s", tostring(nt.seq), nt.msg))
    end
    return ok
end

-- ---------------------------------------------------------------------------
-- load a SavedVariables file and pull out WeirdLootDebugLog.records
-- ---------------------------------------------------------------------------
local function loadSavedVar(path)
    local f = assert(io.open(path, "r"), "cannot open " .. path)
    local src = f:read("*a"); f:close()
    local env = setmetatable({}, { __index = _G })
    local chunk = assert(loadstring(src, "@" .. path))
    setfenv(chunk, env)
    chunk()
    local log = env.WeirdLootDebugLog
    assert(log and log.records, "no WeirdLootDebugLog.records in " .. path)
    return log.records
end

-- ---------------------------------------------------------------------------
-- demo mode: drive the REAL core through a logger, then check the trace.
-- This validates the instrumentation and the checker together, out of game.
-- ---------------------------------------------------------------------------
local function demoRecords()
    local here = string.match(arg[0] or "", "^(.*)/tests/") or "."
    local LootCore = loadfile(here .. "/LootCore.lua")("WeirdLoot", {})

    local recs, seq = {}, 0
    local function logger(ev, data)
        seq = seq + 1
        local r = { seq = seq, ev = ev }
        if data then for k, v in pairs(data) do r[k] = v end end
        recs[#recs + 1] = r
    end

    -- top-N resolver: order responders by roll desc, one winner per copy
    local function topN(lot)
        local rs = {}
        for player, v in pairs(lot.responses) do
            if v ~= "pass" then rs[#rs + 1] = { name = player, roll = tonumber(string.match(v, "%d+")) or 0 } end
        end
        table.sort(rs, function(a, b) return a.roll > b.roll end)
        local winners = {}
        for i = 1, lot.count do winners[i] = rs[i] and rs[i].name or nil end
        return { winners = winners, winner = winners[1] }
    end

    local c = LootCore.New()
    c:SetLogger(logger)
    c:SetResolver(topN)
    c:SetML("ML")
    c:On("ledgerChanged", function() end)

    logger("session", { reason = "demo" })

    -- scenario 1: 2x drop, three rollers -> two distinct owed winners, deliver one
    c:Reconcile({ [40001] = 2 }, { [40001] = true })          -- mint L:1 count 2 (fresh)
    local id = c:openLotForItem(40001).id
    c:Reconcile({ [40001] = 3 }, { [40001] = true })          -- grow to 3
    c:Surface(id); c:StartRoll(id)
    c:SetResponse(id, "Bob", "ms:90")
    c:SetResponse(id, "Amy", "ms:70")
    c:SetResponse(id, "Cat", "os:40")
    c:Resolve(id)                                             -- 3 awards, 2 owed (ML not among)
    c:SetResponse(id, "Late", "ms:99")                       -- rejected (resolved) -> ok=false
    c:MarkDeliveredFor("Bob", 40001)                         -- deliver one owed copy

    -- scenario 2: stale-roll guard -- re-drop the SAME itemId after resolve mints a NEW lot
    c:Reconcile({ [40001] = 4 }, { [40001] = true })         -- +1 fresh copy -> new open lot
    local id2 = c:openLotForItem(40001).id
    assert(id2 ~= id, "re-drop must mint a fresh lot id")

    -- scenario 3: unlock + reroll, then a copy leaves bags (retire/remove)
    c:Reconcile({ [50000] = 1 }, { [50000] = true })
    local x = c:openLotForItem(50000).id
    c:Surface(x); c:StartRoll(x); c:SetResponse(x, "Dan", "ms:55"); c:Resolve(x)
    c:Unlock(x)
    c:Surface(x); c:StartRoll(x); c:SetResponse(x, "Eve", "ms:60"); c:Resolve(x)
    c:Reconcile({}, {})                                      -- everything left bags -> retire/remove

    return recs
end

-- a deliberately-broken trace: the checker MUST flag it, or it has no teeth
local function brokenRecords()
    return {
        { seq = 1, ev = "session", reason = "teeth" },
        { seq = 2, ev = "mint", id = "L:1", itemId = 1, count = 1, state = "new" },
        { seq = 3, ev = "surface", id = "L:1", from = "new" },
        { seq = 4, ev = "startRoll", id = "L:1" },
        { seq = 5, ev = "resolve", id = "L:1", count = 1, awards = { { state = "owed", winner = "Bob" } } },
        { seq = 6, ev = "response", id = "L:1", player = "Bob", value = "ms", ok = true },  -- stale-roll bug
        { seq = 7, ev = "deliver", id = "L:2", recipient = "Zed" },                          -- never minted/owed
        { seq = 8, ev = "resolve", id = "L:3", count = 2, awards = { { state = "owed" } } }, -- awards != count + unminted
    }
end

-- ---------------------------------------------------------------------------
-- main
-- ---------------------------------------------------------------------------
local target = arg[1]
if target == "--demo" or target == nil then
    if target == nil then print("(no file given; running --demo. Pass a SavedVariables path to check a real run.)") end
    local okDemo = report("demo", demoRecords())
    print()
    -- teeth test: the broken trace must FAIL, and we assert it does
    local okBroken = report("teeth (expect FAIL)", brokenRecords())
    print()
    if okDemo and (not okBroken) then
        print("checklog self-test: PASS (real-core trace clean, broken trace caught)")
        os.exit(0)
    else
        print("checklog self-test: FAIL (demo clean=" .. tostring(okDemo) .. ", broken caught=" .. tostring(not okBroken) .. ")")
        os.exit(1)
    end
else
    local ok = report(target, loadSavedVar(target))
    os.exit(ok and 0 or 1)
end
