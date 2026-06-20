-- Out-of-game battery for WeirdSync-1.0 (the reliable state-sync library), standalone.
-- Loads the REAL Libs/WeirdSync-1.0/WeirdSync-1.0.lua into a mocked env and drives the sync +
-- reliability mechanics from DESIGN.md section 10. No WeirdLoot code is involved: the host is a
-- tiny in-memory line store, so this proves the library on its own before Comm.lua is rewired.
--
-- Run from the addon dir:  luajit tests/weirdsync.lua

-- ---------------------------------------------------------------------------
-- tiny test framework (same shape as tests/run.lua)
-- ---------------------------------------------------------------------------
local pass, fail, failures = 0, 0, {}
local current = "?"
local function check(cond, label)
    if cond then pass = pass + 1
    else fail = fail + 1; failures[#failures + 1] = current .. ": " .. label; print("  FAIL " .. label) end
end
local function eq(a, b, label)
    check(a == b, (label or "") .. " (got " .. tostring(a) .. ", want " .. tostring(b) .. ")")
end
local function test(name, fn)
    current = name
    print("[" .. name .. "]")
    local ok, err = pcall(fn)
    if not ok then fail = fail + 1; failures[#failures + 1] = name .. ": ERROR " .. tostring(err); print("  ERROR " .. tostring(err)) end
end

-- ---------------------------------------------------------------------------
-- shared wire + clock + a router that fans messages to all registered channels
-- ---------------------------------------------------------------------------
local WIRE = {}
local CLOCK = 1000
local CHANNELS = {}            -- me -> channel (for the router)

local function clearWire() WIRE = {} end

-- first field (message type tag) of a wire message
local function firstField(msg) return msg:match("^(.-)" .. string.char(30)) or msg end

-- Deliver everything currently on the wire to every channel it is addressed to, in order.
-- A WHISPER reaches only its target; anything else reaches all non-senders. Returns nothing;
-- call repeatedly to let request/response settle. To simulate a DROP, clearWire() first.
local function deliver()
    local msgs = WIRE; WIRE = {}
    for _, m in ipairs(msgs) do
        for me, ch in pairs(CHANNELS) do
            if m.sender ~= me then
                if m.dist == "WHISPER" then
                    if m.target == me then ch:OnReceive(m.sender, m.msg) end
                else
                    ch:OnReceive(m.sender, m.msg)
                end
            end
        end
    end
end

-- Deliver repeatedly until the wire drains (a full request -> response -> ack settles over
-- several hops because messages produced during a deliver land in the next round). Bounded so a
-- live-lock can't hang the test. Use only where you WANT convergence (not in drop scenarios).
local function settle(maxRounds)
    for _ = 1, (maxRounds or 20) do
        if #WIRE == 0 then break end
        deliver()
    end
end

-- ---------------------------------------------------------------------------
-- load the library once into a mocked env
-- ---------------------------------------------------------------------------
local libs = {}
local aceComm = {
    Embed = function(_, target)
        target.SendCommMessage = function(self, prefix, msg, dist, tgt, prio)
            WIRE[#WIRE + 1] = { prefix = prefix, msg = msg, dist = dist, target = tgt, sender = self.me, prio = prio }
        end
        target.RegisterComm = function() end
    end,
}
libs["AceComm-3.0"] = aceComm
local LibStub = setmetatable({
    NewLibrary = function(_, name) libs[name] = libs[name] or {}; return libs[name] end,
    GetLibrary = function(_, name) return libs[name] end,
}, { __call = function(_, name) return libs[name] end })

local env = setmetatable({}, { __index = _G })
env._G = env
env.LibStub = LibStub
env.GetTime = function() return CLOCK end
env.UnitName = function() return "?" end
env.CreateFrame = nil  -- no self-driving frame in tests; we call Tick() explicitly
do
    local chunk = assert(loadfile("Libs/WeirdSync-1.0/WeirdSync-1.0.lua"))
    setfenv(chunk, env)
    chunk()
end
local WeirdSync = libs["WeirdSync-1.0"]
assert(WeirdSync and WeirdSync.NewChannel, "WeirdSync failed to load")

-- ---------------------------------------------------------------------------
-- a minimal host: an in-memory line store keyed by the line's first field (the id).
-- A "line" is { id, value } (an opaque array of strings to the lib).
-- ---------------------------------------------------------------------------
local function makeHost(name, isML, opts)
    opts = opts or {}
    local host = {
        name = name,
        store = {},     -- id -> line
        log = {},       -- captured trace records
        roster = opts.roster or { [name] = true },
        authority = opts.authority or "ML",  -- settable, so a test can model a late-resolving LM
    }
    local cb = {
        selfName = name,
        isAuthority = function() return isML end,
        authorityName = function() return host.authority or "" end,
        rosterContains = function(n) return host.roster[n] == true end,
        epoch = function() return opts.epoch or "S1" end,
        buildSnapshot = function(emit)
            -- emit in a stable order so snapshots are deterministic
            local ids = {}
            for id in pairs(host.store) do ids[#ids + 1] = id end
            table.sort(ids)
            for _, id in ipairs(ids) do emit(host.store[id]) end
        end,
        applySnapshot = function(lines)
            host.store = {}
            for _, line in ipairs(lines) do host.store[line[1]] = line end
        end,
        applyLine = function(line) host.store[line[1]] = line end,
        log = function(ev, data)
            host.log[#host.log + 1] = { ev = ev, data = data or {} }
        end,
        deltaMax = opts.deltaMax or 8,
        backoffBase = opts.backoffBase or 2.0,
        backoffMul = opts.backoffMul or 2.0,
        maxAttempts = opts.maxAttempts or 4,
    }
    host.chan = WeirdSync:NewChannel(opts.prefix or "WST", cb)
    CHANNELS[name] = host.chan
    return host
end

local function reset()
    clearWire(); CLOCK = 1000
    for k in pairs(CHANNELS) do CHANNELS[k] = nil end
end

-- canonical view of a store for convergence comparison
local function view(host)
    local rows = {}
    for id, line in pairs(host.store) do
        rows[#rows + 1] = id .. "=" .. table.concat(line, ",")
    end
    table.sort(rows)
    return table.concat(rows, "\n")
end

-- authority helpers
local function setLine(host, id, value)
    host.store[id] = { id, value }
    return host.store[id]
end
local function deltaChange(host, id, value)
    local line = setLine(host, id, value)
    host.chan:NotifyChanged({ line })
    host.chan:Broadcast(false)
end

-- count captured log events of a kind
local function countEv(host, ev, predicate)
    local n = 0
    for _, r in ipairs(host.log) do
        if r.ev == ev and (not predicate or predicate(r.data)) then n = n + 1 end
    end
    return n
end

-- ===========================================================================
-- BATTERY
-- ===========================================================================

test("baseline snapshot mirrors authority -> peer and sets lastRev", function()
    reset()
    local ml = makeHost("ML", true)
    local rd = makeHost("Raider", false)
    setLine(ml, "L1", "pending")
    setLine(ml, "L2", "rolling")
    ml.chan:Broadcast(true)        -- forced full snapshot
    deliver()
    eq(view(rd), view(ml), "peer mirrored the authority's store")
    check(rd.chan.lastRev ~= nil, "peer set lastRev from the snapshot")
    eq(rd.chan.lastRev, ml.chan.rev, "peer rebaselined to the authority's current rev")
end)

test("a single change sends a delta (D), not a snapshot, and applies", function()
    reset()
    local ml = makeHost("ML", true)
    local rd = makeHost("Raider", false)
    ml.chan:Broadcast(true); deliver()              -- baseline
    clearWire()
    deltaChange(ml, "L1", "rolling")
    local snaps, deltas = 0, 0
    for _, m in ipairs(WIRE) do
        local t = firstField(m.msg)
        if t == "SB" then snaps = snaps + 1 end
        if t == "D" then deltas = deltas + 1 end
    end
    eq(snaps, 0, "no snapshot for a single change")
    check(deltas >= 1, "a delta was sent")
    deliver()
    eq(view(rd), view(ml), "peer applied the delta")
end)

test("more than deltaMax changes falls back to a full snapshot", function()
    reset()
    local ml = makeHost("ML", true, { deltaMax = 3 })
    local rd = makeHost("Raider", false, { deltaMax = 3 })
    ml.chan:Broadcast(true); deliver()
    clearWire()
    for i = 1, 5 do setLine(ml, "L" .. i, "v") end
    ml.chan:NotifyChanged({ ml.store.L1, ml.store.L2, ml.store.L3, ml.store.L4, ml.store.L5 })
    ml.chan:Broadcast(false)
    local sawSB = false
    for _, m in ipairs(WIRE) do if m.msg:sub(1, 2) == "SB" then sawSB = true end end
    check(sawSB, "fell back to a snapshot for a large change set")
    deliver()
    eq(view(rd), view(ml), "peer converged via the fallback snapshot")
end)

test("dropped delta -> gap detected -> peer requests sync -> converges (+ ack)", function()
    reset()
    local ml = makeHost("ML", true)
    local rd = makeHost("Raider", false)
    ml.chan:Broadcast(true); deliver()
    eq(view(rd), view(ml), "synced at baseline")

    ml.roster = { ML = true, Raider = true }
    -- DROP a delta: change state on the ML but never deliver it.
    deltaChange(ml, "L9", "rolling")
    clearWire()                                  -- the delta is lost
    -- a following delta now arrives with a rev gap
    deltaChange(ml, "L9", "resolved")
    deliver()                                    -- deliver the gap delta; raider whispers RQ
    check(rd.chan.pendingRequest ~= nil, "peer flagged a pending sync after the gap")
    check(countEv(rd, "recv-gap") >= 1, "peer logged the gap")
    settle()                                     -- RQ -> targeted snapshot -> apply + ack -> clear
    eq(view(rd), view(ml), "peer converged to authority truth after gap + resync")
    eq(rd.chan.pendingRequest, nil, "peer cleared its pending request on the snapshot")
    check(countEv(ml, "ack") >= 1, "authority received the peer's ack")
    eq(next(ml.chan.outstanding), nil, "authority cleared the outstanding targeted send")
end)

test("targeted snapshot does NOT bump the shared rev (no phantom gap for others)", function()
    reset()
    local ml = makeHost("ML", true)
    local r1 = makeHost("R1", false)
    local r2 = makeHost("R2", false)
    ml.chan:Broadcast(true); deliver()
    local revBefore = ml.chan.rev

    -- R1 asks for a resync; ML answers with a WHISPER snapshot.
    r1.chan:RequestSync(); deliver(); deliver()
    eq(ml.chan.rev, revBefore, "a targeted (whispered) snapshot did not advance the shared rev")

    -- now a normal delta to everyone must still be contiguous for R2 (no gap).
    clearWire()
    deltaChange(ml, "L1", "rolling")
    deliver()
    eq(r2.chan.lastRev, ml.chan.rev, "R2 stayed contiguous")
    eq(countEv(r2, "recv-gap"), 0, "R2 never saw a phantom gap")
    eq(view(r2), view(ml), "R2 applied the delta normally")
end)

test("requester retry: a dropped request is re-sent on exponential backoff, then gives up", function()
    reset()
    local ml = makeHost("ML", true, { maxAttempts = 3 })
    local rd = makeHost("Raider", false, { maxAttempts = 3 })
    -- peer requests, but the ML is "gone": drop every RQ so nothing is ever answered.
    -- maxAttempts=3 => initial send + 2 resends (at 2s, 6s), give up on the tick after the 3rd.
    rd.chan:RequestSync()
    clearWire()
    eq(rd.chan.pendingRequest.attempts, 1, "first request sent")
    local firstNext = rd.chan.pendingRequest.nextAttempt
    eq(firstNext - 1000, 2, "first retry scheduled at base backoff (2s)")

    -- not yet due
    CLOCK = 1001; rd.chan:Tick(CLOCK)
    eq(rd.chan.pendingRequest.attempts, 1, "no retry before the backoff elapses")

    -- due: 2s -> retry (attempt 2), next at +4s
    CLOCK = 1002; rd.chan:Tick(CLOCK); clearWire()
    eq(rd.chan.pendingRequest.attempts, 2, "retried at 2s")
    eq(rd.chan.pendingRequest.nextAttempt - CLOCK, 4, "next backoff is 4s")

    -- due: +4s -> attempt 3, next at +8s
    CLOCK = 1006; rd.chan:Tick(CLOCK); clearWire()
    eq(rd.chan.pendingRequest.attempts, 3, "retried at 6s")
    eq(rd.chan.pendingRequest.nextAttempt - CLOCK, 8, "next backoff is 8s")

    -- due: +8s -> attempts now at max (4) -> give up
    CLOCK = 1014; rd.chan:Tick(CLOCK)
    eq(rd.chan.pendingRequest, nil, "gave up after maxAttempts")
    check(countEv(rd, "give-up", function(d) return d.kind == "request" and d.reason == "max" end) == 1, "logged a request give-up")
    eq(countEv(rd, "resend", function(d) return d.kind == "request" end), 2, "exactly two resends before give-up")
end)

test("requester retry stops as soon as the snapshot actually arrives", function()
    reset()
    local ml = makeHost("ML", true)
    local rd = makeHost("Raider", false)
    setLine(ml, "L1", "pending")
    rd.chan:RequestSync()
    clearWire()                              -- first RQ dropped
    CLOCK = 1002; rd.chan:Tick(CLOCK)        -- resend RQ (attempt 2)
    deliver()                                -- this time ML hears it and answers
    deliver()                                -- raider applies snapshot (+acks)
    eq(rd.chan.pendingRequest, nil, "pending request cleared once state arrived")
    eq(view(rd), view(ml), "peer converged")
end)

test("ack retry: an unacked targeted snapshot is re-sent, then gives up", function()
    reset()
    local ml = makeHost("ML", true, { maxAttempts = 2 })
    local rd = makeHost("Raider", false, { maxAttempts = 2 })
    ml.roster = { ML = true, Raider = true } -- the peer is genuinely present (drops are network, not a leave)
    setLine(ml, "L1", "pending")
    -- peer requests; ML answers, but every reply (and thus the ack) is dropped.
    -- maxAttempts=2 => initial targeted send + 1 resend (at 2s), give up on the tick after.
    rd.chan:RequestSync(); deliver()         -- ML gets RQ, sends targeted snapshot, records outstanding
    local reqId = next(ml.chan.outstanding)
    check(reqId ~= nil, "authority tracked an outstanding targeted send")
    clearWire()                              -- drop the snapshot (no ack will come)

    CLOCK = 1002; ml.chan:Tick(CLOCK); clearWire()  -- resend (attempt 2)
    eq(ml.chan.outstanding[reqId].attempts, 2, "authority resent the targeted snapshot")
    CLOCK = 1006; ml.chan:Tick(CLOCK)               -- attempts at max (2) reached on next due
    eq(ml.chan.outstanding[reqId], nil, "authority gave up after maxAttempts")
    check(countEv(ml, "give-up", function(d) return d.kind == "ack" and d.reason == "max" end) == 1, "logged an ack give-up")
end)

test("ack retry stops immediately when the target leaves the roster", function()
    reset()
    local ml = makeHost("ML", true)
    local rd = makeHost("Raider", false)
    ml.roster = { ML = true, Raider = true }
    setLine(ml, "L1", "pending")
    rd.chan:RequestSync(); deliver()
    local reqId = next(ml.chan.outstanding)
    check(reqId ~= nil, "outstanding recorded")
    clearWire()
    ml.roster.Raider = nil                   -- the peer logged out / left the raid
    CLOCK = 1002; ml.chan:Tick(CLOCK)
    eq(ml.chan.outstanding[reqId], nil, "stopped retrying a peer that left")
    check(countEv(ml, "give-up", function(d) return d.reason == "left" end) == 1, "logged a roster-leave give-up")
end)

test("request with no authority is a no-op and the lib never polls for one", function()
    reset()
    local ml = makeHost("ML", true)
    local rd = makeHost("Raider", false)
    rd.authority = ""                         -- host has not resolved the authority yet
    rd.chan:RequestSync()
    eq(countEv(rd, "req"), 0, "no request sent while the authority is unknown")
    eq(rd.chan.pendingRequest, nil, "no pending state: the lib does not hold a deferred request")
    CLOCK = 1002; rd.chan:Tick(CLOCK)
    eq(countEv(rd, "req"), 0, "Tick does not poll the host's authority resolver")

    -- the HOST owns the timing: it re-requests once it knows the authority
    rd.authority = "ML"
    rd.chan:RequestSync()
    eq(countEv(rd, "req"), 1, "request fires when the host re-requests with an authority known")
    deliver(); deliver()
    eq(view(rd), view(ml), "peer converged")
end)

test("reqIds stay unique across channel lifetimes (reload) via the nonce", function()
    reset()
    local function freshRaider(nonce)
        return WeirdSync:NewChannel("WST", {
            selfName = "Raider", nonce = nonce,
            isAuthority = function() return false end,
            authorityName = function() return "ML" end,
        })
    end
    local a = freshRaider("100"); a:RequestSync()
    local b = freshRaider("200"); b:RequestSync()   -- a "reload": reqSeq resets to 1, nonce differs
    local idA, idB = a.pendingRequest.reqId, b.pendingRequest.reqId
    check(idA ~= idB, "two lifetimes mint distinct reqIds (got " .. tostring(idA) .. " vs " .. tostring(idB) .. ")")
    check(idA == "Raider:100.1" and idB == "Raider:200.1", "reqId embeds nonce + per-life seq")
end)

test("zone-in triggers a sync request", function()
    reset()
    local ml = makeHost("ML", true)
    local rd = makeHost("Raider", false)
    rd.chan:NotifyZoneIn()
    check(rd.chan.pendingRequest ~= nil, "zone-in issued a sync request")
    eq(countEv(rd, "req"), 1, "exactly one request on zone-in")
    rd.chan:NotifyZoneIn()                   -- a second zone-in while pending is a no-op
    eq(countEv(rd, "req"), 1, "no duplicate request while one is pending")
end)

test("duplicate / stale delta is ignored (idempotent, no double-apply)", function()
    reset()
    local ml = makeHost("ML", true)
    local rd = makeHost("Raider", false)
    ml.chan:Broadcast(true); deliver()
    deltaChange(ml, "L1", "rolling")
    local snapshot = {}
    for _, m in ipairs(WIRE) do snapshot[#snapshot + 1] = m end
    deliver()                                -- apply once
    local applied = countEv(rd, "recv-lot")
    -- replay the same delta bytes again
    for _, m in ipairs(snapshot) do rd.chan:OnReceive(m.sender, m.msg) end
    eq(countEv(rd, "recv-lot"), applied, "a replayed stale delta was ignored")
    eq(view(rd), view(ml), "store unchanged by the replay")
end)

test("two peers, one drops a delta, both converge", function()
    reset()
    local ml = makeHost("ML", true)
    local r1 = makeHost("R1", false)
    local r2 = makeHost("R2", false)
    ml.roster = { ML = true, R1 = true, R2 = true }
    ml.chan:Broadcast(true); deliver()
    -- a delta that only R1 receives (R2's copy is dropped). Model by delivering to R1 only.
    deltaChange(ml, "L1", "rolling")
    do
        local msgs = WIRE; WIRE = {}
        for _, m in ipairs(msgs) do if m.sender == "ML" then r1.chan:OnReceive(m.sender, m.msg) end end
    end
    deltaChange(ml, "L1", "resolved")        -- R2 will see this with a gap
    deliver()                                -- R1 contiguous; R2 gaps -> RQ
    settle()                                 -- resync round-trips until the wire drains
    eq(view(r1), view(ml), "R1 converged")
    eq(view(r2), view(ml), "R2 converged after gap-triggered resync")
end)

-- ===========================================================================
print("")
print(string.format("=== WeirdSync battery: %d passed, %d failed ===", pass, fail))
if fail > 0 then
    print("FAILURES:")
    for _, f in ipairs(failures) do print("  - " .. f) end
    os.exit(1)
end
