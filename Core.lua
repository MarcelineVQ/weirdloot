local addonName, addon = ...

WeirdLoot = WeirdLoot or {}
addon = WeirdLoot

addon.name = addonName or "WeirdLoot"
addon.prefix = "WeirdLoot"
addon.version = "0.1.0"
addon.callbacks = {}
addon.events = CreateFrame("Frame")

SLASH_WEIRDLOOT1 = "/weirdloot"
SLASH_WEIRDLOOT2 = "/wl"
SlashCmdList.WEIRDLOOT = function(msg)
    if WeirdLoot and WeirdLoot.HandleSlashCommand then
        WeirdLoot:HandleSlashCommand(msg)
    end
end

local function ensureDefaults(target, defaults)
    if type(target) ~= "table" then
        target = {}
    end

    for key, value in pairs(defaults) do
        if type(value) == "table" then
            target[key] = ensureDefaults(target[key], value)
        elseif target[key] == nil then
            target[key] = value
        end
    end

    return target
end

addon.defaultRosterEntries = {
    { name = "achera", className = "death knight", specName = "frost", status = "designatedalt" },
    { name = "aest", className = "mage", specName = "fire", status = "main" },
    { name = "aldeberron", className = "mage", specName = "arcane", status = "main" },
    { name = "cfg", className = "warlock", specName = "affliction", status = "main" },
    { name = "dehumanizing", className = "warrior", specName = "fury", status = "main" },
    { name = "barnyard", className = "shaman", specName = "restoration", status = "main" },
    { name = "bisket", className = "warlock", specName = "affliction", status = "main" },
    { name = "friendhelper", className = "druid", specName = "balance", status = "main" },
    { name = "nitt", className = "rogue", specName = "combat", status = "main" },
    { name = "notdewbie", className = "rogue", specName = "assassination", status = "main" },
    { name = "valamas", className = "death knight", specName = "unholy", status = "main" },
    { name = "styrza", className = "warrior", specName = "fury", status = "main" },
    { name = "lexissa", className = "warlock", specName = "demonology", status = "main" },
    { name = "zaneran", className = "warrior", specName = "fury", status = "main" },
    { name = "heisthegoat", className = "warrior", specName = "fury", status = "designatedalt" },
    { name = "command", className = "death knight", specName = "frost", status = "designatedalt" },
    { name = "onaqui", className = "death knight", specName = "blood", status = "main" },
    { name = "seme", className = "druid", specName = "restoration", status = "designatedalt" },
    { name = "tumtum", className = "shaman", specName = "enhancement", status = "main" },
    { name = "scozetti", className = "druid", specName = "balance", status = "main" },
    { name = "fellera", className = "priest", specName = "discipline", status = "main" },
    { name = "sweetde", className = "paladin", specName = "retribution", status = "nil" },
    { name = "zannahdee", className = "mage", specName = "arcane", status = "main" },
    { name = "welkin", className = "shaman", specName = "elemental", status = "nil" },
    { name = "nothara", className = "hunter", specName = "survival", status = "main" },
    { name = "owlation", className = "hunter", specName = "survival", status = "main" },
    { name = "dewbie", className = "paladin", specName = "retribution", status = "nil" },
    { name = "uzragol", className = "shaman", specName = "elemental", status = "main" },
    { name = "helvi", className = "priest", specName = "shadow", status = "main" },
    { name = "zenkahi", className = "death knight", specName = "frost", status = "main" },
    { name = "sweezy", className = "death knight", specName = "unholy", status = "main" },
    { name = "runereaver", className = "death knight", specName = "frost", status = "main" },
    { name = "volckerr", className = "warlock", specName = "affliction", status = "main" },
    { name = "volckurr", className = "hunter", specName = "survival", status = "designatedalt" },
    { name = "illithris", className = "paladin", specName = "holy", status = "main" },
    { name = "stickboard", className = "paladin", specName = "holy", status = "main" },
    { name = "sticknight", className = "death knight", specName = "unholy", status = "designatedalt" },
    { name = "mitsuki", className = "paladin", specName = "retribution", status = "main" },
    { name = "yumie", className = "death knight", specName = "frost", status = "designatedalt" },
    { name = "scozette", className = "mage", specName = "arcane", status = "designatedalt" },
    { name = "thalamier", className = "druid", specName = "feral", status = "main" },
    { name = "hellhound", className = "death knight", specName = "frost", status = "designatedalt" },
    { name = "shapiffany", className = "paladin", specName = "holy", status = "main" },
    { name = "gromnash", className = "death knight", specName = "blood", status = "main" },
    { name = "scarletrage", className = "mage", specName = "arcane", status = "main" },
    { name = "lehran", className = "paladin", specName = "protection", status = "main" },
    { name = "dezmar", className = "warlock", specName = "affliction", status = "main" },
    { name = "ivala", className = "shaman", specName = "enhancement", status = "nil" },
    { name = "iseut", className = "paladin", specName = "retribution", status = "main" },
    { name = "allannon", className = "paladin", specName = "protection", status = "main" },
    { name = "sayri", className = "mage", specName = "fire", status = "designatedalt" },
    { name = "halosylvan", className = "priest", specName = "discipline", status = "main" },
    { name = "kleedus", className = "druid", specName = "restoration", status = "main" },
    { name = "verdalax", className = "druid", specName = "balance", status = "nil" },
    { name = "rigul", className = "rogue", specName = "assassination", status = "main" },
    { name = "naioraa", className = "priest", specName = "discipline", status = "main" },
    { name = "plainam", className = "death knight", specName = "frost", status = "nil" },
    { name = "clemency", className = "paladin", specName = "unknown", status = "nil" },
    { name = "coh", className = "rogue", specName = "unknown", status = "main" },
    { name = "douchenasty", className = "rogue", specName = "unknown", status = "main" },
    { name = "electrocuti", className = "shaman", specName = "unknown", status = "nil" },
    { name = "deathbycuti", className = "death knight", specName = "unknown", status = "nil" },
    { name = "magusar", className = "druid", specName = "unknown", status = "main" },
    { name = "scartin", className = "warrior", specName = "fury", status = "main" },
    { name = "sidecar", className = "druid", specName = "unknown", status = "main" },
    { name = "sosqua", className = "mage", specName = "unknown", status = "nil" },
    { name = "araea", className = "death knight", specName = "unknown", status = "nil" },
    { name = "assaris", className = "druid", specName = "unknown", status = "nil" },
    { name = "bospongi", className = "death knight", specName = "frost", status = "nil" },
    { name = "cheezburgah", className = "druid", specName = "unknown", status = "nil" },
    { name = "fischoeder", className = "druid", specName = "restoration", status = "nil" },
    { name = "dragonfang", className = "hunter", specName = "unknown", status = "nil" },
    { name = "dlnero", className = "warlock", specName = "unknown", status = "main" },
    { name = "gungrisa", className = "warlock", specName = "unknown", status = "nil" },
    { name = "keirb", className = "priest", specName = "unknown", status = "nil" },
    { name = "lawgiver", className = "paladin", specName = "protection", status = "nil" },
    { name = "potatosmashr", className = "warrior", specName = "fury", status = "nil" },
    { name = "psychotic", className = "druid", specName = "unknown", status = "nil" },
    { name = "shecute", className = "death knight", specName = "unknown", status = "nil" },
    { name = "tsea", className = "paladin", specName = "retribution", status = "nil" },
    { name = "vsco", className = "priest", specName = "unknown", status = "nil" },
    { name = "ironklad", className = "paladin", specName = "protection", status = "main" },
    { name = "anagke", className = "paladin", specName = "unknown", status = "nil" },
    { name = "burgah", className = "druid", specName = "unknown", status = "nil" },
    { name = "fuuta", className = "warrior", specName = "unknown", status = "nil" },
    { name = "lizal", className = "priest", specName = "discipline", status = "nil" },
    { name = "remos", className = "death knight", specName = "blood", status = "nil" },
    { name = "rigpal", className = "paladin", specName = "unknown", status = "nil" },
    { name = "volcker", className = "warlock", specName = "demonology", status = "main" },
    { name = "volckur", className = "warlock", specName = "demonology", status = "main" },
}

