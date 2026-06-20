-- WeirdSync-1.0
--
-- A small reliable state-synchronization library for 3.3.5a addons, built on AceComm-3.0.
-- One authority (e.g. the loot master) replicates an evolving table of state to many peers
-- (the raid) and guarantees a peer that missed traffic while zoning/dead/disconnected
-- converges back to the authority's state without a human noticing.
--
-- The library owns DELIVERY: a monotonic revision, snapshot/delta framing, gap detection +
-- resync, reliable request/response, targeted-send acknowledgement, retry/backoff, give-up.
-- The host owns ALL payload semantics: a snapshot or delta "line" is an opaque array of
-- strings the library relays and stamps but never interprets. This keeps the lib data-agnostic
-- and reusable across addons. See DESIGN.md in this folder for the full contract.
--
-- Delivery semantics: at-least-once with eventual convergence. Not exactly-once, not ordered.
-- Duplicate or reordered messages are harmless because the host's apply is idempotent.

local MAJOR, MINOR = "WeirdSync-1.0", 1
assert(LibStub, MAJOR .. " requires LibStub")
local WeirdSync = LibStub:NewLibrary(MAJOR, MINOR)
if not WeirdSync then return end -- already loaded a newer or equal version

WeirdSync.channels = WeirdSync.channels or {}

-- ---------------------------------------------------------------------------
-- wire codec: fields joined by a record-separator byte (0x1e) that never appears in
-- normal item/player text, so no escaping is needed. Field 1 is the message type tag.
-- ---------------------------------------------------------------------------
local SEP = string.char(30)

local function encode(fields)
    return table.concat(fields, SEP)
end

