-- WeirdComm + WeirdSync integration test.
--
-- weirdcomm.lua tests the transport in isolation and weirdsync.lua tests the reliability logic over
-- a pass-through fake. This test closes the seam: two REAL WeirdComm channels exchange the ACTUAL
-- message shapes WeirdSync produces (a SNAP value carrying every line; a delta D value), over a
-- shared frame wire, through real serialize -> deflate -> chunk -> pace -> reassemble -> deserialize.
--
-- Run from the addon dir:  luajit tests/integration.lua   (exit 1 on any failure)

strmatch = string.match; strfind = string.find; strsub = string.sub; strlen = string.len
strrep = string.rep; strchar = string.char; strbyte = string.byte; format = string.format
gsub = string.gsub; gmatch = string.gmatch; tinsert = table.insert; tremove = table.remove
wipe = function(t) for k in pairs(t) do t[k] = nil end return t end

local function loadlib(p) return assert(loadfile(p))() end
loadlib("Libs/LibStub/LibStub.lua")
loadlib("Libs/LibDeflate/LibDeflate.lua")
loadlib("Libs/LibSerialize/LibSerialize.lua")
local WeirdComm = loadlib("Libs/WeirdComm-1.0/WeirdComm-1.0.lua")

local pass, fail = 0, 0
local function ok(cond, label) if cond then pass = pass + 1 else fail = fail + 1; print("  FAIL " .. tostring(label)) end end
local function test(name, fn) print("[" .. name .. "]"); local g, e = pcall(fn); if not g then fail = fail + 1; print("  ERROR " .. tostring(e)) end end
local function deepeq(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return a == b end
    for k, v in pairs(a) do if not deepeq(v, b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end

-- ---------------------------------------------------------------------------
-- a shared frame wire + a set of real WeirdComm channels, one per simulated player
-- ---------------------------------------------------------------------------
local PREFIX = "WLSYNC"
local WIRE, CLOCK = {}, 1000

local function makePeer(name)
    local inbox = {}
    local ch = WeirdComm:NewChannel(PREFIX, {
        send = function(prefix, text, dist, target)
            WIRE[#WIRE + 1] = { prefix = prefix, text = text, dist = dist, target = target, sender = name }
        end,
        onMessage = function(value, sender, dist) inbox[#inbox + 1] = { value = value, sender = sender, dist = dist } end,
        getTime = function() return CLOCK end,
        selfName = name,
    })
    return ch, inbox
end

-- route everything on the wire to the channels it is addressed to; honour WHISPER targeting
local function deliver(peers)
    local frames = WIRE; WIRE = {}
    for _, fr in ipairs(frames) do
        for cname, ch in pairs(peers) do
            if fr.sender ~= cname then
                if fr.dist == "WHISPER" then
                    if fr.target == cname then ch:OnReceive(fr.prefix, fr.text, fr.dist, fr.sender) end
                else
                    ch:OnReceive(fr.prefix, fr.text, fr.dist, fr.sender)
                end
            end
        end
    end
end

-- advance the clock, drive each pacer, and deliver, until the wire drains and no frames are queued
local function settle(peers)
    for _ = 1, 1000 do
        if #WIRE > 0 then deliver(peers) end
        CLOCK = CLOCK + 0.1
        local pending = false
        for _, ch in pairs(peers) do
            ch:Tick(CLOCK)
            if #ch._hi > 0 or #ch._lo > 0 then pending = true end
        end
        if #WIRE == 0 and not pending then break end
    end
    if #WIRE > 0 then deliver(peers) end
end

-- ---------------------------------------------------------------------------
-- realistic payload shapes, exactly as WeirdSync/Comm produce them
-- ---------------------------------------------------------------------------
local function lotLine(id, itemId, item, winner, blob)
    -- mirrors EncodeLot's positional array: L, sessionId, id, itemId, state, liveCount,
    -- responses, winners, removed, seq, rollRemaining, resultBlob
    return { "L", "1700000000", tostring(id), tostring(itemId), "resolved", "1",
        "Alice=BiS,Bob=MS", winner, "", "42", "", blob or "" }
end

local function snapValue(rev, reqId, nLots)
    local lines = { { "M", "Masterlooter", "42" } }
    for i = 1, 8 do
        lines[#lines + 1] = { "A", "Raider" .. i, "Warrior", "Fury", "raider" }
    end
    for i = 1, nLots do
        lines[#lines + 1] = lotLine(i, 40000 + i, "Item " .. i, "Raider" .. ((i % 8) + 1),
            "Resolved to a winner: bracket BiS beats MS; roster status raider; roll 90 vs 70.")
    end
    return { "SNAP", "1700000000", tostring(rev), reqId or "", lines }
end

-- ===========================================================================
test("a small SNAP syncs ML -> raider through the real codec", function()
    WIRE = {}; CLOCK = 1000
    local mlCh = makePeer("Masterlooter")
    local rdCh, rdIn = makePeer("Raider")
    local peers = { Masterlooter = mlCh, Raider = rdCh }

    local snap = snapValue(7, nil, 3)
    mlCh:Send(snap, "RAID")
    settle(peers)
    ok(#rdIn == 1, "raider received exactly one SNAP (" .. #rdIn .. ")")
    ok(rdIn[1] and deepeq(rdIn[1].value, snap), "SNAP value round-trips deep-equal through real frames")
    ok(rdIn[1] and rdIn[1].sender == "Masterlooter", "sender preserved")
end)

test("a large SNAP spans multiple frames and still reassembles", function()
    WIRE = {}; CLOCK = 1000
    local mlCh = makePeer("Masterlooter")
    local rdCh, rdIn = makePeer("Raider")
    local peers = { Masterlooter = mlCh, Raider = rdCh }

    local snap = snapValue(12, nil, 40)        -- 40 resolved lots with result blobs: multi-frame
    mlCh:Send(snap, "RAID")
    local framesEmitted = #WIRE
    ok(framesEmitted >= 2, "large SNAP was chunked across multiple frames (" .. framesEmitted .. ")")
    settle(peers)
    ok(#rdIn == 1 and deepeq(rdIn[1].value, snap), "large multi-frame SNAP reassembled deep-equal")
end)

test("a delta D value syncs", function()
    WIRE = {}; CLOCK = 1000
    local mlCh = makePeer("Masterlooter")
    local rdCh, rdIn = makePeer("Raider")
    local peers = { Masterlooter = mlCh, Raider = rdCh }

    local d = { "D", "8", lotLine(5, 40005, "Item 5", "Raider3", "") }
    mlCh:Send(d, "RAID")
    settle(peers)
    ok(#rdIn == 1 and deepeq(rdIn[1].value, d), "delta value round-trips")
end)

test("a WHISPER-targeted SNAP reaches only the target", function()
    WIRE = {}; CLOCK = 1000
    local mlCh = makePeer("Masterlooter")
    local aCh, aIn = makePeer("RaiderA")
    local bCh, bIn = makePeer("RaiderB")
    local peers = { Masterlooter = mlCh, RaiderA = aCh, RaiderB = bCh }

    mlCh:Send(snapValue(3, "RaiderA:1.1", 5), "WHISPER", "RaiderA")
    settle(peers)
    ok(#aIn == 1, "the targeted raider received it")
    ok(#bIn == 0, "the other raider did not")
end)

print(string.format("\n=== WeirdComm+WeirdSync integration: %d passed, %d failed ===", pass, fail))
if fail > 0 then os.exit(1) end