addon.legacySampleRosterImportText = table.concat({
    "volcker, warlock demonology, main",
    "volckur, mage arcane, designatedAlt",
}, "\n")

local defaultRosterImportText = ""

local legacyDefaultLootPriorityText = table.concat({
    "gemmed wand of the nerubians, warlock affliction > warlock demonology > rest",
    "strong-handed ring, warlock demonology > warlock affliction > rest",
}, "\n")

local defaultLootPriorityText = [=[
Shadow of the Ghoul, paladin protection / warrior protection
Haunting Call, shaman elemental
Silent Crusader, death knight frost
Inevitable Defeat, death knight blood
Lost Jewel, warlock affliction / warlock demonology / warlock destruction / druid balance / mage fire > priest shadow
Sand-Worn Band, death knight blood / paladin protection > warrior protection
Fool's Trial, death knight frost / death knight blood / druid balance / druid feral / druid restoration / hunter survival / hunter beast mastery / hunter marksmanship / mage arcane / mage fire / mage frost / paladin holy / paladin retribution / paladin protection / priest discipline / priest holy / priest shadow / shaman elemental / shaman enhancement / shaman restoration / warlock affliction / warlock demonology / warlock destruction / warrior arms / warrior fury / warrior protection > rogue combat / rogue subtlety / rogue assassination / death knight unholy
Heritage, death knight blood
Thunderstorm Amulet, warlock affliction / warlock demonology / warlock destruction
Aged Winter Cloak, druid feral / hunter survival / hunter beast mastery / hunter marksmanship / death knight frost / death knight blood / death knight unholy / warrior fury / warrior arms
Shroud of Luminosity, shaman elemental / shaman restoration / paladin holy

Crown of the Lost Conqueror, warlock affliction / warlock demonology / warlock destruction / paladin protection > priest shadow / priest holy / priest discipline / paladin retribution / paladin holy
Mantle of the Lost Conqueror, paladin protection / paladin retribution / paladin holy / priest discipline / priest holy / priest shadow / warlock affliction / warlock demonology / warlock destruction
Breastplate of the Lost Conqueror, warlock affliction / warlock demonology / warlock destruction / paladin protection / paladin retribution / paladin holy > priest discipline / priest holy / priest shadow
Legplates of the Lost Conqueror, paladin holy > paladin retribution

Crown of the Lost Protector, shaman elemental / shaman restoration / warrior fury / warrior arms > shaman enhancement / hunter survival / hunter beast mastery / hunter marksmanship
Mantle of the Lost Protector, hunter survival / hunter beast mastery / hunter marksmanship / shaman restoration / shaman enhancement / warrior fury / warrior arms > shaman elemental
Breastplate of the Lost Protector, shaman enhancement / shaman restoration / shaman elemental
Legplates of the Lost Protector, shaman restoration / shaman enhancement / warrior fury / warrior arms

Crown of the Lost Vanquisher, rogue combat / rogue assassination / rogue subtlety / death knight blood / mage fire / mage arcane / mage frost / druid balance / druid feral
Mantle of the Lost Vanquisher, rogue combat / rogue assassination / rogue subtlety / death knight frost / death knight blood / death knight unholy / mage fire / mage arcane / mage frost / druid balance / druid restoration / druid feral
Breastplate of the Lost Vanquisher, druid balance / mage fire / mage arcane / mage frost / death knight frost / death knight blood / death knight unholy
Legplates of the Lost Vanquisher, mage arcane / rogue assassination / death knight frost / death knight blood > druid balance / death knight unholy

Mantle of the Locusts, druid restoration
Sash of the Parlor, priest discipline
Leggings of Atrophy, shaman elemental
Dawnwalkers, rogue combat / rogue assassination / rogue subtlety
Arachnoid Gold Band, shaman enhancement
Pauldrons of Unnatural Death, warrior protection
Inexorable Sabatons, paladin protection / warrior protection
Sabatons of Sudden Reprisal, death knight unholy > death knight frost
Webbed Death, rogue combat / rogue assassination / rogue subtlety
Gemmed Wand of the Nerubians, mage fire / priest shadow / warlock affliction > mage arcane > warlock demonology

Punctilious Bindings, priest shadow
Gloves of Token Respect, priest discipline
Seized Beauty, priest discipline > paladin holy

Sinner's Bindings, druid feral / rogue combat / rogue assassination / rogue subtlety / warrior fury / warrior arms
Torn Web Wrapping, hunter survival / hunter beast mastery / hunter marksmanship / shaman enhancement
Bindings of the Hapless Prey, paladin protection / warrior protection
Ablative Chitin Girdle, warrior protection / paladin protection / death knight blood
Matriarch's Spawn, druid restoration / warlock affliction > mage arcane / priest discipline > warlock demonology
Wraith Strike, shaman enhancement > shaman restoration

Sash of Solitude, priest discipline
Belt of the Tortured, rogue assassination > paladin retribution / druid feral / shaman enhancement
Fleshless Girdle, warrior protection
Surplus Limb, priest shadow / warlock demonology / warlock destruction / mage fire / mage arcane / mage frost > warlock affliction
Split Greathammer, warrior protection
Arrowsong, hunter survival / hunter beast mastery / hunter marksmanship

Cowl of Vanity, priest shadow
Mantle of the Corrupted, shaman elemental > druid balance
Slime Stream Bands, shaman enhancement / hunter survival / hunter beast mastery / hunter marksmanship
Depraved Linked Belt, hunter survival / hunter beast mastery / hunter marksmanship
Girdle of Chivalry, paladin retribution / death knight frost / death knight unholy
Plague Igniter, priest discipline

Urn of Lost Memories, priest discipline

Cincture of Polarity, mage fire / druid balance / shaman elemental
Faceguard of the Succumbed, paladin holy
Sabatons of Endurance, paladin protection / warrior protection
Spire of Sunset, priest discipline

Thrusting Bands, paladin retribution > druid feral
Gauntlets of the Disobedient, warrior protection
Accursed Spine, druid balance
Spinning Fate, warrior fury / warrior arms / rogue combat / rogue assassination / rogue subtlety

Heigan's Putrid Vestments, shaman elemental / priest shadow
Serene Echoes, priest discipline
Stalk-Skin Belt, druid feral / rogue combat / rogue assassination / rogue subtlety / warrior fury / warrior arms
Eruption-Scarred Boots, shaman restoration > shaman elemental
Breastplate of Tormented Rage, warrior protection

Boots of Impetuous Ideals, warlock affliction / warlock demonology / warlock destruction / mage fire
Footwraps of Vile Deceit, druid feral
Fading Glow, priest discipline

Bindings of the Expansive Mind, druid balance
Shoulderpads of Secret Arts, hunter survival / hunter beast mastery / hunter marksmanship
Bands of Mutual Respect, shaman restoration / shaman elemental
Girdle of Recuperation, shaman restoration
Bracers of the Unholy Knight, death knight blood > paladin protection / warrior protection
Girdle of Razuvious, death knight frost / death knight unholy
Legplates of Double Strikes, warrior fury / warrior arms

Leggings of Failed Escape, hunter survival / hunter beast mastery / hunter marksmanship
Helm of Vital Protection, warrior protection / paladin protection / death knight blood
Abetment Bracers, paladin holy

Zeliek's Gauntlets, death knight unholy
Broken Promise, paladin protection
Gloves of Grandeur, druid balance
Legguards of the Boneyard, druid restoration
Boots of the Great Construct, shaman enhancement
Cosmic Lights, shaman restoration / priest holy / priest discipline / paladin holy
Icy Blast Amulet, rogue combat / rogue assassination / rogue subtlety
Gatekeeper, warrior protection > death knight blood
Ring of Decaying Beauty, shaman restoration / priest holy / priest discipline / paladin holy / druid restoration
Soul of the Dead, paladin holy
Cape of the Unworthy Wizard, warlock affliction / warlock demonology / warlock destruction / druid balance / priest shadow
Leggings of Mortal Arrogance, priest discipline > warlock affliction / warlock demonology / warlock destruction
Boundless Ambition, death knight blood / warrior protection > paladin protection
Calamity's Grasp, rogue combat > shaman enhancement
Sinister Revenge, rogue assassination
Last Laugh, death knight unholy > warrior protection / paladin protection / death knight blood
Journey's End, druid feral > hunter survival / hunter beast mastery / hunter marksmanship
Wall of Terror, paladin protection / warrior protection
Envoy of Mortality, hunter survival / hunter beast mastery / hunter marksmanship
Gem of Imprisoned Vassals, death knight unholy
Kel'Thuzad's Reach, rogue combat
Hammer of the Astral Plane, priest shadow / paladin holy
Wand of the Archlich, mage arcane / warlock demonology > warlock affliction / mage fire
Wyrmrest Band, shaman restoration / paladin holy
Chestguard of Flagrant Prowess, hunter survival / hunter beast mastery / hunter marksmanship
Greatring of Collision, warrior fury / warrior arms / death knight frost > death knight unholy
Dragon Brood Legguards, paladin protection
Sanctum's Flowing Vestments, mage arcane / priest shadow / druid restoration > priest discipline
Leggings of the Honored, rogue combat / rogue assassination / rogue subtlety / druid feral / paladin retribution
Gown of the Spell-Weaver, druid balance
Footsteps of Malygos, druid balance / shaman elemental > shaman restoration
Surge Needle Ring, hunter survival / hunter beast mastery / hunter marksmanship / druid feral / shaman enhancement / rogue combat / rogue assassination / rogue subtlety > warrior fury / warrior arms / death knight frost
Hailstorm, death knight unholy
Greatstaff of the Nexus, druid balance
Barricade of Eternity, warrior protection
Hood of Rationality, priest shadow / priest holy / priest discipline
Mantle of Dissemination, priest shadow / priest holy / priest discipline
Blanketing Robes of Snow, priest discipline
Leggings of the Wanton Spellcaster, druid balance / mage fire / mage frost / priest shadow / shaman elemental / warlock affliction / warlock demonology / warlock destruction
Arcanic Tramplers, warlock affliction / warlock demonology / warlock destruction / mage fire / mage frost / mage arcane / priest shadow > druid restoration
Blue Aspect Helm, hunter survival / hunter beast mastery / hunter marksmanship / shaman enhancement
Chestguard of the Recluse, druid feral / rogue combat / rogue assassination / rogue subtlety / warrior fury / warrior arms
Winter Spectacle Gloves, shaman restoration
Boots of the Renewed Flight, hunter survival / hunter beast mastery / hunter marksmanship > shaman enhancement
Legplates of Sovereignty, paladin protection / warrior protection
Boots of Healing Energies, paladin holy
Melancholy Sabatons, paladin retribution / death knight frost / warrior fury / warrior arms > death knight unholy
Mark of Norgannon, rogue combat / rogue assassination / rogue subtlety / paladin retribution
]=]

