-- WeirdComm communication benchmark.
--
-- Quantifies the win from sending session state as ONE serialized+compressed blob
-- (LibSerialize + LibDeflate, the WeirdComm payload codec) versus the current
-- per-line wire (WeirdSync emits M + one A per attendee + one L per lot, each a
-- separate AceComm message). Measures messages-sent and bytes-on-wire, and models
-- the REAL ChromieCraft/AzerothCore limits (see WEIRDCOMM_PLAN.md):
--   * 255-byte hard cap per addon message (ChatHandler.cpp:279)
--   * ~99 addon msgs/sec sustained, 100+ in one second -> 10s mute
--   * counted per SENT message, before distribution (RAID = 1 regardless of size)
--   * no packet-level anti-DOS, no per-tick receive cap
--
-- Run from the addon dir:  luajit tests/commbench.lua
-- It also round-trips the new codec and asserts equality, so it doubles as a
-- correctness check for the serialize/deflate/encode pipeline.

-- ---------------------------------------------------------------------------
-- bootstrap: WoW global string aliases the libs expect, then load them
-- ---------------------------------------------------------------------------
strmatch = string.match; strfind = string.find; strsub = string.sub; strlen = string.len
strrep = string.rep; strchar = string.char; strbyte = string.byte; format = string.format
gsub = string.gsub; gmatch = string.gmatch; tinsert = table.insert; tremove = table.remove
wipe = function(t) for k in pairs(t) do t[k] = nil end return t end

local function loadlib(p) return assert(loadfile(p))() end
loadlib("Libs/LibStub/LibStub.lua")
local LibDeflate = loadlib("Libs/LibDeflate/LibDeflate.lua")
local LibSerialize = loadlib("Libs/LibSerialize/LibSerialize.lua")
local WeirdComm = loadlib("Libs/WeirdComm-1.0/WeirdComm-1.0.lua")

-- ---------------------------------------------------------------------------
-- real-server transport + limit model
-- ---------------------------------------------------------------------------
local PREFIX = "WLSYNC"              -- WeirdSync/WeirdComm prefix (6 bytes)
local WIRE_MAX = 254                 -- AceComm's safe prefix+text ceiling (server hard-rejects >255)
local SERVER_ADDON_MSGS_PER_SEC = 99 -- 100+ in one second -> 10s mute (AddonMessageCount=100)

