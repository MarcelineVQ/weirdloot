local addon = WeirdLoot

addon.util = {}
local util = addon.util

-- Canonical hover text for each roll-choice bracket abbreviation. One source so the live-roll
-- popup and the loot tab spell out the same thing and never drift apart.
-- TODO: these are user-facing English strings; move them into a proper localization module
-- (alongside the other display strings) when one exists, instead of hard-coding them here.
addon.RESPONSE_TOOLTIPS = {
    bis = "Best in Slot",
    ms = "Main Spec Upgrade",
    mu = "Minor Upgrade",
    os = "Off Spec",
    tm = "Transmog",
    pass = "Pass",
}

function string.trim(value)
    return (value or ""):match("^%s*(.-)%s*$")
end

-- The numeric item id is the canonical loot identity (links/names vary across clients).
-- Parse it out of any item link or itemString.
function util:ItemIdFromLink(link)
    if type(link) ~= "string" then return nil end
    local id = link:match("|Hitem:(%d+)") or link:match("item:(%d+)")
    return id and tonumber(id) or nil
end

-- Render display fields from an itemId on demand. The link is force-cached by GetItemInfo;
-- if the client hasn't cached it yet, fields may be nil until a later refresh.
function util:ItemRender(itemId)
    if not itemId then return nil end
    local name, link, _, _, _, _, _, _, _, icon = GetItemInfo(itemId)
    return name, link or ("item:" .. itemId), icon or "Interface\\Icons\\INV_Misc_QuestionMark"
end

function util:Split(value, delimiter)
    local results = {}
    if value == nil or value == "" then
        return results
    end

    delimiter = delimiter or ","
    local startIndex = 1

    while true do
        local foundIndex = string.find(value, delimiter, startIndex, true)
        if not foundIndex then
            table.insert(results, string.sub(value, startIndex))
            break
        end

        table.insert(results, string.sub(value, startIndex, foundIndex - 1))
        startIndex = foundIndex + string.len(delimiter)
    end

    return results
end

function util:SplitLines(value)
    local lines = {}
    value = string.gsub(value or "", "\r\n", "\n")
    value = string.gsub(value, "\r", "\n")

    for line in string.gmatch(value, "([^\n]+)") do
        line = string.trim(line)
        if line ~= "" then
            table.insert(lines, line)
        end
    end

    return lines
end

function util:NormalizeKey(value)
    value = string.lower(string.trim(value or ""))
    value = string.gsub(value, "%s+", " ")
    return value
end

function util:CloneTable(source)
    if type(source) ~= "table" then
        return source
    end

    local copy = {}
    for key, value in pairs(source) do
        copy[key] = self:CloneTable(value)
    end
    return copy
end

function util:Contains(list, expected)
    if type(list) ~= "table" then
        return false
    end

    for _, value in ipairs(list) do
        if value == expected then
            return true
        end
    end

    return false
end

function util:TableCount(map)
    local count = 0
    if type(map) ~= "table" then
        return count
    end

    for _ in pairs(map) do
        count = count + 1
    end
    return count
end

function util:SortByName(list, field)
    table.sort(list, function(left, right)
        local leftName = field and left[field] or left.name or left
        local rightName = field and right[field] or right.name or right
        leftName = leftName or ""
        rightName = rightName or ""
        return string.lower(leftName) < string.lower(rightName)
    end)
end

function util:EncodeField(value)
    value = tostring(value or "")
    value = string.gsub(value, "%%", "%%25")
    value = string.gsub(value, "|", "%%7C")
    value = string.gsub(value, "\n", "%%0A")
    value = string.gsub(value, ":", "%%3A")
    return value
end

function util:DecodeField(value)
    value = tostring(value or "")
    value = string.gsub(value, "%%3A", ":")
    value = string.gsub(value, "%%0A", "\n")
    value = string.gsub(value, "%%7C", "|")
    value = string.gsub(value, "%%25", "%%")
    return value
end

function util:JoinEncoded(values)
    local encoded = {}
    for index, value in ipairs(values or {}) do
        encoded[index] = self:EncodeField(value)
    end
    return table.concat(encoded, "|")
end

function util:SplitEncoded(payload)
    local fields = self:Split(payload, "|")
    for index, value in ipairs(fields) do
        fields[index] = self:DecodeField(value)
    end
    return fields
end

function util:PlayerDisplayStatus(status)
    local normalized = self:NormalizeKey(status)
    if normalized == "main" then
        return "Main"
    elseif normalized == "designatedalt" then
        return "Designated Alt"
    end

    return "Unknown"
end

function util:TitleCaseWords(value)
    local normalized = string.trim(value or "")
    if normalized == "" then
        return ""
    end

    return string.gsub(normalized, "(%a)([%w']*)", function(first, rest)
        return string.upper(first) .. string.lower(rest)
    end)
end