local legacyDefaultNamedItemsText = table.concat({
    "gemmed wand of the nerubians, volcker > volckur > rest",
    "strong-handed ring, volckur > volcker > rest",
}, "\n")

local defaultNamedItemsText = table.concat({
    "Ruthlessness, Zenkahi > Sweezy / Mitsuki > LC",
    "Dying Curse, Lexissa > Zannahdee / Friendhelper / Scarletrage > LC",
    "Grim Toll, Styrza > Nitt / Notdewbie",
    "Strong-Handed Ring, Tumtum / Nitt / Notdewbie / Rigul",
    "The Turning Tide, Volckerr > Zannahdee > Dezmar > LC",
    "Angry Dread, Zenkahi > Runereaver > LC",
    "Heroic Key to the Focusing Iris, Zenkahi / Helvi > LC",
    "Drape of the Deadly Foe, Nitt / Tumtum > Rigul > LC",
    "Signet of Manifested Pain, Aest > Illithris > LC",
    "Betrayer of Humanity, Dehumanizing / Iseut > Styrza / Zaneran > LC",
    "Torch of Holy Fire, Stickboard > Helvi > LC",
    "Voice of Reason, Shapiffany > Illithris > LC",
    "Fury of the Five Flights, Mitsuki / Nothara > Nitt / Valamas / Notdewbie > LC",
    "Illustration of the Dragon Soul, Uzragol / Dezmar > Bisket / Fellera / Volckerr",
    "Pennant Cloak, Cfg > Aest / Zannahdee > Friendhelper > LC",
    "Unsullied Cuffs, Lexissa / Aest > Cfg / Scozetti / Volckerr > LC",
    "Obsidian Greathelm, Sweezy / Valamas > LC",
    "Leash of Heedless Magic, Lexissa / Scarletrage / Kleedus > Dezmar > LC",
    "Frosted Adroit Handguards, Mitsuki > Iseut > LC",
}, "\n")

