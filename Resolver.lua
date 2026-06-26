local addon = WeirdLoot
local util = addon.util

function addon:InitializeResolver()
    -- the core delegates winner-picking here, handing us exactly one lot's responses by id.
    if self.lootCore then
        self.lootCore:SetResolver(function(lot) return self:ResolveSessionItem(lot) end)
    end
end

-- Build the roller list from a lot's group-level responses (playerKey -> tier string).
function addon:BuildRollerList(lot)
    local rollers = {}
    local responses = lot and lot.responses or {}
    -- gate-tokens-by-class needs the item name; render it from the lot's itemId.
    local itemName = lot and select(1, util:ItemRender(lot.itemId)) or nil

    for playerKey, choice in pairs(responses) do
        if self:IsResponseActive(choice) and self:IsPlayerAllowedForItem(itemName, playerKey) then
            local attendee = self:GetAttendee(playerKey) or self:GetRosterProfile(playerKey)
            rollers[#rollers + 1] = {
                name = attendee and attendee.name or playerKey,
                className = attendee and attendee.className or "",
                specName = attendee and attendee.specName or "",
                status = attendee and attendee.status or "nil",
                descriptor = util:NormalizeKey(((attendee and attendee.className) or "") .. " " .. ((attendee and attendee.specName) or "")),
                responseType = choice,
            }
        end
    end

    util:SortByName(rollers, "name")
    return rollers
end