local function decode(msg)
    local out = {}
    -- append a trailing SEP so the final field (even if empty) is captured.
    for part in (msg .. SEP):gmatch("(.-)" .. SEP) do
        out[#out + 1] = part
    end
    return out
end

-- ---------------------------------------------------------------------------
-- channel
-- ---------------------------------------------------------------------------
local Channel = {}
Channel.__index = Channel

local function noop() end

local function now()
    return (GetTime and GetTime()) or 0
end

-- normalize a player name for self-comparison: strip the realm and lowercase.
local function normName(name)
    if not name or name == "" then return "" end
    return (name:match("^[^-]+") or name):lower()
end

function Channel:_backoff(attempt)
    -- exponential: base * mul^(attempt-1) -> 2, 4, 8, 16 with the defaults.
    return self.cfg.backoffBase * (self.cfg.backoffMul ^ (attempt - 1))
end

function Channel:_send(fields, dist, target, prio)
    local msg = encode(fields)
    if self.SendCommMessage then
        self:SendCommMessage(self.prefix, msg, dist, target, prio or "BULK")
    end
    self.cb.log("send", { cmd = fields[1], bytes = #msg, prio = prio or "BULK", dist = dist, target = target })
end

-- Emit a full snapshot as SB -> SE* -> SD. A RAID broadcast bumps the shared revision so every
-- peer rebaselines to it. A targeted (WHISPER) snapshot carries the authority's CURRENT
-- revision and must NOT bump it: bumping would advance the shared rev without the rest of the
-- raid seeing the SB, making everyone else's next delta look like a gap (a resync storm).
function Channel:_emitSnapshot(dist, target, reqId)
    local rev
    if target then
        rev = self.rev
    else
        self.rev = self.rev + 1
        rev = self.rev
    end
    self:_send({ "SB", self.cb.epoch(), tostring(rev), reqId or "" }, dist, target)
    self.cb.buildSnapshot(function(lineFields)
        local f = { "SE" }
        for _, v in ipairs(lineFields) do f[#f + 1] = v end
        self:_send(f, dist, target)
    end)
    self:_send({ "SD", self.cb.epoch() }, dist, target)
    self._pending = {} -- a snapshot supersedes any queued deltas
end

function Channel:_sendDeltas(lines)
    for _, line in ipairs(lines) do
        self.rev = self.rev + 1
        local f = { "D", tostring(self.rev) }
        for _, v in ipairs(line) do f[#f + 1] = v end
        self:_send(f, "RAID")
    end
end

-- Authority: queue changed lines (each an opaque array of strings) for the next Broadcast.
function Channel:NotifyChanged(lines)
    self._pending = self._pending or {}
    for _, l in ipairs(lines or {}) do
        self._pending[#self._pending + 1] = l
    end
end

-- Authority: flush. force, or more than deltaMax queued changes, sends a full snapshot
-- (cheaper than N deltas and re-baselines anyone who missed an earlier one); otherwise the
-- queued lines go out as individual deltas.
function Channel:Broadcast(force)
    if not self.cb.isAuthority() then return end
    if force then
        self:_emitSnapshot("RAID", nil)
        return
    end
    local pending = self._pending or {}
    if #pending == 0 then return end
    if #pending > self.cfg.deltaMax then
        self:_emitSnapshot("RAID", nil)
        return
    end
    self:_sendDeltas(pending)
    self._pending = {}
end

-- internal: mint and send a request to a known authority, marking it in-flight for Tick.
function Channel:_sendRequest(auth)
    self.reqSeq = (self.reqSeq or 0) + 1
    -- reqId carries the per-channel nonce so it stays unique across reloads: a fresh channel
    -- resets reqSeq to 1, so without the nonce two reload lifetimes would both mint "<me>:1" and a
    -- stale ack from the prior life could clear the new request's outstanding entry.
    local reqId = self.me .. ":" .. self.nonce .. "." .. self.reqSeq
    self.pendingRequest = { reqId = reqId, attempts = 1, nextAttempt = now() + self:_backoff(1) }
    self:_send({ "RQ", self.me, reqId }, "WHISPER", auth, "NORMAL")
    self.cb.log("req", { reqId = reqId, attempt = 1 })
end

-- Peer: ask the authority for the current full state (reliable; retried by Tick). The authority
-- calling this just broadcasts. Only one request is in flight at a time. If no authority is known
-- yet, this is a no-op: the library does NOT poll the host's authority resolver (that timing is a
-- host concern). The host re-calls RequestSync when its authority resolves; the in-flight guard
-- then collapses repeat calls to a single request.
function Channel:RequestSync()
    if self.cb.isAuthority() then
        self:Broadcast(true)
        return
    end
    if self.pendingRequest then return end -- one request in flight at a time
    local auth = self.cb.authorityName()
    if not auth or auth == "" then return end -- no authority to ask; host re-requests when one resolves
    self:_sendRequest(auth)
end

-- Peer: call on PLAYER_ENTERING_WORLD. A reload/zone-in pulls fresh state, covering a peer
-- that missed deltas while out of the world.
function Channel:NotifyZoneIn()
    if self.cb.isAuthority() then return end
    if self.pendingRequest then return end
    self:RequestSync()
end

-- Routed incoming message (the lib registers its prefix with AceComm; in tests the host calls
-- this directly with the reassembled logical message).
function Channel:OnReceive(sender, message)
    -- Ignore our OWN echoed broadcasts (some servers deliver a sender its own RAID messages).
    -- Only self is dropped: a different sender (a secondary authority, leadership pushing updates)
    -- is still processed, so peer->authority flows remain open.
    if normName(sender) == self.meKey then return end

    local f = decode(message)
    local t = f[1]

    if t == "SB" then
        self._incoming = {
            epoch = f[2],
            rev = tonumber(f[3]) or 0,
            reqId = (f[4] ~= "" and f[4]) or nil,
            lines = {},
        }
    elseif t == "SE" then
        local inc = self._incoming
        if not inc then return end -- stray SE without an SB
        local line = {}
        for i = 2, #f do line[#line + 1] = f[i] end
        inc.lines[#inc.lines + 1] = line
    elseif t == "SD" then
        local inc = self._incoming
        if not inc then return end
        self.cb.applySnapshot(inc.lines, inc.epoch)
        self.lastRev = inc.rev      -- a snapshot re-baselines the revision
        self.pendingRequest = nil   -- our outstanding request (if any) is satisfied
        self._incoming = nil
        self.cb.log("recv-snap", { rev = inc.rev, lines = #inc.lines })
        if inc.reqId then
            -- confirm a TARGETED snapshot was applied so the authority can stop retrying.
            self:_send({ "AK", inc.reqId }, "WHISPER", sender, "ALERT")
        end
    elseif t == "D" then
        local rev = tonumber(f[2]) or 0
        local last = self.lastRev
        if last == nil or rev > last + 1 then
            -- never synced, or a delta was dropped: pull a fresh snapshot once.
            self.cb.log("recv-gap", { rev = rev, lastRev = last })
            if not self.pendingRequest then self:RequestSync() end
            return
        end
        if rev <= last then return end -- stale / duplicate
        local line = {}
        for i = 3, #f do line[#line + 1] = f[i] end
        self.cb.applyLine(line)
        self.lastRev = rev
        self.cb.log("recv-lot", { rev = rev })
    elseif t == "RQ" then
        if not self.cb.isAuthority() then return end
        local reqId = f[3]
        self:_emitSnapshot("WHISPER", sender, reqId)
        self.outstanding[reqId] = { target = sender, reqId = reqId, attempts = 1, nextAttempt = now() + self:_backoff(1) }
    elseif t == "AK" then
        if not self.cb.isAuthority() then return end
        local reqId = f[2]
        if self.outstanding[reqId] then
            self.outstanding[reqId] = nil
            self.cb.log("ack", { reqId = reqId })
        end
    end
end

-- Drive retries. The lib also self-drives this off an OnUpdate frame in-game; tests call it
-- directly with an explicit clock value.
function Channel:Tick(t)
    t = t or now()

    -- authority: re-send targeted snapshots that have not been acked.
    for reqId, o in pairs(self.outstanding) do
        if t >= o.nextAttempt then
            if not self.cb.rosterContains(o.target) then
                self.outstanding[reqId] = nil
                self.cb.log("give-up", { kind = "ack", reqId = reqId, reason = "left" })
            elseif o.attempts >= self.cfg.maxAttempts then
                self.outstanding[reqId] = nil
                self.cb.log("give-up", { kind = "ack", reqId = reqId, reason = "max" })
            else
                o.attempts = o.attempts + 1
                self:_emitSnapshot("WHISPER", o.target, reqId)
                o.nextAttempt = t + self:_backoff(o.attempts)
                self.cb.log("resend", { kind = "ack", reqId = reqId, attempt = o.attempts })
            end
        end
    end

    -- peer: re-send a sync request that has not been answered.
    local pr = self.pendingRequest
    if pr and t >= pr.nextAttempt then
        if pr.attempts >= self.cfg.maxAttempts then
            self.pendingRequest = nil
            self.cb.log("give-up", { kind = "request", reqId = pr.reqId, reason = "max" })
        else
            pr.attempts = pr.attempts + 1
            local auth = self.cb.authorityName()
            self:_send({ "RQ", self.me, pr.reqId }, "WHISPER", auth, "NORMAL")
            pr.nextAttempt = t + self:_backoff(pr.attempts)
            self.cb.log("resend", { kind = "request", reqId = pr.reqId, attempt = pr.attempts })
        end
    end
end

-- ---------------------------------------------------------------------------
-- construction
-- ---------------------------------------------------------------------------
-- cb (host callbacks / config):
--   isAuthority()            -> bool   am I the source of truth
--   authorityName()          -> string whom a peer whispers for resync
--   rosterContains(name)     -> bool   roster-aware give-up (defaults true)
--   epoch()                  -> string rebaseline key (e.g. session id; defaults "")
--   buildSnapshot(emit)      authority emits every state line: emit(fields)
--   applySnapshot(lines, ep) peer replaces local state from a staged full snapshot
--   applyLine(fields)        peer upserts one delta line
--   log(ev, data)            trace sink (defaults to no-op)
--   selfName                 OPTIONAL explicit player name (else UnitName("player"))
--   deltaMax/backoffBase/backoffMul/maxAttempts  OPTIONAL tuning
function WeirdSync:NewChannel(prefix, cb)
    assert(type(prefix) == "string" and prefix ~= "", "WeirdSync:NewChannel requires a prefix")
    cb = cb or {}

    local ch = setmetatable({}, Channel)
    ch.prefix = prefix
    ch.cb = {
        isAuthority = cb.isAuthority or function() return false end,
        authorityName = cb.authorityName or function() return "" end,
        rosterContains = cb.rosterContains or function() return true end,
        epoch = cb.epoch or function() return "" end,
        buildSnapshot = cb.buildSnapshot or noop,
        applySnapshot = cb.applySnapshot or noop,
        applyLine = cb.applyLine or noop,
        log = cb.log or noop,
    }
    ch.cfg = {
        deltaMax = cb.deltaMax or 8,
        backoffBase = cb.backoffBase or 2.0,
        backoffMul = cb.backoffMul or 2.0,
        maxAttempts = cb.maxAttempts or 4,
    }
    ch.rev = 0
    ch.lastRev = nil
    ch.outstanding = {}     -- authority: reqId -> { target, attempts, nextAttempt }
    ch.pendingRequest = nil -- peer: { reqId, attempts, nextAttempt }
    ch._pending = {}        -- authority: queued changed lines awaiting Broadcast
    ch.reqSeq = 0
    ch.me = cb.selfName or (UnitName and UnitName("player")) or "?"
    ch.meKey = normName(ch.me)
    -- per-channel-instance nonce so reqIds are unique across reloads (GetTime keeps climbing
    -- across a /reload, so each channel lifetime gets a distinct value). Injectable for tests.
    ch.nonce = cb.nonce or tostring(math.floor(now()))

    -- transport: register our prefix with AceComm and route inbound to OnReceive.
    local Comm = LibStub("AceComm-3.0", true)
    if Comm and Comm.Embed then
        Comm:Embed(ch)
        if ch.RegisterComm then
            ch:RegisterComm(prefix, function(_, message, _, sender) ch:OnReceive(sender, message) end)
        end
    end

    -- self-driving retry tick (no AceTimer on 3.3.5a; drive off an OnUpdate frame).
    if CreateFrame then
        local fr = CreateFrame("Frame")
        ch._frame = fr
        local acc = 0
        fr:SetScript("OnUpdate", function(_, dt)
            acc = acc + (dt or 0)
            if acc >= 0.5 then acc = 0; ch:Tick() end
        end)
    end

    WeirdSync.channels[prefix] = ch
    return ch
end