local function onEvent(self, event, ...)
    if addon[event] then
        addon[event](addon, ...)
    end
end

function addon:RegisterCallback(eventName, handler)
    if type(handler) ~= "function" then
        return
    end

    self.callbacks[eventName] = self.callbacks[eventName] or {}
    table.insert(self.callbacks[eventName], handler)
end

function addon:TriggerCallback(eventName, ...)
    local handlers = self.callbacks[eventName]
    if not handlers then
        return
    end

    for _, handler in ipairs(handlers) do
        handler(...)
    end
end

function addon:Print(message)
    DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffWeirdLoot|r: " .. tostring(message))
end

function addon:GetSessionOwnerKey()
    local playerName = UnitName("player") or "unknown"
    local realmName = GetRealmName and GetRealmName() or "realm"
    local function normalizeKey(value)
        value = string.lower(value or "")
        value = string.match(value, "^%s*(.-)%s*$") or ""
        value = string.gsub(value, "%s+", " ")
        return value
    end

    return string.format("%s-%s", normalizeKey(playerName), normalizeKey(realmName))
end

function addon:RefreshAll()
    self:RefreshRoster()
    self:RefreshLootAuthority()
    self:RefreshSessionItems()
    self:TriggerCallback("STATE_UPDATED")
end

function addon:PLAYER_LOGIN()
    WeirdLootDB = ensureDefaults(WeirdLootDB, {
        testMode = false,        -- in-city testing: treat ANY bag item as session loot
        autoRoll = true,         -- newly-looted/traded-in items auto-start a live roll
        config = {
            rosterImportText = defaultRosterImportText,
            rosterEntries = addon.defaultRosterEntries,
            lootPriorityText = defaultLootPriorityText,
            namedItemsText = defaultNamedItemsText,
            roster = {},
            lootRules = {},
            namedRules = {},
            revision = 0,
        },
        ui = {
            selectedTab = "loot",
            lootSortMode = "name",
            lootUsabilitySort = false,
            liveRollPopups = {
                point = "TOP",
                relativePoint = "TOP",
                x = 260,
                y = -170,
            },
            frame = {
                x = 0,
                y = 0,
            },
        },
    })

    WeirdLootSessionDB = ensureDefaults(WeirdLootSessionDB, {
        activeSession = nil,
        activeSessions = {},
        history = {},
    })

    if WeirdLootDB and WeirdLootDB.config then
        local lootPriorityText = WeirdLootDB.config.lootPriorityText or ""
        if lootPriorityText == "" or lootPriorityText == legacyDefaultLootPriorityText then
            WeirdLootDB.config.lootPriorityText = defaultLootPriorityText
        end

        local namedItemsText = WeirdLootDB.config.namedItemsText or ""
        if namedItemsText == "" or namedItemsText == legacyDefaultNamedItemsText then
            WeirdLootDB.config.namedItemsText = defaultNamedItemsText
        end

        if type(WeirdLootDB.config.rosterEntries) == "table" then
            for _, entry in ipairs(WeirdLootDB.config.rosterEntries) do
                if string.lower(string.trim(entry.name or "")) == "volcker"
                    and string.lower(string.trim(entry.className or "")) == "warlock"
                    and string.lower(string.trim(entry.specName or "")) == "affliction" then
                    entry.specName = "demonology"
                end
            end
        end

        if type(WeirdLootDB.config.rosterImportText) == "string" and WeirdLootDB.config.rosterImportText ~= "" then
            WeirdLootDB.config.rosterImportText = string.gsub(
                WeirdLootDB.config.rosterImportText,
                "([Vv][Oo][Ll][Cc][Kk][Ee][Rr]%s*,%s*[Ww][Aa][Rr][Ll][Oo][Cc][Kk]%s+)[Aa][Ff][Ff][Ll][Ii][Cc][Tt][Ii][Oo][Nn]",
                "%1demonology"
            )
        end
    end

    self.db = WeirdLootDB
    self.sessionDb = WeirdLootSessionDB
    self.bagSettleAt = GetTime() + 5   -- ignore bag deltas (staged loading) until bags settle this login

    if self.sessionDb.activeSession ~= nil then
        local legacySession = self.sessionDb.activeSession
        local legacyOwnerKey = legacySession and legacySession.ownerKey
        self.sessionDb.activeSessions = self.sessionDb.activeSessions or {}
        if legacyOwnerKey and legacyOwnerKey ~= "" and self.sessionDb.activeSessions[legacyOwnerKey] == nil then
            self.sessionDb.activeSessions[legacyOwnerKey] = legacySession
        end
        self.sessionDb.activeSession = nil
    end

    local guidSeed = tonumber(string.match(UnitGUID("player") or "0", "(%d+)$")) or 0
    if type(randomseed) == "function" then
        randomseed(time() + guidSeed)
    elseif math and type(math.randomseed) == "function" then
        math.randomseed(time() + guidSeed)
    end

    self:InitializeConfig()
    self:InitializeRoster()
    self:InitializeSession()
    self:InitializeComm()
    self:InitializeResolver()
    self:InitializePayout()
    self:InitializeLiveRoll()
    self:InitializeUI()

    self.events:RegisterEvent("RAID_ROSTER_UPDATE")
    self.events:RegisterEvent("PARTY_MEMBERS_CHANGED")
    self.events:RegisterEvent("PARTY_LOOT_METHOD_CHANGED")
    self.events:RegisterEvent("PLAYER_ENTERING_WORLD")
    self.events:RegisterEvent("BAG_UPDATE")
    self.events:RegisterEvent("PLAYER_REGEN_ENABLED")
    self.events:RegisterEvent("LOOT_OPENED")
    self.events:RegisterEvent("LOOT_BIND_CONFIRM")

    self:RefreshAll()
    self:ResumePayoutMode()      -- a session restored from SavedVariables keeps payout mode on
    self:Print("Loaded. Use /weirdloot to open the window.")
