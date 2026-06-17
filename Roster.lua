local addon = WeirdLoot
local util = addon.util

function addon:InitializeRoster()
    self.roster = {
        attendees = {},
        attendeesByName = {},
        rosterDisplay = {},
        isLootMaster = false,
        lootMasterName = nil,
    }
end

function addon:RefreshRoster()
    local attendees = {}
    local attendeesByName = {}
    local count = GetNumRaidMembers() or 0

    for index = 1, count do
        local name, _, _, _, classLocalized, classFileName = GetRaidRosterInfo(index)
        name = name and string.match(name, "^[^-]+") or name
        if name then
            local profile = self:GetRosterProfile(name) or {}
            local className = profile.className or self:NormalizeClassName(classFileName or classLocalized or "")
            local specName = profile.specName or ""
            local status = profile.status or "nil"

            local attendee = {
                index = index,
                name = name,
                className = className,
                specName = specName,
                status = status,
                descriptor = util:NormalizeKey((className or "") .. " " .. (specName or "")),
            }
            attendees[#attendees + 1] = attendee
            attendeesByName[util:NormalizeKey(name)] = attendee
        end
    end

    util:SortByName(attendees, "name")

    self.roster.attendees = attendees
    self.roster.attendeesByName = attendeesByName
    self.roster.rosterDisplay = self:BuildRosterDisplay(attendeesByName)

    self:TriggerCallback("ROSTER_UPDATED")
end

function addon:BuildRosterDisplay(attendeesByName)
    local display = {}
    local seen = {}

    for _, entry in ipairs(self:GetRosterEntries()) do
        local key = util:NormalizeKey(entry.name)
        local attendee = attendeesByName[key]
        display[#display + 1] = {
            name = entry.name,
            className = entry.className,
            specName = entry.specName,
            status = entry.status,
            present = attendee ~= nil,
            descriptor = entry.descriptor,
            source = "configured",
        }
        seen[key] = true
    end

    for key, attendee in pairs(attendeesByName or {}) do
        if not seen[key] then
            display[#display + 1] = {
                name = attendee.name,
                className = attendee.className,
                specName = attendee.specName,
                status = attendee.status or "nil",
                present = true,
                descriptor = attendee.descriptor,
                source = "unconfigured",
            }
        end
    end

    table.sort(display, function(left, right)
        if left.present ~= right.present then
            return left.present
        end
        if left.source ~= right.source then
            return left.source == "configured"
        end
        return util:NormalizeKey(left.name) < util:NormalizeKey(right.name)
    end)

    return display
end

function addon:GetAttendees()
    return self.roster.attendees or {}
end

function addon:GetAttendee(name)
    return self.roster.attendeesByName[util:NormalizeKey(name or "")]
end

function addon:GetRosterDisplayList()
    return self.roster.rosterDisplay or {}
end

local function stripRealm(name)
    return name and string.match(name, "^[^-]+") or name
end

-- Determine the master looter's name and whether *we* drive WeirdLoot, robustly across
-- every group shape (mirrors RCLootCouncil's GetML): raid master-loot, party master-loot,
-- raid leader/assistant, party leader, and solo. The leadership fallback only applies when
-- no master looter is set, matching RCLootCouncil (under master loot, only the ML runs it).
function addon:RefreshLootAuthority()
    local playerName = util:GetPlayerName("player")
    local method, partyMasterIndex, raidMasterIndex = GetLootMethod()
    local numRaid = GetNumRaidMembers() or 0
    local numParty = GetNumPartyMembers() or 0

    -- 1) who is the master looter?
    local lootMasterName
    if method == "master" then
        if raidMasterIndex and raidMasterIndex > 0 then
            lootMasterName = stripRealm(GetRaidRosterInfo(raidMasterIndex))   -- ML in raid
        elseif partyMasterIndex == 0 then
            lootMasterName = playerName                                        -- we are party ML
        elseif partyMasterIndex and partyMasterIndex > 0 then
            lootMasterName = stripRealm(UnitName("party" .. partyMasterIndex)) -- party member ML
        end
    end

    -- 2) are we leadership (or solo)?
    local isLeader = false
    if numRaid > 0 then
        for index = 1, numRaid do
            local name, rank = GetRaidRosterInfo(index)
            if playerName and name and util:NormalizeKey(stripRealm(name)) == util:NormalizeKey(playerName) then
                isLeader = (rank == 2) or (rank == 1)    -- raid leader or assistant
                break
            end
        end
    elseif numParty > 0 then
        isLeader = IsPartyLeader() and true or false     -- party leader
    else
        -- Solo: only act as loot master in explicit test mode (city testing). Otherwise a
        -- normal member logged in alone would wrongly think they're the ML and could
        -- whisper / auto-trade raiders.
        isLeader = (self.db and self.db.testMode) and true or false
    end

    -- 3) resolve authority
    local isLootMaster = false
    if lootMasterName and playerName then
        isLootMaster = util:NormalizeKey(lootMasterName) == util:NormalizeKey(playerName)
    end

    if not isLootMaster and isLeader and method ~= "master" then
        isLootMaster = true                              -- leadership fallback (no ML set)
    end

    if not lootMasterName and isLeader then
        lootMasterName = playerName
    end

    self.roster.lootMasterName = lootMasterName
    self.roster.isLootMaster = isLootMaster

    self:TriggerCallback("AUTHORITY_UPDATED")
end

function addon:IsAuthorizedLootMaster()
    return self.roster.isLootMaster
end

function addon:GetLootMasterName()
    return self.roster.lootMasterName
end

function addon:GetPlayerDescriptor(playerName)
    local attendee = self:GetAttendee(playerName) or self:GetRosterProfile(playerName)
    if not attendee then
        return ""
    end

    local className = attendee.className or ""
    local specName = attendee.specName or ""
    return util:NormalizeKey(className .. " " .. specName)
end