-- Chunk a logical payload exactly as AceComm does: one message if it fits under
-- (WIRE_MAX - #prefix), else multipart with 1 extra prefix byte per chunk.
-- Returns (messageCount, bytesOnWire) where bytesOnWire counts prefix+chunk per message.
local function chunkize(payloadLen, prefixLen)
    local oneShot = WIRE_MAX - prefixLen
    if payloadLen <= oneShot then
        return 1, prefixLen + payloadLen
    end
    local per = oneShot - 1                       -- multipart indicator costs 1 prefix byte
    local n = math.ceil(payloadLen / per)
    -- last chunk is the remainder; all carry prefix(+1)
    local bytes = n * (prefixLen + 1) + payloadLen
    return n, bytes
end

-- ---------------------------------------------------------------------------
-- representative raid + ledger (25 raiders, 15 surfaced lots)
-- ---------------------------------------------------------------------------
local CLASSES = {
    { "Warrior", "Fury" }, { "Warrior", "Protection" }, { "Paladin", "Holy" },
    { "Paladin", "Retribution" }, { "Death Knight", "Blood" }, { "Death Knight", "Frost" },
    { "Hunter", "Marksmanship" }, { "Rogue", "Combat" }, { "Priest", "Shadow" },
    { "Priest", "Discipline" }, { "Shaman", "Enhancement" }, { "Shaman", "Restoration" },
    { "Mage", "Frost" }, { "Warlock", "Affliction" }, { "Druid", "Balance" },
    { "Druid", "Restoration" },
}
local NAMES = {
    "Aragorn", "Legolas", "Gimli", "Boromir", "Faramir", "Eowyn", "Theoden", "Eomer",
    "Galadriel", "Elrond", "Arwen", "Gandalf", "Saruman", "Radagast", "Bilbo", "Frodo",
    "Samwise", "Peregrin", "Meriadoc", "Denethor", "Celeborn", "Thranduil", "Glorfindel",
    "Haldir", "Treebeard",
}
local STATUSES = { "raider", "trial", "raider", "raider", "bench" }

local function buildAttendees(n)
    local out = {}
    for i = 1, n do
        local cls = CLASSES[((i - 1) % #CLASSES) + 1]
        out[i] = {
            name = NAMES[((i - 1) % #NAMES) + 1] .. (i > #NAMES and tostring(i) or ""),
            className = cls[1], specName = cls[2],
            status = STATUSES[((i - 1) % #STATUSES) + 1],
        }
    end
    return out
end

local function linkFor(itemId, name)
    return "|cffa335ee|Hitem:" .. itemId .. ":0:0:0:0:0:0:0:80|h[" .. name .. "]|h|r"
end

-- A resolved lot's "record breakdown" blob: the human-readable reasoning the ML
-- sees and (current wire) ships to raiders. Deliberately repetitive phrasing, which
-- is exactly what LibSerialize dedup + deflate exploit.
local function recordBlob(winner, item)
    return "Resolved " .. item .. " to " .. winner ..
        ": bracket BiS beats MS; named-item priority matched; roster status raider; "
        .. "roll 94 vs 71; loot-council fallback not needed."
end

local ITEMNAMES = {
    "Mantle of the Fallen", "Helm of Cleansing Light", "Band of Eternal Vigil",
    "Bladed Pauldrons", "Sabatons of Endless Night", "Greatsword of the Vanquished",
    "Cloak of the Shadowed Vale", "Gauntlets of the Crusade", "Leggings of Wrath",
    "Pendant of the Grateful Dead", "Ring of Rotting Sinew", "Shroud of Reverie",
    "Bracers of the Herald", "Belt of the Titans", "Boots of the Iron Council",
}

local function buildLots(n, attendees)
    local out = {}
    for i = 1, n do
        local itemId = 40000 + i
        local item = ITEMNAMES[((i - 1) % #ITEMNAMES) + 1]
        local resolved = (i % 3 ~= 0)       -- ~2/3 resolved, ~1/3 still rolling
        local responses = {}
        for j = 1, 5 do                      -- 5 raiders registered interest
            local a = attendees[((i + j) % #attendees) + 1]
            responses[a.name] = ({ "BiS", "MS", "MU", "OS", "Pass" })[j]
        end
        local lot = {
            id = i, itemId = itemId, link = linkFor(itemId, item),
            state = resolved and "resolved" or "rolling",
            count = (i % 4 == 0) and 2 or 1,  -- a few multi-copy drops
            responses = responses,
        }
        if resolved then
            local winner = attendees[(i % #attendees) + 1].name
            lot.awards = {}
            for c = 1, lot.count do
                lot.awards[c] = { winner = winner, state = "owed", holder = "Masterlooter" }
            end
            lot.record = recordBlob(winner, item)
        end
        out[i] = lot
    end
    return out
end

-- ---------------------------------------------------------------------------
-- OLD scheme: faithful model of the current per-line wire
--   M line + one A line per attendee + one L line per lot, fields joined by
--   char(30), each line its own AceComm message (WeirdSync _send per line).
-- ---------------------------------------------------------------------------
local SEP = string.char(30)
local function encodeLine(fields) return table.concat(fields, SEP) end

local function oldScheme(mlName, seq, attendees, lots)
    local lines = {}
    lines[#lines + 1] = { "M", mlName, tostring(seq) }
    for _, a in ipairs(attendees) do
        lines[#lines + 1] = { "A", a.name, a.className, a.specName, a.status }
    end
    for _, lot in ipairs(lots) do
        local winners = {}
        for _, aw in ipairs(lot.awards or {}) do winners[#winners + 1] = aw.winner end
        local resp = {}
        for p, t in pairs(lot.responses or {}) do resp[#resp + 1] = p .. "=" .. t end
        lines[#lines + 1] = {
            "L", "1700000000", tostring(lot.id), tostring(lot.itemId), lot.state,
            tostring(lot.count), table.concat(resp, ","), table.concat(winners, ","),
            "", tostring(seq), "", lot.record or "",
        }
    end
    -- WeirdSync frames the burst as SB ... SD (two control messages around the lines).
    local msgs, bytes = 2, 0                          -- SB + SD
    bytes = bytes + (#PREFIX + #encodeLine({ "SB", "1700000000", tostring(seq), "" }))
    bytes = bytes + (#PREFIX + #encodeLine({ "SD", "1700000000" }))
    for _, line in ipairs(lines) do
        local m, b = chunkize(#encodeLine(line), #PREFIX)
        msgs = msgs + m; bytes = bytes + b
    end
    return { messages = msgs, bytes = bytes, lines = #lines }
end

-- ---------------------------------------------------------------------------
-- NEW scheme: WeirdComm payload codec on the whole snapshot table.
--   serialize -> pick smaller of {raw, deflated} -> EncodeForWoWAddonChannel
--   -> chunk across frames. Round-trips and asserts equality.
-- ---------------------------------------------------------------------------
local function newScheme(snapshot)
    -- the REAL WeirdComm codec/chunker, so these numbers match what ships
    local FP = WeirdComm.WIRE_MAX - #PREFIX - WeirdComm.HEADER_LEN - 1
    local frames = assert(WeirdComm.EncodeFrames(snapshot, 0, FP, 96))
    local bytes = 0
    for _, f in ipairs(frames) do bytes = bytes + #PREFIX + #f end
    local ok, back = WeirdComm.DecodeFrames(frames)

    -- also report the codec internals for context
    local ser = LibSerialize:Serialize(snapshot)
    local deflated = LibDeflate:CompressDeflate(ser)
    local useDeflate = #deflated < #ser
    local wire = LibDeflate:EncodeForWoWAddonChannel(useDeflate and deflated or ser)
    return {
        messages = #frames, bytes = bytes,
        serialized = #ser, deflated = #deflated, useDeflate = useDeflate,
        wire = #wire, roundtrip = ok, decoded = back,
    }
end

-- ---------------------------------------------------------------------------
-- run + report
-- ---------------------------------------------------------------------------
local pass, fail = 0, 0
local function ok(cond, label)
    if cond then pass = pass + 1 else fail = fail + 1; print("  FAIL " .. label) end
end

local function deepeq(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return a == b end
    for k, v in pairs(a) do if not deepeq(v, b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end

local RAIDERS, LOTS = 25, 15
local attendees = buildAttendees(RAIDERS)
local lots = buildLots(LOTS, attendees)
local snapshot = {
    epoch = "1700000000", rev = 12, ml = "Masterlooter", seq = 87,
    attendees = attendees, lots = lots,
}

local old = oldScheme(snapshot.ml, snapshot.seq, attendees, lots)
local new = newScheme(snapshot)

print(string.format("=== WeirdComm benchmark: %d raiders, %d lots ===", RAIDERS, LOTS))
print(string.format("OLD per-line wire : %3d messages, %5d bytes on wire (%d logical lines)",
    old.messages, old.bytes, old.lines))
print(string.format("NEW codec (%-8s): %3d messages, %5d bytes on wire",
    new.useDeflate and "deflate" or "raw", new.messages, new.bytes))
print(string.format("  serialized=%dB  deflated=%dB  wow-encoded=%dB",
    new.serialized, new.deflated, new.wire))
print(string.format("  -> %.1fx fewer messages, %.2fx the bytes",
    old.messages / new.messages, new.bytes / old.bytes))

-- correctness
ok(new.roundtrip, "new codec round-trips (Deserialize ok)")
ok(deepeq(snapshot, new.decoded), "decoded snapshot deep-equals the original")

-- real-limit assertions
ok(WIRE_MAX <= 255, "frame ceiling respects the 255B server cap")
ok(new.messages < old.messages, "new scheme sends fewer messages than old")
ok(new.messages <= SERVER_ADDON_MSGS_PER_SEC, "a single new broadcast is well under the 99/s mute")
ok(old.messages <= SERVER_ADDON_MSGS_PER_SEC,
    "(context) a single old broadcast also fits in one second, but pages slowly through CTL's 800 B/s")

-- ---------------------------------------------------------------------------
-- Phase 2 measurement: the CURRENT flat-string lot encoding (EncodeLot's 11 positional fields, with
-- the result breakdown packed into one triple-delimiter blob string) vs the proposed STRUCTURED-table
-- lot, for the SAME ledger with full breakdowns. The flat form buries every player/class name inside
-- one opaque blob string per lot, hidden from LibSerialize's string/table dedup (only deflate sees the
-- repetition); the structured form exposes those names as values, so dedup collapses the heavy
-- cross-lot recurrence BEFORE deflate runs.
-- ---------------------------------------------------------------------------
local BLOB_PART, BLOB_ROW, BLOB_COL = string.char(29), string.char(28), string.char(31)
local function packRows(list, cols)
    local rows = {}
    for _, d in ipairs(list or {}) do rows[#rows + 1] = table.concat(cols(d), BLOB_COL) end
    return table.concat(rows, BLOB_ROW)
end
local function encResponses(map)
    local p = {}; for k, v in pairs(map or {}) do p[#p + 1] = k .. "=" .. v end
    table.sort(p); return table.concat(p, ",")
end

local POOL = {}
for i = 1, 25 do POOL[i] = NAMES[((i - 1) % #NAMES) + 1] .. (i > #NAMES and tostring(i) or "") end

-- a source ledger with FULL result breakdowns; names recur across lots (the dedup target)
local function buildRichLots(n)
    local TIERS = { "BiS", "MS", "MU", "OS", "Pass" }
    local out = {}
    for i = 1, n do
        local responses, allRollers, rollDetails = {}, {}, {}
        for j = 1, 8 do
            local nm = POOL[((i + j) % #POOL) + 1]
            allRollers[#allRollers + 1] = { name = nm, responseType = TIERS[(j % 5) + 1], rollText = "rolled " .. (40 + j) }
            if j <= 5 then
                responses[nm] = TIERS[(j % 5) + 1]
                rollDetails[#rollDetails + 1] = { name = nm, roll = 40 + j * 3, auto = (j % 2 == 0), isNamed = (j == 1) }
            end
        end
        local winner = POOL[(i % #POOL) + 1]
        out[i] = {
            id = i, itemId = 40000 + i, state = "resolved", count = (i % 4 == 0) and 2 or 1, seq = 80 + i,
            responses = responses, winners = { winner },
            record = {
                allRollerDetails = allRollers, rollDetails = rollDetails,
                winnerDetails = { { name = winner, roll = 98, auto = false } },
                specPriorityText = "Fury > Arms; Prot last", lcNamesText = "", isLootCouncil = false,
            },
        }
    end
    return out
end

-- a lot encoded the CURRENT way: flat positional array, breakdown as one blob string (field 11)
local function flatLine(lot)
    local r = lot.record
    local blob = table.concat({
        packRows(r.allRollerDetails, function(d) return { d.name or "", d.responseType or "", d.rollText or "" } end),
        packRows(r.rollDetails, function(d) return { d.name or "", tostring(d.roll or ""), d.auto and "1" or "", d.isNamed and "1" or "" } end),
        packRows(r.winnerDetails, function(d) return { d.name or "", tostring(d.roll or ""), d.auto and "1" or "" } end),
        r.specPriorityText or "", r.lcNamesText or "", r.isLootCouncil and "1" or "",
    }, BLOB_PART)
    return { "L", "1700000000", tostring(lot.id), tostring(lot.itemId), lot.state, tostring(lot.count),
        encResponses(lot.responses), table.concat(lot.winners or {}, ","), "", tostring(lot.seq), "", blob }
end

-- a lot encoded the PHASE 2 way: structured, names exposed as values for dedup
local function tableLine(lot)
    return { t = "L", id = lot.id, itemId = lot.itemId, state = lot.state, count = lot.count, seq = lot.seq,
        responses = lot.responses, winners = lot.winners, record = lot.record }
end

local function snapOf(lineFn, richLots, atts)
    local lines = { { "M", "Masterlooter", "87" } }
    for _, a in ipairs(atts) do lines[#lines + 1] = { "A", a.name, a.className, a.specName, a.status } end
    for _, lot in ipairs(richLots) do lines[#lines + 1] = lineFn(lot) end
    return { "SNAP", "1700000000", "12", "", lines }
end

local function measure(value)
    local FP = WeirdComm.WIRE_MAX - #PREFIX - WeirdComm.HEADER_LEN - 1
    local frames = assert(WeirdComm.EncodeFrames(value, 0, FP, 96))
    local bytes = 0; for _, f in ipairs(frames) do bytes = bytes + #PREFIX + #f end
    local ser = LibSerialize:Serialize(value)
    local def = LibDeflate:CompressDeflate(ser)
    local rt = select(1, WeirdComm.DecodeFrames(frames))
    return { messages = #frames, bytes = bytes, serialized = #ser, deflated = #def, roundtrip = rt }
end

local richLots = buildRichLots(LOTS)
local mFlat = measure(snapOf(flatLine, richLots, attendees))
local mTbl = measure(snapOf(tableLine, richLots, attendees))

print(string.format("\n=== Phase 2: flat-string lot encoding vs structured-table (%d lots, full breakdowns) ===", LOTS))
print(string.format("flat (EncodeLot+blob): %2d msgs  serialized=%dB  deflated=%dB  ->  %d bytes on wire",
    mFlat.messages, mFlat.serialized, mFlat.deflated, mFlat.bytes))
print(string.format("structured tables    : %2d msgs  serialized=%dB  deflated=%dB  ->  %d bytes on wire",
    mTbl.messages, mTbl.serialized, mTbl.deflated, mTbl.bytes))
print(string.format("  -> structured is %.0f%% the serialized size, %.0f%% the deflated, %.0f%% the wire bytes",
    100 * mTbl.serialized / mFlat.serialized, 100 * mTbl.deflated / mFlat.deflated, 100 * mTbl.bytes / mFlat.bytes))

ok(mFlat.roundtrip and mTbl.roundtrip, "both lot encodings round-trip")

print(string.format("\n=== commbench: %d passed, %d failed ===", pass, fail))
if fail > 0 then os.exit(1) end
