# WeirdSync-1.0

A small reliable state-synchronization library for 3.3.5a addons, built on AceComm-3.0.

WeirdSync keeps an evolving table of state replicated from one authority (e.g. the loot
master) to many peers (the raid), and guarantees that a peer which missed traffic while
zoning, dead, or briefly disconnected converges back to the authority's state without a
human noticing or re-clicking anything.

## 1. Why this exists

The platform has no reusable reliability layer for addon messages:

- AceComm-3.0 gives transport, multipart chunking, and ChatThrottleLib pacing, but no
  acknowledgements, no retries, no delivery confirmation. Its send callback reports bytes
  handed to the wire, not bytes received.
- The CurseForge `LibSync` is an abandoned 2011 stub (API marked "TBD", zero downloads).
- WeakAuras' sharing (Transmission.lua) is the most-used sync-like feature on the platform
  and still implements only transport + a request/response handshake + a one-shot 5s timeout
  that surfaces an error to a human who then re-clicks. It has no automatic retry, no receipt
  ack, no multi-recipient convergence, and no drift/gap detection, because its job is a
  one-shot, human-driven, 1:1 copy.

Our regime is the opposite: continuous, unattended, raid-wide state that must converge even
when a peer was offline at the wrong instant. That is exactly what every existing option
punts on, so we own a thin layer for it.

## 2. Guarantees and non-goals

Delivery semantics: **at-least-once with eventual convergence.** Not exactly-once, not
strictly ordered.

- Every targeted transfer is retried until acknowledged or abandoned, so it arrives at least
  once (duplicates possible).
- Every broadcast carries a monotonic revision; a peer that sees a gap pulls a fresh
  snapshot, so all peers converge on the authority's state.
- Apply is idempotent on the host side (upsert by id, snapshot replaces wholesale), so
  duplicate or reordered messages are harmless.

Non-goals:

- Not a generic RPC or remote-call framework.
- Not strict total ordering. We provide convergence, not a replicated log.
- Not peer-to-peer multi-master. One authority at a time; the authority can change (see 7.6).
- No compression in v1 (AceComm chunking is enough for our payloads; can add LibDeflate later
  behind the same API without a wire-format break, since payloads are host-opaque).

## 3. Layering

```
  host addon (WeirdLoot)
    owns: what a state line means, dirty tracking, snapshot contents,
          authority identity, roster membership, the trace sink
        |  callbacks (encode/apply/isAuthority/roster/log)
        v
  WeirdSync-1.0
    owns: revision counter, snapshot/delta framing, gap detection + resync,
          reliable request/response, targeted-send ack, retry/backoff, give-up
        |  AceComm prefix
        v
  AceComm-3.0  (chunking + ChatThrottleLib)
        |
  SendAddonMessage  (fire-and-forget)
```

The host owns **all payload semantics**: a snapshot line or delta line is an opaque array of
strings to WeirdSync. WeirdSync owns **all sync mechanics**: revisions, framing, reliability.
This keeps the library data-agnostic and reusable across the Weird* addons (loot, DBM,
vendor, anything that needs raid-wide convergence).

## 4. Public API

A host creates one channel bound to its own AceComm prefix:

```lua
local WeirdSync = LibStub("WeirdSync-1.0")
local chan = WeirdSync:NewChannel(prefix, {
    -- identity / environment (called fresh each time, never cached)
    isAuthority   = function() return addon:IsAuthorizedLootMaster() end,
    authorityName = function() return addon:GetLootMasterName() end,
    rosterContains= function(name) return addon:RosterHas(name) end,
    epoch         = function() return addon:GetCurrentSession().id or "" end, -- rebaseline key

    -- payload (opaque lines = arrays of strings)
    buildSnapshot = function(emit)   -- authority: emit(fields) for every state line
        for _, attendee in ... do emit({ "A", attendee.name, ... }) end
        for _, lot in ... do        emit({ "L", lot.id, ... })     end
    end,
    applySnapshot = function(lines)  -- peer: replace local state from a full staged snapshot
        addon:ApplyRemoteSnapshot(lines)
    end,
    applyLine     = function(fields) -- peer: upsert one delta line
        addon:ApplyRemoteLine(fields)
    end,

    -- observability
    log = function(ev, data) addon:LogCoreEvent(ev, data) end,

    -- tuning (all optional, defaults shown)
    deltaMax    = 8,      -- > this many changed lines in one tick -> send a full snapshot
    backoffBase = 2.0,    -- seconds to first retry
    backoffMul  = 2.0,    -- exponential factor (2,4,8,16...)
    maxAttempts = 4,      -- attempts before give-up + log
})
```

Host drives the channel:

| Call | Who | When |
|---|---|---|
| `chan:Broadcast(force)` | authority | after state changes; `force` sends a full snapshot |
| `chan:NotifyChanged(lines)` | authority | queue the changed lines (host-encoded) for the next Broadcast |
| `chan:RequestSync()` | peer | needs current state (reliable, retried) |
| `chan:NotifyZoneIn()` | peer | on `PLAYER_ENTERING_WORLD`; triggers a RequestSync |
| `chan:Tick(now)` | both | drive retries (lib also self-drives via an OnUpdate frame in-game) |

WeirdSync registers `prefix` with AceComm itself and routes incoming messages internally, so
the host does not hand-route sync traffic. The host keeps its own prefix for non-sync
messages (WeirdLoot's live-roll DROP/WIN/CANCEL/RSP stay on "WeirdLoot"; sync moves to its
own prefix, e.g. "WLSYNC").

## 5. Wire protocol

All WeirdSync messages share the channel prefix and are tagged by a one-letter type in field 1.
Payload lines (`SE`, `D`) carry the host's opaque fields after the lib header.

| Type | Direction | Fields | Meaning |
|---|---|---|---|
| `SB` | authority -> RAID or WHISPER | epoch, rev, reqId | snapshot begin; reqId set only when answering a specific request (targeted/whispered) |
| `SE` | authority | host fields... | one snapshot line (attendee, lot, ...) |
| `SD` | authority | epoch | snapshot done; peer applies staged lines atomically |
| `D`  | authority -> RAID | rev, host fields... | one delta line (upsert) |
| `RQ` | peer -> authority (WHISPER) | requesterName, reqId | request full sync |
| `AK` | peer -> authority (WHISPER) | reqId | confirm a targeted snapshot was applied |

## 6. State-sync mechanics (the convergence layer)

- **Revision.** The authority holds a monotonic `rev`, bumped once per broadcast snapshot and
  once per delta line. Every `SB`/`D` carries it. Each peer tracks `lastRev`.
- **Delta vs snapshot.** `Broadcast()` looks at the changed line count from `NotifyChanged`.
  `<= deltaMax` changed lines go out as individual `D` deltas. More than that, or `force`,
  sends a full `SB`/`SE`*/`SD` snapshot (cheaper than N deltas, and it re-baselines anyone who
  missed an earlier delta).
- **Gap detection.** On a `D`, if `rev > lastRev + 1`, a delta was dropped. The peer calls
  `RequestSync()` once (throttled by a pending flag) and ignores further deltas until a
  snapshot re-baselines `lastRev`. `rev <= lastRev` is a stale/duplicate, dropped.
- **Atomic snapshot apply.** `SB` opens a staging buffer; `SE` lines append; `SD` calls
  `applySnapshot(lines)` once and sets `lastRev` to the snapshot's rev. A stray `SE`/`SD`
  without an `SB` is ignored.
- **Epoch rebaseline.** `SB` carries the host `epoch` (session id). A changed epoch means a
  new session; the peer rebaselines unconditionally rather than treating it as a gap.

## 7. Reliability mechanics (the new layer)

### 7.1 Requester retry (peer side: "I asked and got nothing")

`RequestSync()` mints a `reqId` (peer name + local counter), whispers `RQ` to the authority,
and records `pendingRequest = { reqId, attempts, nextAttempt }`. It is cleared when a
snapshot re-baselines the peer (the snapshot is the response; a matching `reqId` is the
strong signal but any rebaseline clears it). If no snapshot arrives by `nextAttempt`, it
re-whispers `RQ` on exponential backoff up to `maxAttempts`, then logs a `give-up` and
surfaces it. This single mechanism covers **both** a dropped request and a dropped response,
because in either case the peer is left waiting and re-asks.

A `reqId` is `<me>:<nonce>.<seq>`. The nonce is fixed per channel instance, so it differs across
reloads (a fresh channel resets `seq` to 1); without it two reload lifetimes would both mint
`<me>:1` and a stale ack from the prior life could clear the new request's `outstanding` entry.

### 7.2 Targeted-send ack (authority side: "I sent it, did it land?")