function addon:FindMatchingTier(rule, candidates, matcher)
    if not rule or not rule.tiers then
        return nil, candidates
    end

    local unmatched = util:CloneTable(candidates)
    for _, tier in ipairs(rule.tiers) do
        local survivors = {}
        local matchedKeys = {}
        local hasRest = false

        for _, entry in ipairs(tier.entries) do
            if entry.isRest then
                hasRest = true
            else
                for _, candidate in ipairs(candidates) do
                    if not matchedKeys[candidate.name] and matcher(entry, candidate) then
                        survivors[#survivors + 1] = candidate
                        matchedKeys[candidate.name] = true
                    end
                end
            end
        end

        if #survivors > 0 then
            return tier, survivors
        end

        if hasRest then
            return tier, unmatched
        end
    end

    return nil, candidates
end

function addon:FilterByStatus(candidates)
    local highestRank = 0
    local survivors = {}

    for _, candidate in ipairs(candidates) do
        highestRank = math.max(highestRank, util:StatusRank(candidate.status))
    end

    for _, candidate in ipairs(candidates) do
        if util:StatusRank(candidate.status) == highestRank then
            survivors[#survivors + 1] = candidate
        end
    end

    return survivors, highestRank
end

function addon:RollCandidates(candidates, rollAssignments)
    local rolls = {}
    for _, candidate in ipairs(candidates) do
        local assigned = rollAssignments and rollAssignments[util:NormalizeKey(candidate.name)]
        rolls[#rolls + 1] = {
            name = (assigned and assigned.name) or candidate.name,
            roll = (assigned and assigned.roll) or math.random(1, 100),
            auto = assigned and assigned.auto or false,
        }
    end

    table.sort(rolls, function(left, right)
        if left.roll == right.roll then
            return string.lower(left.name) < string.lower(right.name)
        end
        return left.roll > right.roll
    end)

    return rolls
end

local function sortRollsDescending(rolls)
    table.sort(rolls, function(left, right)
        if left.roll == right.roll then
            return string.lower(left.name) < string.lower(right.name)
        end
        return left.roll > right.roll
    end)
end

local function formatCandidateSummary(candidate)
    local nameText = (util:GetClassColorCode(candidate.className) or "|cffffffff") .. (candidate.name or "Unknown") .. "|r"
    local parts = {
        nameText,
        util:TitleCaseWords(string.trim((candidate.className or "") .. " " .. (candidate.specName or ""))),
        util:PlayerDisplayStatus(candidate.status),
    }

    return table.concat(parts, " - ")
end

local function winnerPriorityLabel(winner)
    if winner and winner.isNamed then
        return "LC Prio"
    end
    return nil
end

local RESULT_RESPONSE_GROUPS = {
    { key = "bis", label = "BiS Rollers:" },
    { key = "ms", label = "MS Rollers:" },
    { key = "mu", label = "MU Rollers:" },
    { key = "os", label = "OS Rollers:" },
    { key = "tm", label = "TM Rollers:" },
}

local RESPONSE_PRIORITY_RANKS = {
    bis = 6,
    ms = 5,
    mu = 4,
    os = 3,
    tm = 2,
    pass = 1,
}

local function rollerSortValue(candidate)
    if candidate.auto or candidate.rollText == "AUTO" then
        return 101
    end
    return tonumber(candidate.roll) or tonumber(candidate.rollText) or -1
end

local function sortGroupedRollers(entries)
    table.sort(entries, function(left, right)
        local leftRoll = rollerSortValue(left)
        local rightRoll = rollerSortValue(right)
        if leftRoll == rightRoll then
            return string.lower(left.name or "") < string.lower(right.name or "")
        end
        return leftRoll > rightRoll
    end)
end

local function appendGroupedRollers(lines, candidates)
    local grouped = {}
    for _, group in ipairs(RESULT_RESPONSE_GROUPS) do
        grouped[group.key] = {}
    end

    for _, candidate in ipairs(candidates or {}) do
        local choice = candidate.responseType or "pass"
        if choice ~= "pass" then
            grouped[choice] = grouped[choice] or {}
            grouped[choice][#grouped[choice] + 1] = candidate
        end
    end

    local renderedGroups = 0
    for _, group in ipairs(RESULT_RESPONSE_GROUPS) do
        local entries = grouped[group.key] or {}
        if #entries > 0 then
            sortGroupedRollers(entries)
            if renderedGroups > 0 then
                lines[#lines + 1] = ""
            end

            lines[#lines + 1] = group.label
            for _, candidate in ipairs(entries) do
                local rollText = candidate.rollText and (" - (" .. candidate.rollText .. ")") or ""
                lines[#lines + 1] = formatCandidateSummary(candidate) .. rollText
            end
            renderedGroups = renderedGroups + 1
        end
    end

    if renderedGroups > 0 then
        lines[#lines + 1] = ""
    end
end

function addon:FilterByResponsePriority(candidates)
    local highestRank = 0
    local survivors = {}
    local highestKey = "pass"

    for _, candidate in ipairs(candidates or {}) do
        local responseKey = candidate.responseType or "pass"
        local responseRank = RESPONSE_PRIORITY_RANKS[responseKey] or 0
        if responseRank > highestRank then
            highestRank = responseRank
            highestKey = responseKey
        end
    end

    for _, candidate in ipairs(candidates or {}) do
        local responseKey = candidate.responseType or "pass"
        if (RESPONSE_PRIORITY_RANKS[responseKey] or 0) == highestRank then
            survivors[#survivors + 1] = candidate
        end
    end

    return survivors, highestKey, highestRank
end

function addon:IsCandidateNamedForItem(namedRule, candidateName)
    if not namedRule or not namedRule.tiers then
        return false
    end

    local candidateKey = util:NormalizeKey(candidateName or "")
    for _, tier in ipairs(namedRule.tiers) do
        for _, entry in ipairs(tier.entries or {}) do
            if not entry.isRest and entry.playerKey == candidateKey then
                return true
            end
        end
    end

    return false
end

function addon:FindMatchingNamedTier(rule, candidates)
    if not rule or not rule.tiers then
        return nil, candidates, false
    end

    for _, tier in ipairs(rule.tiers) do
        local survivors = {}
        local matchedKeys = {}
        local hasLootCouncil = false

        for _, entry in ipairs(tier.entries or {}) do
            if entry.isLootCouncil then
                hasLootCouncil = true
            elseif not entry.isRest then
                for _, candidate in ipairs(candidates or {}) do
                    local candidateKey = util:NormalizeKey(candidate.name)
                    if not matchedKeys[candidateKey] and entry.playerKey == candidateKey then
                        survivors[#survivors + 1] = candidate
                        matchedKeys[candidateKey] = true
                    end
                end
            end
        end

        if #survivors > 0 then
            return tier, survivors, false
        end

        if hasLootCouncil then
            return tier, candidates, true
        end
    end

    return nil, candidates, false
end

local function formatPlainCandidateNames(candidates)
    local names = {}
    for _, candidate in ipairs(candidates or {}) do
        if candidate.name and candidate.name ~= "" then
            names[#names + 1] = candidate.name
        end
    end

    if #names == 0 then
        return "none"
    end

    return table.concat(names, ", ")
end

local function formatSpecPriorityDisplay(specPriorityText)
    local normalized = string.trim(specPriorityText or "")
    if normalized == "" then
        return "none"
    end

    local tiers = {}
    for _, tierText in ipairs(util:Split(normalized, ">")) do
        tierText = string.trim(tierText)
        if tierText ~= "" then
            if string.find(tierText, "/", 1, true) then
                local formattedEntries = {}
                for _, entryText in ipairs(util:Split(tierText, "/")) do
                    entryText = string.trim(entryText)
                    formattedEntries[#formattedEntries + 1] = util:NormalizeKey(entryText) == "lc" and "LC" or util:TitleCaseWords(entryText)
                end
                tiers[#tiers + 1] = table.concat(formattedEntries, " / ")
            else
                tiers[#tiers + 1] = util:NormalizeKey(tierText) == "lc" and "LC" or util:TitleCaseWords(tierText)
            end
        end
    end

    if #tiers == 0 then
        return "none"
    end

    return table.concat(tiers, "\n---\n")
end

function addon:RuleHasLootCouncil(rule)
    if not rule or not rule.tiers then
        return false
    end

    for _, tier in ipairs(rule.tiers) do
        for _, entry in ipairs(tier.entries or {}) do
            if entry.isLootCouncil then
                return true
            end
        end
    end

    return false
end

function addon:BuildResultDetail(result)
    local lines = {}
    local quantityText = (result.quantity or 1) > 1 and string.format(" x%d", result.quantity or 1) or ""
    local lcNamesText = string.trim(result.lcNamesText or "")
    local hasLcNames = lcNamesText ~= "" and lcNamesText ~= "none"
    lines[#lines + 1] = "Item: " .. (result.itemName or "") .. quantityText
    lines[#lines + 1] = ""
    appendGroupedRollers(lines, result.allRollerDetails or {})

    if hasLcNames then
        lines[#lines + 1] = "LC Names:"
        lines[#lines + 1] = lcNamesText
        lines[#lines + 1] = ""
    end

    lines[#lines + 1] = "Spec Priority:"
    lines[#lines + 1] = formatSpecPriorityDisplay(result.specPriorityText)
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Prioritized Rolls:"
    if #(result.rollDetails or {}) == 0 then
        lines[#lines + 1] = "none"
    else
        for _, roll in ipairs(result.rollDetails or {}) do
            local rollValue = roll.auto and "AUTO" or tostring(roll.roll or "")
            local namedText = roll.isNamed and " - LC" or ""
            lines[#lines + 1] = string.format("%s - (%s)%s", formatCandidateSummary(roll), rollValue, namedText)
        end
    end

    lines[#lines + 1] = ""
    lines[#lines + 1] = "Winner:"
    if result.isLootCouncil then
        lines[#lines + 1] = "Loot Council"
    elseif #(result.winnerDetails or {}) == 0 then
        lines[#lines + 1] = "No winner"
    else
        for _, winner in ipairs(result.winnerDetails or {}) do
            local rollValue = winner.auto and "AUTO" or tostring(winner.roll or "")
            local winnerName = (util:GetClassColorCode(winner.className) or "|cffffffff") .. (winner.name or "Unknown") .. "|r"
            local priorityText = winnerPriorityLabel(winner)
            lines[#lines + 1] = string.format("%s (%s)%s", winnerName, rollValue, priorityText and (" - " .. priorityText) or "")
        end
    end
    return table.concat(lines, "\n")
end

-- A name that is still the bare "item:<id>" fallback util:ItemRender hands back while GetItemInfo is
-- cold (see Util.lua). A resolved record built in that window bakes this into itemName/itemLink.
local function isFallbackItemName(name)
    return (not name) or name == "" or string.find(name, "^item:%d+$") ~= nil
end

-- The real (40194-style) item id for a result record. A record's own itemId field is the LOT key
-- ("L:<seq>"), not the item id; the item id lives on the lot (lootCore identity) and, on raider
-- records, also on realItemId. Fall back to the id embedded in the stored itemLink ("item:40194",
-- present even when cold) so a record whose lot has been pruned still resolves.
function addon:ResultRealItemId(result)
    if not result then return nil end
    if result.realItemId then return result.realItemId end
    local lot = self.lootCore and self.lootCore:Get(result.itemId)
    if lot and lot.itemId then return lot.itemId end
    return tonumber(string.match(result.itemLink or "", "item:(%d+)"))
end

-- Heal a result that resolved while its item was cold: it baked the "item:<id>" fallback into the
-- record's itemName/itemLink/icon/summary/detailText. Once the client has the data, rewrite those
-- stored fields in place so every Results surface shows the real name and it sticks across renders and
-- saves. While still cold, prime the client and flag the shared name ticker to retry. No-op once real.
function addon:RehydrateResult(result)
    if not result or not isFallbackItemName(result.itemName) then return end
    local realId = self:ResultRealItemId(result)
    if not realId then return end
    local name, link, icon = util:ItemRender(realId)
    if not name then
        self:PrimeItemInfo(realId)
        self._lootNamesPending = true
        return
    end
    result.itemName, result.itemLink, result.itemIcon = name, link, icon
    local winnersText = result.winnersText or result.winner or "No winner"
    result.summary = (result.quantity or 1) >= 2
        and string.format("%s x%d -> %s", name, result.quantity or 1, winnersText)
        or string.format("%s -> %s", name, winnersText)
    result.detailText = self:BuildResultDetail(result)
end

function addon:SelectWinningRolls(rolls, quantity)
    -- top-N: one distinct winner per copy (was hard-capped at 2; the core supports any N)
    local winnerCount = math.min(quantity or 1, #rolls)

    local winners = {}
    for index = 1, winnerCount do
        if rolls[index] then
            winners[#winners + 1] = rolls[index].name
        end
    end

    return winners
end

function addon:CollectPriorityWinnerCandidates(rule, candidates, matcher, quantity, allRollByName)
    local orderedCandidates = {}
    local chosen = {}
    local maxCount = quantity or 1

    local function appendSortedCandidates(tierCandidates)
        local statusSurvivors = self:FilterByStatus(tierCandidates)

        table.sort(statusSurvivors, function(left, right)
            local leftRoll = allRollByName[util:NormalizeKey(left.name)] and allRollByName[util:NormalizeKey(left.name)].roll or 0
            local rightRoll = allRollByName[util:NormalizeKey(right.name)] and allRollByName[util:NormalizeKey(right.name)].roll or 0
            if leftRoll == rightRoll then
                return string.lower(left.name or "") < string.lower(right.name or "")
            end
            return leftRoll > rightRoll
        end)

        for _, candidate in ipairs(statusSurvivors) do
            local candidateKey = util:NormalizeKey(candidate.name)
            if not chosen[candidateKey] then
                orderedCandidates[#orderedCandidates + 1] = candidate
                chosen[candidateKey] = true
                if #orderedCandidates >= maxCount then
                    return true
                end
            end
        end

        return false
    end

    for _, tier in ipairs(rule and rule.tiers or {}) do
        local tierCandidates = {}
        local hasRest = false

        for _, entry in ipairs(tier.entries or {}) do
            if entry.isRest then
                hasRest = true
            else
                for _, candidate in ipairs(candidates or {}) do
                    local candidateKey = util:NormalizeKey(candidate.name)
                    if not chosen[candidateKey] and matcher(entry, candidate) then
                        tierCandidates[#tierCandidates + 1] = candidate
                    end
                end
            end
        end

        if #tierCandidates == 0 and hasRest then
            for _, candidate in ipairs(candidates or {}) do
                local candidateKey = util:NormalizeKey(candidate.name)
                if not chosen[candidateKey] then
                    tierCandidates[#tierCandidates + 1] = candidate
                end
            end
        end

        if #tierCandidates > 0 and appendSortedCandidates(tierCandidates) then
            break
        end
    end

    return orderedCandidates
end

function addon:BuildResultRecord(item, allRollerNames, allRollerDetails, lcNamesText, specPriorityText, statusRank, prioritizedNames, rolls, rollDetails, winnerDetails)
    local winners = {}
    for _, winner in ipairs(winnerDetails or {}) do
        winners[#winners + 1] = winner.name
    end
    if #winners == 0 then
        winners = self:SelectWinningRolls(rolls, item.quantity or 1)
    end
    local winnersText = #winners > 0 and table.concat(winners, ", ") or "No winner"
    local result = {
        itemId = item.id,
        itemName = item.name,
        itemLink = item.link,
        itemIcon = item.icon,
        quantity = item.quantity or 1,
        allRollers = allRollerNames,
        allRollerDetails = allRollerDetails or {},
        lcNamesText = lcNamesText,
        specPriorityText = specPriorityText,
        statusTierText = statusRank == 3 and "Main" or (statusRank == 2 and "Designated Alt" or "Nil"),
        prioritizedNames = prioritizedNames,
        finalRolls = rolls,
        rollDetails = rollDetails or {},
        winnerDetails = winnerDetails or {},
        winners = winners,
        winnersText = winnersText,
        winner = winners[1] or "No winner",
        locked = true,
    }

    if (item.quantity or 1) >= 2 then
        result.summary = string.format("%s x%d -> %s", item.name or "Item", item.quantity or 1, winnersText)
    else
        result.summary = string.format("%s -> %s", item.name or "Item", winnersText)
    end
    result.detailText = self:BuildResultDetail(result)
    return result
end

function addon:BuildLootCouncilResultRecord(item, allRollerNames, allRollerDetails, lcNamesText, specPriorityText, statusRank, prioritizedNames)
    local result = {
        itemId = item.id,
        itemName = item.name,
        itemLink = item.link,
        itemIcon = item.icon,
        quantity = item.quantity or 1,
        allRollers = allRollerNames,
        allRollerDetails = allRollerDetails or {},
        lcNamesText = lcNamesText,
        specPriorityText = specPriorityText,
        statusTierText = statusRank == 3 and "Main" or (statusRank == 2 and "Designated Alt" or "Nil"),
        prioritizedNames = prioritizedNames or {},
        finalRolls = {},
        rollDetails = {},
        winnerDetails = {},
        winners = {},
        winnersText = "Loot Council",
        winner = "No winner",
        locked = true,
        isLootCouncil = true,
    }

    if (item.quantity or 1) >= 2 then
        result.summary = string.format("%s x%d -> Loot Council", item.name or "Item", item.quantity or 1)
    else
        result.summary = string.format("%s -> Loot Council", item.name or "Item")
    end
    result.detailText = self:BuildResultDetail(result)
    return result
end

-- Resolve a single session item through the shared bracket -> named -> spec -> status
-- engine (used by both batch ProcessLoot and the live-roll flow). Returns the standard
-- result record. Does NOT lock or append -- the caller does that.
-- Resolve one lot. `lot` is a LootCore lot: identity is lot.itemId, count is lot.count, and
-- the responses live on lot.responses. Display fields are rendered from itemId on demand.
function addon:ResolveSessionItem(lot)
    local record
        local _name, _link, _icon = util:ItemRender(lot.itemId)
        local item = {
            id = lot.id,
            itemId = lot.itemId,
            name = _name or ("item:" .. tostring(lot.itemId)),
            link = _link,
            icon = _icon,
            quantity = lot.count or 1,
        }
        local rollers = self:BuildRollerList(lot)
        local allRollerNames = {}
        local allRollerDetails = {}
        local namedRule = self:GetNamedRule(item.name)
        for _, roller in ipairs(rollers) do
            allRollerNames[#allRollerNames + 1] = roller.name
            allRollerDetails[#allRollerDetails + 1] = {
                name = roller.name,
                className = roller.className,
                specName = roller.specName,
                status = roller.status,
                responseType = roller.responseType,
                isNamed = self:IsCandidateNamedForItem(namedRule, roller.name),
            }
        end

        local allRolls = self:RollCandidates(rollers, item.liveRollAssignments)
        local allRollByName = {}
        for _, roll in ipairs(allRolls) do
            allRollByName[util:NormalizeKey(roll.name)] = roll
        end
        for _, detail in ipairs(allRollerDetails) do
            local matchedRoll = allRollByName[util:NormalizeKey(detail.name)]
            detail.rollText = matchedRoll and (matchedRoll.auto and "AUTO" or tostring(matchedRoll.roll)) or nil
        end
        local lootRule = self:GetLootRule(item.name)
        local defaultSpecPriorityText = lootRule and lootRule.raw or (self:RuleHasLootCouncil(namedRule) and "LC" or nil)
        local responsePriorityCandidates = self:FilterByResponsePriority(rollers)

        local namedTier, prioritized, isLootCouncil = self:FindMatchingNamedTier(namedRule, responsePriorityCandidates)

        if isLootCouncil then
            local councilCandidates = prioritized
            local prioritizedNames = {}
            local rank = 0
            local displaySpecPriorityText = defaultSpecPriorityText or "LC"

            if lootRule then
                local lootTier
                lootTier, councilCandidates = self:FindMatchingTier(lootRule, councilCandidates, function(entry, candidate)
                    local keyA = util:NormalizeKey((candidate.className or "") .. " " .. (candidate.specName or ""))
                    local keyB = util:NormalizeKey((candidate.specName or "") .. " " .. (candidate.className or ""))
                    for _, key in ipairs(entry.matchKeys or {}) do
                        if key ~= "" and (key == keyA or key == keyB) then
                            return true
                        end
                    end
                    return false
                end)
            end

            councilCandidates, rank = self:FilterByStatus(councilCandidates)
            for _, player in ipairs(councilCandidates) do
                prioritizedNames[#prioritizedNames + 1] = player.name
            end

            record = self:BuildLootCouncilResultRecord(
                item,
                allRollerNames,
                allRollerDetails,
                formatPlainCandidateNames(councilCandidates),
                displaySpecPriorityText,
                rank,
                prioritizedNames
            )
        elseif not namedTier and lootRule then
            local lootTier
            lootTier, prioritized = self:FindMatchingTier(lootRule, prioritized, function(entry, candidate)
                local keyA = util:NormalizeKey((candidate.className or "") .. " " .. (candidate.specName or ""))
                local keyB = util:NormalizeKey((candidate.specName or "") .. " " .. (candidate.className or ""))
                for _, key in ipairs(entry.matchKeys or {}) do
                    if key ~= "" and (key == keyA or key == keyB) then
                        return true
                    end
                end
                return false
            end)

            local statusSurvivors, rank = self:FilterByStatus(prioritized)
            local rolls = {}
            local prioritizedNames = {}
            local rollDetails = {}
            local survivorByName = {}
            for _, player in ipairs(statusSurvivors) do
                prioritizedNames[#prioritizedNames + 1] = player.name
                survivorByName[util:NormalizeKey(player.name)] = player
                local matchedRoll = allRollByName[util:NormalizeKey(player.name)]
                if matchedRoll then
                    rolls[#rolls + 1] = {
                        name = matchedRoll.name,
                        roll = matchedRoll.roll,
                        auto = matchedRoll.auto,
                    }
                end
            end
            sortRollsDescending(rolls)
            for _, roller in ipairs(statusSurvivors) do
                local matchedRoll = allRollByName[util:NormalizeKey(roller.name)]
                rollDetails[#rollDetails + 1] = {
                    name = roller.name,
                    className = roller.className,
                    specName = roller.specName,
                    status = roller.status,
                    roll = matchedRoll and matchedRoll.roll or nil,
                    auto = matchedRoll and matchedRoll.auto or false,
                    isNamed = self:IsCandidateNamedForItem(namedRule, roller.name),
                }
            end
            local winnerDetails = {}
            local winnerCandidates = self:CollectPriorityWinnerCandidates(lootRule, responsePriorityCandidates, function(entry, candidate)
                local keyA = util:NormalizeKey((candidate.className or "") .. " " .. (candidate.specName or ""))
                local keyB = util:NormalizeKey((candidate.specName or "") .. " " .. (candidate.className or ""))
                for _, key in ipairs(entry.matchKeys or {}) do
                    if key ~= "" and (key == keyA or key == keyB) then
                        return true
                    end
                end
                return false
            end, item.quantity or 1, allRollByName)
            if #winnerCandidates == 0 then
                for _, winnerName in ipairs(self:SelectWinningRolls(rolls, item.quantity or 1)) do
                    local winnerCandidate = survivorByName[util:NormalizeKey(winnerName)]
                    if winnerCandidate then
                        winnerCandidates[#winnerCandidates + 1] = winnerCandidate
                    end
                end
            end
            for _, winnerCandidate in ipairs(winnerCandidates) do
                local winnerName = winnerCandidate.name
                local matchedRoll = allRollByName[util:NormalizeKey(winnerName)]
                winnerDetails[#winnerDetails + 1] = {
                    name = winnerName,
                    className = winnerCandidate.className,
                    roll = matchedRoll and matchedRoll.roll or nil,
                    auto = matchedRoll and matchedRoll.auto or false,
                    isNamed = self:IsCandidateNamedForItem(namedRule, winnerName),
                }
            end

            record = self:BuildResultRecord(
                item,
                allRollerNames,
                allRollerDetails,
                namedTier and namedTier.raw or nil,
                defaultSpecPriorityText,
                rank,
                prioritizedNames,
                rolls,
                rollDetails,
                winnerDetails
            )
        else
            local statusSurvivors, rank = self:FilterByStatus(prioritized)
            local rolls = {}
            local prioritizedNames = {}
            local rollDetails = {}
            local survivorByName = {}
            for _, player in ipairs(statusSurvivors) do
                prioritizedNames[#prioritizedNames + 1] = player.name
                survivorByName[util:NormalizeKey(player.name)] = player
                local matchedRoll = allRollByName[util:NormalizeKey(player.name)]
                if matchedRoll then
                    rolls[#rolls + 1] = {
                        name = matchedRoll.name,
                        roll = matchedRoll.roll,
                        auto = matchedRoll.auto,
                    }
                end
            end
            sortRollsDescending(rolls)
            for _, roller in ipairs(statusSurvivors) do
                local matchedRoll = allRollByName[util:NormalizeKey(roller.name)]
                rollDetails[#rollDetails + 1] = {
                    name = roller.name,
                    className = roller.className,
                    specName = roller.specName,
                    status = roller.status,
                    roll = matchedRoll and matchedRoll.roll or nil,
                    auto = matchedRoll and matchedRoll.auto or false,
                    isNamed = self:IsCandidateNamedForItem(namedRule, roller.name),
                }
            end
            local winnerDetails = {}
            local winnerCandidates
            if namedTier and namedRule then
                winnerCandidates = self:CollectPriorityWinnerCandidates(namedRule, responsePriorityCandidates, function(entry, candidate)
                    return entry.playerKey == util:NormalizeKey(candidate.name)
                end, item.quantity or 1, allRollByName)
            else
                winnerCandidates = {}
                for _, winnerName in ipairs(self:SelectWinningRolls(rolls, item.quantity or 1)) do
                    local winnerCandidate = survivorByName[util:NormalizeKey(winnerName)]
                    if winnerCandidate then
                        winnerCandidates[#winnerCandidates + 1] = winnerCandidate
                    end
                end
            end
            for _, winnerCandidate in ipairs(winnerCandidates) do
                local winnerName = winnerCandidate.name
                local matchedRoll = allRollByName[util:NormalizeKey(winnerName)]
                winnerDetails[#winnerDetails + 1] = {
                    name = winnerName,
                    className = winnerCandidate.className,
                    roll = matchedRoll and matchedRoll.roll or nil,
                    auto = matchedRoll and matchedRoll.auto or false,
                    isNamed = self:IsCandidateNamedForItem(namedRule, winnerName),
                }
            end

            record = self:BuildResultRecord(
                item,
                allRollerNames,
                allRollerDetails,
                namedTier and namedTier.raw or nil,
                defaultSpecPriorityText,
                rank,
                prioritizedNames,
                rolls,
                rollDetails,
                winnerDetails
            )
        end
    return record
end

-- ProcessLoot (the "Start Rolls" button): kick off live rolls in batches. The first
-- N lots from the loot list go up for roll in parallel; as each batch finishes (every
-- roll resolved or cancelled), the next N start. This replaces the old instant
-- bulk-resolve behavior so the raid actually gets to roll on each item.
function addon:ProcessLoot()
    if not self:IsAuthorizedLootMaster() then
        self:Print("Only the loot master can process loot.")
        return
    end

    local core = self.lootCore
    local queue = {}
    for _, lot in ipairs(core:List()) do
        if lot.state ~= core.STATE.ROLLING and lot.state ~= core.STATE.RESOLVED then
            queue[#queue + 1] = lot.id
        end
    end

    if #queue == 0 then
        self:Print("No unrolled loot to start. Unlock a result to reroll it.")
        return
    end

    queue = self:OrderLotIdsNonEquipFirst(queue)   -- roll non-equipment (bags/mounts) out first

    local batchSize = tonumber(self.db and self.db.options and self.db.options.rollBatchSize) or 5
    if batchSize < 1 then batchSize = 1 end

    self._rollBatch = { queue = queue, batchSize = batchSize, active = {} }
    self:Print(string.format("Starting rolls in batches of %d (%d items queued).", batchSize, #queue))
    self:AdvanceRollBatch()
end

-- Pull the next slice from the queue and StartLiveRoll on each. Called once by ProcessLoot
-- and again every time the active set drains.
function addon:AdvanceRollBatch()
    local batch = self._rollBatch
    if not batch then return end
    while #batch.queue > 0 and self:CountActiveRollBatch() < batch.batchSize do
        local lotId = table.remove(batch.queue, 1)
        local lot = self.lootCore:Get(lotId)
        if lot and lot.state ~= self.lootCore.STATE.ROLLING and lot.state ~= self.lootCore.STATE.RESOLVED then
            batch.active[lotId] = true
            self:StartLiveRoll(lotId)
        end
    end
    if #batch.queue == 0 and self:CountActiveRollBatch() == 0 then
        self:FinishRollBatch()
    end
end

function addon:CountActiveRollBatch()
    local batch = self._rollBatch
    if not batch then return 0 end
    local n = 0
    for _ in pairs(batch.active) do n = n + 1 end
    return n
end

-- Called from ResolveLiveRoll / CancelLiveRoll: drop the lot from the active set and,
-- if the batch has fully drained, advance to the next slice.
function addon:NotifyRollBatchFinished(lotId)
    local batch = self._rollBatch
    if not batch or not batch.active[lotId] then return end
    batch.active[lotId] = nil
    self:AdvanceRollBatch()
end

-- Auto-start path: feed fresh NEW lot ids into the same batch infrastructure used by Start Rolls
-- so the configured Start-Rolls batch size caps how many rolls fire in parallel. Creates a silent
-- batch (no history snapshot / no RAID_WARNING on completion -- background drips shouldn't
-- masquerade as a full Start-Rolls run). If a batch is already running, appends to its queue.
function addon:EnqueueAutoStartLots(lotIds)
    if not lotIds or #lotIds == 0 then return end
    local batchSize = tonumber(self.db and self.db.options and self.db.options.rollBatchSize) or 5
    if batchSize < 1 then batchSize = 1 end
    if not self._rollBatch then
        self._rollBatch = { queue = {}, batchSize = batchSize, active = {}, silent = true }
    end
    for _, id in ipairs(lotIds) do
        self._rollBatch.queue[#self._rollBatch.queue + 1] = id
    end
    self:AdvanceRollBatch()
end

function addon:FinishRollBatch()
    local session = self:GetCurrentSession()
    local silent = self._rollBatch and self._rollBatch.silent
    self._rollBatch = nil

    if silent then
        self:BroadcastSession()
        self:TriggerCallback("RESULTS_UPDATED")
        return
    end

    self.sessionDb.history = self.sessionDb.history or {}
    self.sessionDb.history[#self.sessionDb.history + 1] = {
        sessionId = session.id,
        timestamp = time(),
        results = util:CloneTable(self.lootView.results or {}),
    }

    local text = "All loot rolls finished, check the Results tab."
    local ctl = _G.ChatThrottleLib
    if ctl then
        ctl:SendChatMessage("ALERT", self.prefix, text, "RAID_WARNING")
    else
        SendChatMessage(text, "RAID_WARNING")
    end

    self:BroadcastSession()
    self:TriggerCallback("RESULTS_UPDATED")
    self:Print("Rolls complete.")
end
