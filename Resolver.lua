local addon = WeirdLoot
local util = addon.util

function addon:InitializeResolver()
end

function addon:BuildRollerList(itemId)
    local session = self:GetCurrentSession()
    local rollers = {}
    local responses = session.responses[itemId] or {}

    for playerKey, shouldRoll in pairs(responses) do
        if shouldRoll then
            local attendee = self:GetAttendee(playerKey) or self:GetRosterProfile(playerKey)
            if attendee then
                rollers[#rollers + 1] = {
                    name = attendee.name or playerKey,
                    className = attendee.className or "",
                    specName = attendee.specName or "",
                    status = attendee.status or "nil",
                    descriptor = util:NormalizeKey((attendee.className or "") .. " " .. (attendee.specName or "")),
                }
            else
                rollers[#rollers + 1] = {
                    name = playerKey,
                    className = "",
                    specName = "",
                    status = "nil",
                    descriptor = "",
                }
            end
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

function addon:RollCandidates(candidates)
    local rolls = {}
    if #candidates == 1 then
        rolls[1] = {
            name = candidates[1].name,
            roll = 100,
            auto = true,
        }
        return rolls
    end

    for _, candidate in ipairs(candidates) do
        rolls[#rolls + 1] = {
            name = candidate.name,
            roll = math.random(1, 100),
            auto = false,
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

local function formatCandidateSummary(candidate)
    local parts = {
        candidate.name or "Unknown",
        util:TitleCaseWords(string.trim((candidate.className or "") .. " " .. (candidate.specName or ""))),
        util:PlayerDisplayStatus(candidate.status),
    }

    return table.concat(parts, " - ")
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

function addon:BuildResultDetail(result)
    local lines = {}
    local quantityText = (result.quantity or 1) > 1 and string.format(" x%d", result.quantity or 1) or ""
    lines[#lines + 1] = "Item: " .. (result.itemName or "") .. quantityText
    lines[#lines + 1] = ""
    lines[#lines + 1] = "All Rollers -"
    if #(result.allRollerDetails or {}) == 0 then
        lines[#lines + 1] = "none"
    else
        for _, roller in ipairs(result.allRollerDetails or {}) do
            local rollText = roller.rollText and (" - (" .. roller.rollText .. ")") or ""
            lines[#lines + 1] = formatCandidateSummary(roller) .. rollText
        end
    end

    lines[#lines + 1] = ""
    lines[#lines + 1] = "LC Names:"
    lines[#lines + 1] = ((result.lcNamesText and result.lcNamesText ~= "") and result.lcNamesText or "none")
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Spec Priority:"
    lines[#lines + 1] = ((result.specPriorityText and result.specPriorityText ~= "") and result.specPriorityText or "none")
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Rolls:"
    if #(result.rollDetails or {}) == 0 then
        lines[#lines + 1] = "none"
    else
        for _, roll in ipairs(result.rollDetails or {}) do
            local rollValue = roll.auto and "AUTO" or tostring(roll.roll or "")
            local namedText = roll.isNamed and " - Named" or ""
            lines[#lines + 1] = string.format("%s - (%s)%s", formatCandidateSummary(roll), rollValue, namedText)
        end
    end

    lines[#lines + 1] = ""
    lines[#lines + 1] = "Winner:"
    if #(result.winnerDetails or {}) == 0 then
        lines[#lines + 1] = "No winner"
    else
        for _, winner in ipairs(result.winnerDetails or {}) do
            local rollValue = winner.auto and "AUTO" or tostring(winner.roll or "")
            lines[#lines + 1] = string.format("%s (%s)", winner.name or "Unknown", rollValue)
        end
    end
    return table.concat(lines, "\n")
end

function addon:SelectWinningRolls(rolls, quantity)
    local winnerCount = 1
    if (quantity or 1) >= 2 then
        winnerCount = math.min(2, #rolls)
    end

    local winners = {}
    for index = 1, winnerCount do
        if rolls[index] then
            winners[#winners + 1] = rolls[index].name
        end
    end

    return winners
end

function addon:BuildResultRecord(item, allRollerNames, allRollerDetails, lcNamesText, specPriorityText, statusRank, prioritizedNames, rolls, rollDetails, winnerDetails)
    local winners = self:SelectWinningRolls(rolls, item.quantity or 1)
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
    }

    if (item.quantity or 1) >= 2 then
        result.summary = string.format("%s x%d -> %s", item.name or "Item", item.quantity or 1, winnersText)
    else
        result.summary = string.format("%s -> %s", item.name or "Item", winnersText)
    end
    result.detailText = self:BuildResultDetail(result)
    return result
end

function addon:ProcessLoot()
    if not self:IsAuthorizedLootMaster() then
        self:Print("Only the loot master can process loot.")
        return
    end

    local session = self:GetCurrentSession()
    local results = {}

    for _, item in ipairs(session.items or {}) do
        local rollers = self:BuildRollerList(item.id)
        local allRollerNames = {}
        local allRollerDetails = {}
        for _, roller in ipairs(rollers) do
            allRollerNames[#allRollerNames + 1] = roller.name
            allRollerDetails[#allRollerDetails + 1] = {
                name = roller.name,
                className = roller.className,
                specName = roller.specName,
                status = roller.status,
            }
        end

        local namedRule = self:GetNamedRule(item.name)
        local lootRule = self:GetLootRule(item.name)

        local namedTier, prioritized = self:FindMatchingTier(namedRule, rollers, function(entry, candidate)
            return entry.playerKey == util:NormalizeKey(candidate.name)
        end)

        if not namedTier and lootRule then
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
            local rolls = self:RollCandidates(statusSurvivors)
            local prioritizedNames = {}
            local rollDetails = {}
            local rollByName = {}
            for _, player in ipairs(statusSurvivors) do
                prioritizedNames[#prioritizedNames + 1] = player.name
            end
            for _, roll in ipairs(rolls) do
                rollByName[util:NormalizeKey(roll.name)] = roll
            end
            for _, roller in ipairs(statusSurvivors) do
                local matchedRoll = rollByName[util:NormalizeKey(roller.name)]
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
            for _, detail in ipairs(allRollerDetails) do
                local matchedRoll = rollByName[util:NormalizeKey(detail.name)]
                detail.rollText = matchedRoll and (matchedRoll.auto and "AUTO" or tostring(matchedRoll.roll)) or nil
            end
            local winnerDetails = {}
            for _, winnerName in ipairs(self:SelectWinningRolls(rolls, item.quantity or 1)) do
                local matchedRoll = rollByName[util:NormalizeKey(winnerName)]
                winnerDetails[#winnerDetails + 1] = {
                    name = winnerName,
                    roll = matchedRoll and matchedRoll.roll or nil,
                    auto = matchedRoll and matchedRoll.auto or false,
                }
            end

            results[#results + 1] = self:BuildResultRecord(
                item,
                allRollerNames,
                allRollerDetails,
                namedRule and namedRule.raw or nil,
                lootRule and lootRule.raw or nil,
                rank,
                prioritizedNames,
                rolls,
                rollDetails,
                winnerDetails
            )
        else
            local statusSurvivors, rank = self:FilterByStatus(prioritized)
            local rolls = self:RollCandidates(statusSurvivors)
            local prioritizedNames = {}
            local rollDetails = {}
            local rollByName = {}
            for _, player in ipairs(statusSurvivors) do
                prioritizedNames[#prioritizedNames + 1] = player.name
            end
            for _, roll in ipairs(rolls) do
                rollByName[util:NormalizeKey(roll.name)] = roll
            end
            for _, roller in ipairs(statusSurvivors) do
                local matchedRoll = rollByName[util:NormalizeKey(roller.name)]
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
            for _, detail in ipairs(allRollerDetails) do
                local matchedRoll = rollByName[util:NormalizeKey(detail.name)]
                detail.rollText = matchedRoll and (matchedRoll.auto and "AUTO" or tostring(matchedRoll.roll)) or nil
            end
            local winnerDetails = {}
            for _, winnerName in ipairs(self:SelectWinningRolls(rolls, item.quantity or 1)) do
                local matchedRoll = rollByName[util:NormalizeKey(winnerName)]
                winnerDetails[#winnerDetails + 1] = {
                    name = winnerName,
                    roll = matchedRoll and matchedRoll.roll or nil,
                    auto = matchedRoll and matchedRoll.auto or false,
                }
            end

            results[#results + 1] = self:BuildResultRecord(
                item,
                allRollerNames,
                allRollerDetails,
                namedRule and namedRule.raw or nil,
                lootRule and lootRule.raw or nil,
                rank,
                prioritizedNames,
                rolls,
                rollDetails,
                winnerDetails
            )
        end
    end

    session.results = results
    self.sessionDb.history = self.sessionDb.history or {}
    self.sessionDb.history[#self.sessionDb.history + 1] = {
        sessionId = session.id,
        timestamp = time(),
        results = util:CloneTable(results),
    }

    if #results > 0 then
        SendChatMessage("Loot has been rolled on, check the Results tab.", "RAID_WARNING")
    end

    self:BroadcastResults(results)
    self:TriggerCallback("RESULTS_UPDATED")
    self:Print("Loot processed.")
end