When the authority answers an `RQ` from peer P, it whispers the snapshot to **P only** with
the request's `reqId` in `SB`, and records `outstanding[reqId] = { target = P, attempts,
nextAttempt }`. P, on applying that snapshot (`SD` with a reqId), whispers `AK reqId` back.
The authority clears `outstanding[reqId]` on `AK`. If no ack by `nextAttempt`, it re-whispers
the snapshot on the same backoff. This gives the authority **visibility**: it learns whether
its targeted response actually landed, instead of hoping P's own retry covers it. The two
mechanisms overlap safely (duplicate snapshots are idempotent) and cover different observers.

### 7.3 Targeted snapshots must not consume a broadcast rev

A snapshot whispered to one peer carries the authority's **current** `rev`, it does not bump
it. Bumping would advance the shared revision without the rest of the raid seeing the `SB`,
making every other peer's next `D` look like a gap and triggering a resync storm. A targeted
snapshot rebaselines only its recipient to the shared position. Only RAID broadcasts (session
start, forced full resync) bump `rev` for everyone.

### 7.4 Backoff and give-up

Exponential: `backoffBase * backoffMul^(attempt-1)` -> 2s, 4s, 8s, 16s by default. Capped at
`maxAttempts`. The authority stops retrying a target immediately if `rosterContains(target)`
returns false (the peer genuinely left, not a drop). On final give-up either side logs a
`give-up` record and the host surfaces it (authority: "peer X may be out of sync"; peer:
"could not reach loot master").

### 7.5 Stale detection

Per the locked decision: zone-in request only. `NotifyZoneIn()` on `PLAYER_ENTERING_WORLD`
triggers a `RequestSync`, which covers a peer that reloads or re-enters the world. We
deliberately do **not** run a periodic heartbeat; a mid-session dropped delta with no
follow-up traffic is caught on the next delta or the next zone, which is acceptable for loot.

`RequestSync` requires a known authority to send to. If `authorityName()` returns nothing
(e.g. right after a reload, before the client has the loot-method / roster data), the call is
a no-op: **the library never polls the host's authority resolver**, because *when* an
authority becomes available is a host concern, not a sync concern. The host re-calls
`RequestSync` once its authority resolves (in WeirdLoot, the loot-master recheck ticker that
already runs over the first ~15s after load); the in-flight guard collapses repeat calls to a
single request. Only a request the lib has actually *sent* is retried by `Tick` (that is the
packet-loss reliability the lib does own).

### 7.6 Authority change

`authorityName`/`isAuthority` are read fresh on every use, so a loot-master handoff is picked
up automatically: peers whisper `RQ` to the new authority, and the epoch change on the next
snapshot forces a clean rebaseline. No special-case handshake.

## 8. Failure modes covered

| Failure | Mechanism |
|---|---|
| Peer's `RQ` dropped | requester retry (7.1) |
| Authority's snapshot reply dropped | requester retry (7.1) AND ack retry (7.2) |
| A single broadcast delta dropped | gap detection -> resync (6) |
| Peer zoning / reload during the only delta | zone-in RequestSync (7.5) |
| Peer logged out, genuinely gone | roster-aware give-up stops authority retries (7.4) |
| Authority changed mid-session | fresh authority read + epoch rebaseline (7.6) |
| Duplicate / reordered messages | idempotent apply + rev compare (2, 6) |

Explicitly not covered: a peer offline for an entire session who never zones back in while it
is active (it has no state to be wrong about), and total-order replay (out of scope).

## 9. Integration: WeirdLoot onto WeirdSync

Current `Comm.lua` maps cleanly; WeirdSync absorbs the sync mechanics, WeirdLoot keeps payload
semantics.

| Today (Comm.lua) | After |
|---|---|
| `comm.rev` / `comm.lastRev`, gap detection in `OnCommReceived` | WeirdSync internal |
| `BroadcastSession` (SNAP_BEGIN/ATTENDEE/LOT/SNAP_END) | `chan:Broadcast(true)` + `buildSnapshot` callback emitting attendee + lot lines |
| `BroadcastDelta` / `AutoBroadcastSession` / `DELTA_MAX` | `chan:NotifyChanged(<EncodeLot per dirty id>)` + `chan:Broadcast()` |
| `RequestSessionSync` | `chan:RequestSync()` (now reliable) |
| `EncodeLot` / `DecodeLot` | host encode in `buildSnapshot`, host decode in `applySnapshot`/`applyLine` |
| `HandleCommMessage` SNAP_*/LOTD branches | `chan:OnReceive` (lib-internal routing) |
| live-roll DROP/WIN/CANCEL/RSP/SELECTION/NAMED_ITEMS | unchanged, stay on the "WeirdLoot" prefix |

The `send`/`recv-snap`/`recv-lot`/`recv-gap` trace events the checker already understands are
emitted by WeirdSync through the `log` callback, plus new `req`/`ack`/`resend`/`give-up`
events for the reliability layer.

### 9.1 Where LootCore sits

WeirdSync and LootCore never reference each other. LootCore stays comm-agnostic; WeirdSync
stays loot-agnostic. The Session/Comm glue depends on both and is the only seam.

```
  LootCore           owns TRUTH:    identity, lifecycle, resolution, dirty set, seq
     ^  ^                           (no knowledge of the wire)
     |  | host callbacks
     v  v
  Session/Comm glue  owns TRANSLATION: lot <-> opaque line; wires core events to the channel
     ^  ^
     |  | NewChannel callbacks
     v  v
  WeirdSync          owns DELIVERY:  rev, snapshot/delta, gap/resync, retry, ack, give-up
                                     (no knowledge of lots)