end

-- Zone-in prompt (RCLootCouncil model): on entering a raid instance as the loot
-- master with no session running, offer to start one. Declining is remembered until
-- we leave the raid, so it isn't re-asked on every loading screen inside the instance.
StaticPopupDialogs["WEIRDLOOT_START_SESSION"] = {
    text = "Start a WeirdLoot session for this raid?",
    button1 = YES,
    button2 = NO,
    OnAccept = function() addon:StartLootSession() end,
    OnCancel = function() addon.raidPrompt.declined = true end,
    timeout = 0,
    whileDead = 1,
    hideOnEscape = 1,
    showAlert = 1,
}

function addon:MaybePromptStartSession()
    self.raidPrompt = self.raidPrompt or { declined = false }
    local _, instanceType = IsInInstance()
    if instanceType ~= "raid" then
        self.raidPrompt.declined = false       -- reset once we've left the raid
        return
    end
    if self.session.active then return end
    if not self:IsAuthorizedLootMaster() then return end
    if self.raidPrompt.declined then return end
    StaticPopup_Show("WEIRDLOOT_START_SESSION")
end

-- Delayed loot-master re-check (RCLootCouncil's NewMLCheck pattern). At login the client
-- hasn't received the loot method / raid roster yet, so a single check can miss ML status,
-- and PARTY_LOOT_METHOD_CHANGED won't re-fire if nothing actually changed. 3.3.5 has no
-- C_Timer, so we drive a few re-checks off an OnUpdate frame over the first few seconds.
local AUTH_RETRY_TIMES = { 0.5, 1.0, 1.5, 3.0, 6.0, 9.0, 12.0, 15.0 }   -- re-check: fast early, then every 3s, over the first ~15s
local authRetry = CreateFrame("Frame")
authRetry:Hide()
authRetry:SetScript("OnUpdate", function(frame, dt)
    frame.elapsed = (frame.elapsed or 0) + dt
    local target = AUTH_RETRY_TIMES[frame.index or 1]
    if not target then frame:Hide(); return end
    if frame.elapsed >= target then
        frame.index = (frame.index or 1) + 1
        addon:RecheckLootAuthority()
    end
end)

function addon:ScheduleAuthorityRecheck()
    authRetry.elapsed = 0
    authRetry.index = 1
    authRetry:Show()
end

-- Re-evaluate authority; if we only NOW resolve as ML (data finally arrived), run the
-- ML-on-login work the early PLAYER_ENTERING_WORLD check skipped.
function addon:RecheckLootAuthority()
    local was = self.roster.isLootMaster
    self:RefreshLootAuthority()
    if self.roster.isLootMaster and not was then
        self:AutoBroadcastSession(true)
        self:ResumePayoutMode()
        self:RestorePendingPopups()
        self:MaybePromptStartSession()
    end
end

function addon:PLAYER_ENTERING_WORLD()
    self:RefreshAll()
    if self:IsAuthorizedLootMaster() then
        self:AutoBroadcastSession(true)
        self:RestorePendingPopups()     -- re-show pending items the ML hadn't decided on
    else
        self:RequestSessionSync()
    end
    self:MaybePromptStartSession()
    self:ScheduleAuthorityRecheck()     -- catch ML status that lands after the data settles
end

function addon:RAID_ROSTER_UPDATE()
    self:RefreshRoster()
    self:RefreshLootAuthority()
    self:TriggerCallback("ROSTER_UPDATED")
end

function addon:PARTY_MEMBERS_CHANGED()
    self:RefreshRoster()
    self:RefreshLootAuthority()
    self:TriggerCallback("ROSTER_UPDATED")
end

function addon:PARTY_LOOT_METHOD_CHANGED()
    self:RefreshLootAuthority()
    self:TriggerCallback("AUTHORITY_UPDATED")
    self:MaybePromptStartSession()      -- becoming ML in a raid offers a session too
end

function addon:BAG_UPDATE()
    if self:OnBagUpdate() then
        self:AutoBroadcastSession(false)
    end
end

function addon:PLAYER_REGEN_ENABLED()
    self:TriggerCallback("STATE_UPDATED")
end

function addon:HandleSlashCommand(msg)
    local command = string.lower(string.trim(msg or ""))
    if command == "start" then
        self:StartLootSession()
    elseif command == "end" or command == "stop" or command == "clear" then
        self:ClearSession()
        self:Print("Loot session ended.")
    elseif command == "scan" then
        self:RefreshSessionItems(true)
    elseif command == "payout" then
        self:StartPayout()
    elseif command == "payout stop" or command == "payout off" then
        self:StopPayout()
    elseif command == "payout clear" then
        if self.payout then
            self.payout:StopPayout()
            self.payout:ClearOwed()
            self:Print("Payout ledger cleared.")
            if self.ui and self.ui.masterPanel then self:RefreshMasterTab() end
        end
    elseif command == "test" then
        self.db.testMode = not self.db.testMode
        self:Print("Test mode " .. (self.db.testMode
            and "ON - every item in your bags counts as session loot (city testing)."
            or "OFF - only tradable epics count."))
        self:RefreshSessionItems(true)
    elseif command == "autoroll" then
        self.db.autoRoll = not self.db.autoRoll
        self:Print("Auto-roll on new loot " .. (self.db.autoRoll and "ON." or "OFF (right-click an item to roll manually)."))
    elseif command == "deer" or string.sub(command, 1, 5) == "deer " then
        local name = string.match(string.trim(msg or ""), "^%S+%s+(.+)$")
        if name and string.trim(name) ~= "" then
            self.db.deer = string.trim(name)
            self:Print("Disenchanter set to " .. self.db.deer .. " (non-epic BoE auto-routes there).")
        else
            self.db.deer = nil
            self:Print("Disenchanter cleared.")
        end
    else
        self:ToggleMainFrame()
    end
end

addon.events:SetScript("OnEvent", onEvent)
addon.events:RegisterEvent("PLAYER_LOGIN")