function util:StatusRank(status)
    local normalized = self:NormalizeKey(status)
    if normalized == "main" then
        return 3
    elseif normalized == "designatedalt" then
        return 2
    end

    return 1
end

function util:GetPlayerName(unit)
    local name = UnitName(unit)
    if not name then
        return nil
    end

    local shortName = string.match(name, "^[^-]+")
    return shortName or name
end

function util:GetUnitTokenByPlayerName(playerName)
    local expected = self:NormalizeKey(playerName or "")
    if expected == "" then
        return nil
    end

    if self:NormalizeKey(self:GetPlayerName("player") or "") == expected then
        return "player"
    end

    local raidCount = GetNumRaidMembers() or 0
    for index = 1, raidCount do
        local unit = "raid" .. index
        if self:NormalizeKey(self:GetPlayerName(unit) or "") == expected then
            return unit
        end
    end

    local partyCount = GetNumPartyMembers() or 0
    for index = 1, partyCount do
        local unit = "party" .. index
        if self:NormalizeKey(self:GetPlayerName(unit) or "") == expected then
            return unit
        end
    end

    if self:NormalizeKey(self:GetPlayerName("target") or "") == expected then
        return "target"
    end

    return nil
end

function util:GetClassColorCode(className)
    local normalized = self:NormalizeKey(className)
    local tokenByName = {
        ["death knight"] = "DEATHKNIGHT",
        druid = "DRUID",
        hunter = "HUNTER",
        mage = "MAGE",
        paladin = "PALADIN",
        priest = "PRIEST",
        rogue = "ROGUE",
        shaman = "SHAMAN",
        warlock = "WARLOCK",
        warrior = "WARRIOR",
    }

    local classToken = tokenByName[normalized]
    local colors = CUSTOM_CLASS_COLORS or RAID_CLASS_COLORS
    local color = classToken and colors and colors[classToken]
    if not color then
        return "|cffffffff"
    end

    return string.format("|cff%02x%02x%02x", color.r * 255, color.g * 255, color.b * 255)
end

-- "You" rendering. Any name that resolves to the local player is shown as a special-colored
-- "You" instead of the literal character name, so you instantly spot your own line in roll
-- tooltips, the result popup, and Loot Results. Export text deliberately keeps literal names
-- (it is shared with others, for whom "You" is meaningless).
local YOU_COLOR = "|cff00ffcc"   -- aqua: distinct from every class color

function util:IsSelfName(name)
    if not name or name == "" then
        return false
    end
    return self:NormalizeKey(name) == self:NormalizeKey(self:GetPlayerName("player") or "")
end

-- Color-coded display string for a player name: special "You" for the local player, otherwise the
-- name in its class color. className is only used for the non-self color.
function util:ColorPlayerName(name, className)
    if self:IsSelfName(name) then
        return YOU_COLOR .. "You|r"
    end
    return (self:GetClassColorCode(className) or "|cffffffff") .. tostring(name or "Unknown") .. "|r"
end

function util:FindBagItemByLink(itemLink)
    if not itemLink or itemLink == "" then
        return nil
    end

    for bag = 0, 4 do
        local slots = GetContainerNumSlots(bag) or 0
        for slot = 1, slots do
            local link = GetContainerItemLink(bag, slot)
            if link == itemLink then
                return bag, slot
            end
        end
    end

    return nil
end

function util:GetLootSortInfo(itemLink)
    local itemName, _, _, _, _, itemType, itemSubType, _, equipLoc = GetItemInfo(itemLink or "")
    local normalizedType = self:NormalizeKey(itemType or "")
    local normalizedSubType = self:NormalizeKey(itemSubType or "")
    local normalizedEquipLoc = self:NormalizeKey(equipLoc or "")

    if normalizedType == "armor" then
        local armorOrder = {
            cloth = 1,
            leather = 2,
            mail = 3,
            plate = 4,
        }
        local bucket = armorOrder[normalizedSubType]
        if bucket then
            return {
                order = bucket,
                label = normalizedSubType,
                subtype = normalizedSubType,
                itemName = itemName or "",
            }
        end
    end

    if normalizedType == "weapon"
        or string.find(normalizedEquipLoc, "weapon", 1, true)
        or normalizedSubType == "bows"
        or normalizedSubType == "guns"
        or normalizedSubType == "crossbows"
        or normalizedSubType == "thrown"
        or normalizedSubType == "wands"
        or normalizedSubType == "fishing poles"
        or normalizedSubType == "shields"
        or normalizedEquipLoc == "invtype_holdable"
        or normalizedEquipLoc == "invtype_relic" then
        return {
            order = 5,
            label = "weapon",
            subtype = normalizedSubType ~= "" and normalizedSubType or normalizedEquipLoc,
            itemName = itemName or "",
        }
    end

    return {
        order = 6,
        label = normalizedType ~= "" and normalizedType or "other",
        subtype = normalizedSubType,
        itemName = itemName or "",
    }
end