```

Authority path: a core transition bumps `seq`, marks the lot dirty, and fires `ledgerChanged`.
The glue drains `core:DrainDirty()`, calls `chan:NotifyChanged(ids)` then `chan:Broadcast()`.
WeirdSync's `buildSnapshot(emit)` re-reads `core:All()` live, so a resync always reflects
current core truth. The lib keeps **no copy** of the state, only rev/reqId/retry bookkeeping.

Peer path: WeirdSync routes an incoming `D` to `applyLine` -> glue decode ->
`core:ApplyRemoteLot(lot, seq)`; a snapshot to `applySnapshot` -> `core:ApplyRemote({seq, lots})`.
A gap routes to `chan:RequestSync()`.

Four consequences of this seam:

- **`seq` and `rev` are distinct counters and both survive.** `seq` is the core's mint-order
  identity; it rides inside the host-opaque line and the lib never reads it. `rev` is the
  lib's broadcast-order revision stamped on the envelope. Same split as today (field 9 = seq,
  field 10 = rev), no conflation.
- **One dirty set, the core's.** WeirdSync keeps none; it only counts the ids the glue hands
  it to choose delta vs snapshot. Nothing to drift.
- **The lib's at-least-once / duplicate-safety is satisfied by the core.** It works precisely
  because `ApplyRemoteLot` is an idempotent upsert keyed by lot id and `ApplyRemote` replaces
  wholesale. A retried delivery is indistinguishable from the first at the core, so the
  reliability layer rests on the core's existing identity invariant.
- **One trace.** WeirdSync logs through the same `addon:LogCoreEvent` sink the core uses, so
  core transitions and sync events interleave in one `WeirdLootDebugLog` and checklog verifies
  them together. `epoch` is the session id (owned by the core/session lifecycle); a core
  `Reset` is a new epoch, which rebaselines peers cleanly.

## 10. Testing

- **Out-of-game battery** (`tests/run.lua`): WeirdSync loads into the mocked WoW env exactly
  like the addon does today. The existing AceComm mock + shared WIRE list carries lib traffic;
  the frozen `CLOCK` + a direct `chan:Tick(now)` call drive retries deterministically. New
  cases: requester retry on dropped `RQ`; requester retry on dropped snapshot reply; ack
  clears an outstanding targeted send; backoff schedule is exact; give-up after `maxAttempts`;
  roster-leave stops retries; targeted snapshot does not bump the shared rev (other peers see
  no gap); a two-peer differential where one peer drops a delta and reconverges.
- **checklog** (`tests/checklog.lua`): extend invariants with reliability ones: every `req`
  is eventually followed by a matching rebaseline or a `give-up`; every targeted snapshot is
  followed by an `ack` or a `give-up`; no `resend` exceeds `maxAttempts`; backoff gaps are
  monotonic per reqId.
- **In-game**: scenarios that exercise a real drop (peer alt-tabbed / zoning during a delta,
  peer reload mid-session, ML handoff), each `/wl debug mark`ed, checked from the
  per-character trace.

## 11. Open questions (resolved)

- Library boundary: **full versioned state-sync** (lib owns rev/delta/snapshot/gap/resync +
  reliability; host owns payload). Decided.
- Transport: **AceComm-3.0**. Decided.
- Name: **WeirdSync-1.0**. Decided.
- Both-direction reliability with minimal acks: requester retry + targeted ack, broadcasts
  stay fire-and-forget. Decided.
- Stale detection: **zone-in request only**, no heartbeat. Decided.
- Give-up: **exponential backoff**, capped, roster-leave stop, logged. Decided.

## 12. Remaining risks

- Extracting working, tested rev/delta/snapshot code from `Comm.lua` into the lib is the main
  risk. Mitigation: the lib ships behind the existing battery first (port the tests, prove
  green), then `Comm.lua` is rewired to call it, then the old paths are deleted, in that order.
- Two retry loops (requester + ack) can briefly double traffic on a real drop. Bounded by
  `maxAttempts` and idempotent apply; acceptable and far below the broadcast-storm we removed.
- `epoch` correctness: if the host returns an unstable epoch, peers would rebaseline
  constantly. The session id is stable per session, so this holds; documented as a host
  contract.
