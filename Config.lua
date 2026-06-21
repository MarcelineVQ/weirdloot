local addon = WeirdLoot
local util = addon.util

local configClassAliases = {
    ["death knight"] = "death knight",
    deathknight = "death knight",
    dk = "death knight",
    druid = "druid",
    hunter = "hunter",
    mage = "mage",
    paladin = "paladin",
    priest = "priest",
    rogue = "rogue",
    shaman = "shaman",
    warlock = "warlock",
    warrior = "warrior",
}

local orderedClassNames = {
    "death knight",
    "paladin",
    "priest",
    "warlock",
    "warrior",
    "hunter",
    "shaman",
    "druid",
    "rogue",
    "mage",
}

addon.defaultItemInfo = {
    ["omen of ruin"] = { itemName = "Omen of Ruin", note = "", role = "Physical" },
    ["the stray"] = { itemName = "The Stray", note = "", role = "Physical" },
    ["contortion"] = { itemName = "Contortion", note = "", role = "Healer" },
    ["medallion of the disgraced"] = { itemName = "Medallion of the Disgraced", note = "", role = "Tank" },
    ["chain of latent energies"] = { itemName = "Chain of Latent Energies", note = "", role = "Spellpower" },
    ["minion bracers"] = { itemName = "Minion Bracers", note = "", role = "Tank" },
    ["knife of incision"] = { itemName = "Knife of Incision", note = "", role = "Physical" },
    ["collar of dissolution"] = { itemName = "Collar of Dissolution", note = "", role = "Physical" },
    ["deflection band"] = { itemName = "Deflection Band", note = "", role = "Tank" },
    ["band of neglected pleas"] = { itemName = "Band of Neglected Pleas", note = "", role = "Healer" },
    ["agonal sash"] = { itemName = "Agonal Sash", note = "", role = "Spellpower" },
    ["gloves of dark gestures"] = { itemName = "Gloves of Dark Gestures", note = "", role = "Spellpower" },
    ["splint-bound leggings"] = { itemName = "Splint-Bound Leggings", note = "", role = "Spellpower" },
    ["boots of persistence"] = { itemName = "Boots of Persistence", note = "", role = "Healer" },
    ["chivalric chestguard"] = { itemName = "Chivalric Chestguard", note = "", role = "Healer" },
    ["ravaging sabatons"] = { itemName = "Ravaging Sabatons", note = "", role = "Physical" },
    ["watchful eye"] = { itemName = "Watchful Eye", note = "", role = "Spellpower" },
    ["grieving spellblade"] = { itemName = "Grieving Spellblade", note = "", role = "Spellpower" },
    ["sash of mortal desire"] = { itemName = "Sash of Mortal Desire", note = "", role = "Spellpower" },
    ["boots of the worshiper"] = { itemName = "Boots of the Worshiper", note = "", role = "Physical" },
    ["boots of the follower"] = { itemName = "Boots of the Follower", note = "", role = "Spellpower" },
    ["rusted-link spiked gauntlets"] = { itemName = "Rusted-Link Spiked Gauntlets", note = "", role = "Physical" },
    ["avenging combat leggings"] = { itemName = "Avenging Combat Leggings", note = "", role = "Spellpower" },
    ["gauntlets of the master"] = { itemName = "Gauntlets of the Master", note = "", role = "Tank" },
    ["frostblight pauldrons"] = { itemName = "Frostblight Pauldrons", note = "", role = "Spellpower" },
    ["bracers of lost sentiments"] = { itemName = "Bracers of Lost Sentiments", note = "", role = "Physical" },
    ["maexxna's femur"] = { itemName = "Maexxna's Femur", note = "", role = "Physical" },
    ["wraith spear"] = { itemName = "Wraith Spear", note = "", role = "Physical" },
    ["aegis of damnation"] = { itemName = "Aegis of Damnation", note = "", role = "Spellpower" },
    ["embrace of the spider"] = { itemName = "Embrace of the Spider", note = "", role = "Spellpower" },
    ["cloak of armed strife"] = { itemName = "Cloak of Armed Strife", note = "", role = "Tank" },
    ["timeworn silken band"] = { itemName = "Timeworn Silken Band", note = "", role = "Spellpower" },
    ["pendant of lost vocations"] = { itemName = "Pendant of Lost Vocations", note = "", role = "Spellpower" },
    ["leggings of discord"] = { itemName = "Leggings of Discord", note = "", role = "Physical" },
    ["spaulders of the monstrosity"] = { itemName = "Spaulders of the Monstrosity", note = "", role = "Spellpower" },
    ["web cocoon grips"] = { itemName = "Web Cocoon Grips", note = "", role = "Spellpower" },
    ["dark shroud of the scourge"] = { itemName = "Dark Shroud of the Scourge", note = "", role = "Spellpower" },
    ["ring of the fated"] = { itemName = "Ring of the Fated", note = "", role = "Spellpower" },
    ["robes of hoarse breaths"] = { itemName = "Robes of Hoarse Breaths", note = "", role = "Spellpower" },
    ["noth's curse"] = { itemName = "Noth's Curse", note = "", role = "Spellpower" },
    ["spaulders of resumed battle"] = { itemName = "Spaulders of Resumed Battle", note = "", role = "Physical" },
    ["trespasser's boots"] = { itemName = "Trespasser's Boots", note = "", role = "Physical" },
    ["handgrips of the foredoomed"] = { itemName = "Handgrips of the Foredoomed", note = "", role = "Spellpower" },
    ["chestplate of the risen soldier"] = { itemName = "Chestplate of the Risen Soldier", note = "", role = "Physical" },
    ["plague-impervious boots"] = { itemName = "Plague-Impervious Boots", note = "", role = "Tank" },
    ["bone-framed bracers"] = { itemName = "Bone-Framed Bracers", note = "", role = "Spellpower" },
    ["demise"] = { itemName = "Demise", note = "", role = "Physical" },
    ["staff of the plague beast"] = { itemName = "Staff of the Plague Beast", note = "", role = "Physical" },
    ["ring of holy cleansing"] = { itemName = "Ring of Holy Cleansing", note = "", role = "Spellpower" },
    ["amulet of autopsy"] = { itemName = "Amulet of Autopsy", note = "", role = "Tank" },
    ["saltarello shoes"] = { itemName = "Saltarello Shoes", note = "", role = "Spellpower" },
    ["preceptor's bindings"] = { itemName = "Preceptor's Bindings", note = "", role = "Spellpower" },
    ["cuffs of dark shadows"] = { itemName = "Cuffs of Dark Shadows", note = "", role = "Physical" },
    ["tunic of the lost pack"] = { itemName = "Tunic of the Lost Pack", note = "", role = "Physical" },
    ["necrogenic belt"] = { itemName = "Necrogenic Belt", note = "", role = "Spellpower" },
    ["shoulderplates of bloodshed"] = { itemName = "Shoulderplates of Bloodshed", note = "", role = "Physical" },
    ["spaulders of the lost conqueror"] = { itemName = "Spaulders of the Lost Conqueror", note = "Paladin, Priest, Warlock", role = "ALL" },
    ["spaulders of the lost protector"] = { itemName = "Spaulders of the Lost Protector", note = "Warrior, Hunter, Shaman", role = "ALL" },
    ["spaulders of the lost vanquisher"] = { itemName = "Spaulders of the Lost Vanquisher", note = "Rogue, Death Knight, Mage, Druid", role = "ALL" },
    ["sulfur stave"] = { itemName = "Sulfur Stave", note = "", role = "Spellpower" },
    ["loatheb's shadow"] = { itemName = "Loatheb's Shadow", note = "", role = "Physical" },
    ["fungi-stained coverings"] = { itemName = "Fungi-Stained Coverings", note = "", role = "Spellpower" },
    ["helm of the corrupted mind"] = { itemName = "Helm of the Corrupted Mind", note = "", role = "Spellpower" },
    ["legplates of inescapable death"] = { itemName = "Legplates of Inescapable Death", note = "", role = "Tank" },
    ["accursed bow of the elite"] = { itemName = "Accursed Bow of the Elite", note = "", role = "Physical" },
    ["scepter of murmuring spirits"] = { itemName = "Scepter of Murmuring Spirits", note = "", role = "Spellpower" },
    ["cloak of darkening"] = { itemName = "Cloak of Darkening", note = "", role = "Physical" },
    ["leggings of the instructor"] = { itemName = "Leggings of the Instructor", note = "", role = "Spellpower" },
    ["mantle of the extensive mind"] = { itemName = "Mantle of the Extensive Mind", note = "", role = "Spellpower" },
    ["rapid attack gloves"] = { itemName = "Rapid Attack Gloves", note = "", role = "Physical" },
    ["girdle of lenience"] = { itemName = "Girdle of Lenience", note = "", role = "Spellpower" },
    ["iron rings of endurance"] = { itemName = "Iron Rings of Endurance", note = "", role = "Spellpower" },
    ["waistguard of the tutor"] = { itemName = "Waistguard of the Tutor", note = "", role = "Tank" },
    ["plated gloves of relief"] = { itemName = "Plated Gloves of Relief", note = "", role = "Spellpower" },
    ["slayer of the lifeless"] = { itemName = "Slayer of the Lifeless", note = "", role = "Tank" },
    ["spirit-world glass"] = { itemName = "Spirit-World Glass", note = "", role = "Spellpower" },
    ["signet of the malevolent"] = { itemName = "Signet of the Malevolent", note = "", role = "Spellpower" },
    ["veiled amulet of life"] = { itemName = "Veiled Amulet of Life", note = "", role = "Spellpower" },
    ["resurgent phantom bindings"] = { itemName = "Resurgent Phantom Bindings", note = "", role = "Spellpower" },
    ["tunic of dislocation"] = { itemName = "Tunic of Dislocation", note = "", role = "Physical" },
    ["heinous mail chestguard"] = { itemName = "Heinous Mail Chestguard", note = "", role = "Spellpower" },
    ["spectral rider's girdle"] = { itemName = "Spectral Rider's Girdle", note = "", role = "Physical" },
    ["sabatons of deathlike gloom"] = { itemName = "Sabatons of Deathlike Gloom", note = "", role = "Spellpower" },
    ["girdle of the ascended phantom"] = { itemName = "Girdle of the Ascended Phantom", note = "", role = "Physical" },
    ["chestguard of the lost conqueror"] = { itemName = "Chestguard of the Lost Conqueror", note = "Paladin, Priest, Warlock", role = "ALL" },
    ["chestguard of the lost protector"] = { itemName = "Chestguard of the Lost Protector", note = "Warrior, Hunter, Shaman", role = "ALL" },
    ["chestguard of the lost vanquisher"] = { itemName = "Chestguard of the Lost Vanquisher", note = "Rogue, Death Knight, Mage, Druid", role = "ALL" },
    ["claymore of ancient power"] = { itemName = "Claymore of Ancient Power", note = "", role = "Physical" },
    ["charmed cierge"] = { itemName = "Charmed Cierge", note = "", role = "Spellpower" },
    ["gown of blaumeux"] = { itemName = "Gown of Blaumeux", note = "", role = "Spellpower" },
    ["pauldrons of havoc"] = { itemName = "Pauldrons of Havoc", note = "", role = "Physical" },
    ["thane's tainted greathelm"] = { itemName = "Thane's Tainted Greathelm", note = "", role = "Tank" },
    ["blade of dormant memories"] = { itemName = "Blade of Dormant Memories", note = "", role = "Spellpower" },
    ["hatestrike"] = { itemName = "Hatestrike", note = "", role = "Physical" },
    ["drape of surgery"] = { itemName = "Drape of Surgery", note = "", role = "Spellpower" },
    ["sullen cloth boots"] = { itemName = "Sullen Cloth Boots", note = "", role = "Spellpower" },
    ["contagion gloves"] = { itemName = "Contagion Gloves", note = "", role = "Spellpower" },
    ["retcher's shoulderpads"] = { itemName = "Retcher's Shoulderpads", note = "", role = "Spellpower" },
    ["gauntlets of combined strength"] = { itemName = "Gauntlets of Combined Strength", note = "", role = "Physical" },
    ["abomination shoulderblades"] = { itemName = "Abomination Shoulderblades", note = "", role = "Tank" },
    ["tainted girdle of mending"] = { itemName = "Tainted Girdle of Mending", note = "", role = "Spellpower" },
    ["the skull of ruin"] = { itemName = "The Skull of Ruin", note = "", role = "Tank" },
    ["infection repulser"] = { itemName = "Infection Repulser", note = "", role = "Spellpower" },
    ["sealing ring of grobbulus"] = { itemName = "Sealing Ring of Grobbulus", note = "", role = "Physical" },
    ["bone-linked amulet"] = { itemName = "Bone-Linked Amulet", note = "", role = "Spellpower" },
    ["handgrips of turmoil"] = { itemName = "Handgrips of Turmoil", note = "", role = "Spellpower" },
    ["miasma mantle"] = { itemName = "Miasma Mantle", note = "", role = "Spellpower" },
    ["blistered belt of decay"] = { itemName = "Blistered Belt of Decay", note = "", role = "Physical" },
    ["putrescent bands"] = { itemName = "Putrescent Bands", note = "", role = "Spellpower" },
    ["bands of anxiety"] = { itemName = "Bands of Anxiety", note = "", role = "Physical" },
    ["leggings of innumerable barbs"] = { itemName = "Leggings of Innumerable Barbs", note = "", role = "Physical" },
    ["leggings of the lost conqueror"] = { itemName = "Leggings of the Lost Conqueror", note = "Paladin, Priest, Warlock", role = "ALL" },
    ["leggings of the lost protector"] = { itemName = "Leggings of the Lost Protector", note = "Warrior, Hunter, Shaman", role = "ALL" },
    ["leggings of the lost vanquisher"] = { itemName = "Leggings of the Lost Vanquisher", note = "Rogue, Death Knight, Mage, Druid", role = "ALL" },
    ["torment of the banished"] = { itemName = "Torment of the Banished", note = "", role = "Physical" },
    ["repelling charge"] = { itemName = "Repelling Charge", note = "", role = "Tank" },
    ["cowl of sheet lightning"] = { itemName = "Cowl of Sheet Lightning", note = "", role = "Spellpower" },
    ["arc-scorched helmet"] = { itemName = "Arc-Scorched Helmet", note = "", role = "Physical" },
    ["blackened legplates of feugen"] = { itemName = "Blackened Legplates of Feugen", note = "", role = "Spellpower" },
    ["key to the focusing iris"] = { itemName = "Key to the Focusing Iris", note = "LC", role = "ALL" },
    ["cloak of mastery"] = { itemName = "Cloak of Mastery", note = "", role = "Physical" },
    ["shroud of the citadel"] = { itemName = "Shroud of the Citadel", note = "", role = "Spellpower" },
    ["circle of death"] = { itemName = "Circle of Death", note = "", role = "Physical" },
    ["circle of life"] = { itemName = "Circle of Life", note = "", role = "Spellpower" },
    ["cowl of winged fear"] = { itemName = "Cowl of Winged Fear", note = "", role = "Spellpower" },
    ["leggings of sapphiron"] = { itemName = "Leggings of Sapphiron", note = "", role = "Spellpower" },
    ["helm of the vast legions"] = { itemName = "Helm of the Vast Legions", note = "", role = "Physical" },
    ["helmet of the inner sanctum"] = { itemName = "Helmet of the Inner Sanctum", note = "", role = "Spellpower" },
    ["massive skeletal ribcage"] = { itemName = "Massive Skeletal Ribcage", note = "", role = "Tank" },
    ["helm of the unsubmissive"] = { itemName = "Helm of the Unsubmissive", note = "", role = "Physical" },
    ["helm of the lost conqueror"] = { itemName = "Helm of the Lost Conqueror", note = "Paladin, Priest, Warlock", role = "ALL" },
    ["helm of the lost protector"] = { itemName = "Helm of the Lost Protector", note = "Warrior, Hunter, Shaman", role = "ALL" },
    ["helm of the lost vanquisher"] = { itemName = "Helm of the Lost Vanquisher", note = "Rogue, Death Knight, Mage, Druid", role = "ALL" },
    ["kel'thuzad's reach"] = { itemName = "Kel'Thuzad's Reach", note = "", role = "Physical" },
    ["death's bite"] = { itemName = "Death's Bite", note = "", role = "Physical" },
    ["nerubian conquerer"] = { itemName = "Nerubian Conquerer", note = "", role = "Physical" },
    ["anarchy"] = { itemName = "Anarchy", note = "", role = "Physical" },
    ["staff of the plaguehound"] = { itemName = "Staff of the Plaguehound", note = "", role = "Physical" },
    ["hammer of the astral plane"] = { itemName = "Hammer of the Astral Plane", note = "", role = "Spellpower" },
    ["the soulblade"] = { itemName = "The Soulblade", note = "", role = "Spellpower" },
    ["wand of the archlich"] = { itemName = "Wand of the Archlich", note = "", role = "Spellpower" },
    ["cloak of the dying"] = { itemName = "Cloak of the Dying", note = "", role = "Spellpower" },
    ["gem of imprisoned vassals"] = { itemName = "Gem of Imprisoned Vassals", note = "", role = "Physical" },
    ["inevitable defeat"] = { itemName = "Inevitable Defeat", note = "", role = "Physical" },
    ["silent crusader"] = { itemName = "Silent Crusader", note = "", role = "Physical" },
    ["haunting call"] = { itemName = "Haunting Call", note = "", role = "Spellpower" },
    ["shadow of the ghoul"] = { itemName = "Shadow of the Ghoul", note = "", role = "Tank" },
    ["ousted bead necklace"] = { itemName = "Ousted Bead Necklace", note = "", role = "Spellpower" },
    ["boots of the escaped captive"] = { itemName = "Boots of the Escaped Captive", note = "", role = "Spellpower" },
    ["shoulderguards of the undaunted"] = { itemName = "Shoulderguards of the Undaunted", note = "", role = "Physical" },
    ["strong-handed ring"] = { itemName = "Strong-Handed Ring", note = "", role = "Physical" },
    ["ruthlessness"] = { itemName = "Ruthlessness", note = "", role = "Physical" },
    ["lost jewel"] = { itemName = "Lost Jewel", note = "", role = "Spellpower" },
    ["sand-worn band"] = { itemName = "Sand-Worn Band", note = "", role = "Tank" },
    ["seized beauty"] = { itemName = "Seized Beauty", note = "", role = "Spellpower" },
    ["thunderstorm amulet"] = { itemName = "Thunderstorm Amulet", note = "", role = "Spellpower" },
    ["fool's trial"] = { itemName = "Fool's Trial", note = "", role = "Physical" },
    ["heritage"] = { itemName = "Heritage", note = "", role = "Tank" },
    ["chains of adoration"] = { itemName = "Chains of Adoration", note = "", role = "Spellpower" },
    ["gemmed wand of the nerubians"] = { itemName = "Gemmed Wand of the Nerubians", note = "", role = "Spellpower" },
    ["webbed death"] = { itemName = "Webbed Death", note = "", role = "Physical" },
    ["shield of assimilation"] = { itemName = "Shield of Assimilation", note = "", role = "Spellpower" },
    ["leggings of atrophy"] = { itemName = "Leggings of Atrophy", note = "", role = "Spellpower" },
    ["mantle of the locusts"] = { itemName = "Mantle of the Locusts", note = "", role = "Spellpower" },
    ["sash of the parlor"] = { itemName = "Sash of the Parlor", note = "", role = "Spellpower" },
    ["dawnwalkers"] = { itemName = "Dawnwalkers", note = "", role = "Physical" },
    ["swarm bindings"] = { itemName = "Swarm Bindings", note = "", role = "Spellpower" },
    ["corpse scarab handguards"] = { itemName = "Corpse Scarab Handguards", note = "", role = "Spellpower" },
    ["arachnoid gold band"] = { itemName = "Arachnoid Gold Band", note = "", role = "Physical" },
    ["sabatons of sudden reprisal"] = { itemName = "Sabatons of Sudden Reprisal", note = "", role = "Physical" },
    ["inexorable sabatons"] = { itemName = "Inexorable Sabatons", note = "", role = "Tank" },
    ["rescinding grips"] = { itemName = "Rescinding Grips", note = "", role = "Spellpower" },
    ["pauldrons of unnatural death"] = { itemName = "Pauldrons of Unnatural Death", note = "", role = "Tank" },
    ["widow's fury"] = { itemName = "Widow's Fury", note = "", role = "Physical" },
    ["totem of misery"] = { itemName = "Totem of Misery", note = "", role = "SHAMAN" },
    ["idol of worship"] = { itemName = "Idol of Worship", note = "", role = "DRUID" },
    ["gloves of token respect"] = { itemName = "Gloves of Token Respect", note = "", role = "Spellpower" },
    ["faerlina's madness"] = { itemName = "Faerlina's Madness", note = "", role = "Spellpower" },
    ["belt of false dignity"] = { itemName = "Belt of False Dignity", note = "", role = "Spellpower" },
    ["punctilious bindings"] = { itemName = "Punctilious Bindings", note = "", role = "Spellpower" },
    ["tunic of prejudice"] = { itemName = "Tunic of Prejudice", note = "", role = "Spellpower" },
    ["dislocating handguards"] = { itemName = "Dislocating Handguards", note = "", role = "Physical" },
    ["atonement greaves"] = { itemName = "Atonement Greaves", note = "", role = "Spellpower" },
    ["cult's chestguard"] = { itemName = "Cult's Chestguard", note = "", role = "Physical" },
    ["bracers of the tyrant"] = { itemName = "Bracers of the Tyrant", note = "", role = "Physical" },
    ["fire-scorched greathelm"] = { itemName = "Fire-Scorched Greathelm", note = "", role = "Physical" },
    ["callous-hearted gauntlets"] = { itemName = "Callous-Hearted Gauntlets", note = "", role = "Tank" },
    ["epaulets of the grieving servant"] = { itemName = "Epaulets of the Grieving Servant", note = "", role = "Spellpower" },
    ["wraith strike"] = { itemName = "Wraith Strike", note = "", role = "Spellpower" },
    ["the jawbone"] = { itemName = "The Jawbone", note = "", role = "Physical" },
    ["matriarch's spawn"] = { itemName = "Matriarch's Spawn", note = "", role = "Spellpower" },
    ["dying curse"] = { itemName = "Dying Curse", note = "LC", role = "Spellpower" },
    ["grim toll"] = { itemName = "Grim Toll", note = "LC", role = "Physical" },
    ["defender's code"] = { itemName = "Defender's Code", note = "", role = "Tank" },
    ["forethought talisman"] = { itemName = "Forethought Talisman", note = "", role = "Spellpower" },
    ["aged winter cloak"] = { itemName = "Aged Winter Cloak", note = "", role = "Physical" },
    ["shroud of luminosity"] = { itemName = "Shroud of Luminosity", note = "", role = "Spellpower" },
    ["cloak of the shadowed sun"] = { itemName = "Cloak of the Shadowed Sun", note = "", role = "Tank" },
    ["shawl of the old maid"] = { itemName = "Shawl of the Old Maid", note = "", role = "Spellpower" },
    ["cloak of averted crisis"] = { itemName = "Cloak of Averted Crisis", note = "", role = "Spellpower" },
    ["digested silken robes"] = { itemName = "Digested Silken Robes", note = "", role = "Spellpower" },
    ["distorted limbs"] = { itemName = "Distorted Limbs", note = "", role = "Spellpower" },
    ["cowl of the perished"] = { itemName = "Cowl of the Perished", note = "", role = "Spellpower" },
    ["infectious skitterer leggings"] = { itemName = "Infectious Skitterer Leggings", note = "", role = "Physical" },
    ["mantle of shattered kinship"] = { itemName = "Mantle of Shattered Kinship", note = "", role = "Spellpower" },
    ["sinner's bindings"] = { itemName = "Sinner's Bindings", note = "", role = "Physical" },
    ["quivering tunic"] = { itemName = "Quivering Tunic", note = "", role = "Spellpower" },
    ["torn web wrapping"] = { itemName = "Torn Web Wrapping", note = "", role = "Physical" },
    ["undiminished battleplate"] = { itemName = "Undiminished Battleplate", note = "", role = "Physical" },
    ["helm of diminished pride"] = { itemName = "Helm of Diminished Pride", note = "", role = "Spellpower" },
    ["ablative chitin girdle"] = { itemName = "Ablative Chitin Girdle", note = "", role = "Tank" },
    ["bindings of the hapless prey"] = { itemName = "Bindings of the Hapless Prey", note = "", role = "Tank" },
    ["angry dread"] = { itemName = "Angry Dread", note = "LC", role = "Physical" },
    ["spinning fate"] = { itemName = "Spinning Fate", note = "", role = "Physical" },
    ["accursed spine"] = { itemName = "Accursed Spine", note = "", role = "Spellpower" },
    ["libram of radiance"] = { itemName = "Libram of Radiance", note = "", role = "PALADIN" },
    ["robes of mutation"] = { itemName = "Robes of Mutation", note = "", role = "Spellpower" },
    ["gloves of the fallen wizard"] = { itemName = "Gloves of the Fallen Wizard", note = "", role = "Spellpower" },
    ["bands of impurity"] = { itemName = "Bands of Impurity", note = "", role = "Spellpower" },
    ["belt of potent chanting"] = { itemName = "Belt of Potent Chanting", note = "", role = "Spellpower" },
    ["thrusting bands"] = { itemName = "Thrusting Bands", note = "", role = "Physical" },
    ["tunic of masked suffering"] = { itemName = "Tunic of Masked Suffering", note = "", role = "Physical" },
    ["crippled treads"] = { itemName = "Crippled Treads", note = "", role = "Physical" },
    ["legguards of the undisturbed"] = { itemName = "Legguards of the Undisturbed", note = "", role = "Spellpower" },
    ["poignant sabatons"] = { itemName = "Poignant Sabatons", note = "", role = "Spellpower" },
    ["gauntlets of the disobedient"] = { itemName = "Gauntlets of the Disobedient", note = "", role = "Tank" },
    ["shoulderguards of opportunity"] = { itemName = "Shoulderguards of Opportunity", note = "", role = "Physical" },
    ["cryptfiend's bite"] = { itemName = "Cryptfiend's Bite", note = "", role = "Physical" },
    ["the undeath carrier"] = { itemName = "The Undeath Carrier", note = "", role = "Physical" },
    ["sigil of awareness"] = { itemName = "Sigil of Awareness", note = "", role = "DEATH KNIGHT" },
    ["heigan's putrid vestments"] = { itemName = "Heigan's Putrid Vestments", note = "", role = "Spellpower" },
    ["serene echoes"] = { itemName = "Serene Echoes", note = "", role = "Spellpower" },
    ["gloves of the dancing bear"] = { itemName = "Gloves of the Dancing Bear", note = "", role = "Spellpower" },
    ["stalk-skin belt"] = { itemName = "Stalk-Skin Belt", note = "", role = "Physical" },
    ["eruption-scarred boots"] = { itemName = "Eruption-Scarred Boots", note = "", role = "Spellpower" },
    ["helm of pilgrimage"] = { itemName = "Helm of Pilgrimage", note = "", role = "Spellpower" },
    ["leggings of colossal strides"] = { itemName = "Leggings of Colossal Strides", note = "", role = "Physical" },
    ["bindings of the decrepit"] = { itemName = "Bindings of the Decrepit", note = "", role = "Spellpower" },
    ["breastplate of tormented rage"] = { itemName = "Breastplate of Tormented Rage", note = "", role = "Tank" },
    ["chestguard of bitter charms"] = { itemName = "Chestguard of Bitter Charms", note = "", role = "Spellpower" },
    ["iron-spring jumpers"] = { itemName = "Iron-Spring Jumpers", note = "", role = "Physical" },
    ["legguards of the apostle"] = { itemName = "Legguards of the Apostle", note = "", role = "Spellpower" },
    ["mantle of the lost conqueror"] = { itemName = "Mantle of the Lost Conqueror", note = "Paladin, Priest, Warlock", role = "ALL" },
    ["mantle of the lost protector"] = { itemName = "Mantle of the Lost Protector", note = "Warrior, Hunter, Shaman", role = "ALL" },
    ["mantle of the lost vanquisher"] = { itemName = "Mantle of the Lost Vanquisher", note = "Rogue, Death Knight, Mage, Druid", role = "ALL" },
    ["the hand of nerub"] = { itemName = "The Hand of Nerub", note = "", role = "Physical" },
    ["the impossible dream"] = { itemName = "The Impossible Dream", note = "", role = "Spellpower" },
    ["fading glow"] = { itemName = "Fading Glow", note = "", role = "Spellpower" },
    ["boots of impetuous ideals"] = { itemName = "Boots of Impetuous Ideals", note = "", role = "Spellpower" },
    ["cowl of innocent delight"] = { itemName = "Cowl of Innocent Delight", note = "", role = "Spellpower" },
    ["vest of vitality"] = { itemName = "Vest of Vitality", note = "", role = "Spellpower" },
    ["footwraps of vile deceit"] = { itemName = "Footwraps of Vile Deceit", note = "", role = "Physical" },
    ["grotesque handgrips"] = { itemName = "Grotesque Handgrips", note = "", role = "Physical" },
    ["greaves of turbulence"] = { itemName = "Greaves of Turbulence", note = "", role = "Tank" },
    ["girdle of unity"] = { itemName = "Girdle of Unity", note = "", role = "Spellpower" },
    ["idol of the shooting star"] = { itemName = "Idol of the Shooting Star", note = "", role = "DRUID" },
    ["totem of dueling"] = { itemName = "Totem of Dueling", note = "", role = "SHAMAN" },
    ["boots of forlorn wishes"] = { itemName = "Boots of Forlorn Wishes", note = "", role = "Spellpower" },
    ["bindings of the expansive mind"] = { itemName = "Bindings of the Expansive Mind", note = "", role = "Spellpower" },
    ["chestpiece of suspicion"] = { itemName = "Chestpiece of Suspicion", note = "", role = "Physical" },
    ["spaulders of egotism"] = { itemName = "Spaulders of Egotism", note = "", role = "Physical" },
    ["esteemed bindings"] = { itemName = "Esteemed Bindings", note = "", role = "Spellpower" },
    ["shoulderpads of secret arts"] = { itemName = "Shoulderpads of Secret Arts", note = "", role = "Physical" },
    ["girdle of recuperation"] = { itemName = "Girdle of Recuperation", note = "", role = "Spellpower" },
    ["bands of mutual respect"] = { itemName = "Bands of Mutual Respect", note = "", role = "Spellpower" },
    ["faithful steel sabatons"] = { itemName = "Faithful Steel Sabatons", note = "", role = "Spellpower" },
    ["gauntlets of guiding touch"] = { itemName = "Gauntlets of Guiding Touch", note = "", role = "Spellpower" },
    ["legplates of double strikes"] = { itemName = "Legplates of Double Strikes", note = "", role = "Physical" },
    ["girdle of razuvious"] = { itemName = "Girdle of Razuvious", note = "", role = "Physical" },
    ["bracers of the unholy knight"] = { itemName = "Bracers of the Unholy Knight", note = "", role = "Tank" },
    ["touch of horror"] = { itemName = "Touch of Horror", note = "", role = "Spellpower" },
    ["life and death"] = { itemName = "Life and Death", note = "", role = "Spellpower" },
    ["libram of resurgence"] = { itemName = "Libram of Resurgence", note = "", role = "PALADIN" },
    ["idol of awakening"] = { itemName = "Idol of Awakening", note = "", role = "DRUID" },
    ["gothik's cowl"] = { itemName = "Gothik's Cowl", note = "", role = "Spellpower" },
    ["bindings of yearning"] = { itemName = "Bindings of Yearning", note = "", role = "Spellpower" },
    ["hood of the exodus"] = { itemName = "Hood of the Exodus", note = "", role = "Physical" },
    ["leggings of fleeting moments"] = { itemName = "Leggings of Fleeting Moments", note = "", role = "Physical" },
    ["shackled cinch"] = { itemName = "Shackled Cinch", note = "", role = "Spellpower" },
    ["helm of unleashed energy"] = { itemName = "Helm of Unleashed Energy", note = "", role = "Spellpower" },
    ["leggings of failed escape"] = { itemName = "Leggings of Failed Escape", note = "", role = "Physical" },
    ["helm of vital protection"] = { itemName = "Helm of Vital Protection", note = "", role = "Tank" },
    ["burdened shoulderplates"] = { itemName = "Burdened Shoulderplates", note = "", role = "Tank" },
    ["bracers of unrelenting attack"] = { itemName = "Bracers of Unrelenting Attack", note = "", role = "Physical" },
    ["abetment bracers"] = { itemName = "Abetment Bracers", note = "", role = "Spellpower" },
    ["breastplate of the lost conqueror"] = { itemName = "Breastplate of the Lost Conqueror", note = "Paladin, Priest, Warlock", role = "ALL" },
    ["breastplate of the lost protector"] = { itemName = "Breastplate of the Lost Protector", note = "Warrior, Hunter, Shaman", role = "ALL" },
    ["breastplate of the lost vanquisher"] = { itemName = "Breastplate of the Lost Vanquisher", note = "Rogue, Death Knight, Mage, Druid", role = "ALL" },
    ["damnation"] = { itemName = "Damnation", note = "", role = "Spellpower" },
    ["armageddon"] = { itemName = "Armageddon", note = "", role = "Physical" },
    ["broken promise"] = { itemName = "Broken Promise", note = "", role = "Tank" },
    ["final voyage"] = { itemName = "Final Voyage", note = "", role = "Physical" },
    ["urn of lost memories"] = { itemName = "Urn of Lost Memories", note = "", role = "Spellpower" },
    ["mantle of the corrupted"] = { itemName = "Mantle of the Corrupted", note = "", role = "Spellpower" },
    ["gloves of peaceful death"] = { itemName = "Gloves of Peaceful Death", note = "", role = "Spellpower" },
    ["helm of the grave"] = { itemName = "Helm of the Grave", note = "", role = "Physical" },
    ["pauldrons of havoc"] = { itemName = "Pauldrons of Havoc", note = "", role = "Physical" },
    ["leggings of voracious shadows"] = { itemName = "Leggings of Voracious Shadows", note = "", role = "Spellpower" },
    ["zeliek's gauntlets"] = { itemName = "Zeliek's Gauntlets", note = "", role = "Physical" },
    ["split greathammer"] = { itemName = "Split Greathammer", note = "", role = "Physical" },
    ["arrowsong"] = { itemName = "Arrowsong", note = "", role = "Physical" },
    ["hero's surrender"] = { itemName = "Hero's Surrender", note = "", role = "Tank" },
    ["surplus limb"] = { itemName = "Surplus Limb", note = "", role = "Spellpower" },
    ["totem of hex"] = { itemName = "Totem of Hex", note = "", role = "SHAMAN" },
    ["libram of tolerance"] = { itemName = "Libram of Tolerance", note = "", role = "PALADIN" },
    ["boots of persuasion"] = { itemName = "Boots of Persuasion", note = "", role = "Spellpower" },
    ["sash of solitude"] = { itemName = "Sash of Solitude", note = "", role = "Spellpower" },
    ["boots of septic wounds"] = { itemName = "Boots of Septic Wounds", note = "", role = "Spellpower" },
    ["belt of the tortured"] = { itemName = "Belt of the Tortured", note = "", role = "Physical" },
    ["gloves of calculated risk"] = { itemName = "Gloves of Calculated Risk", note = "", role = "Physical" },
    ["girdle of the gambit"] = { itemName = "Girdle of the Gambit", note = "", role = "Spellpower" },
    ["crude discolored battlegrips"] = { itemName = "Crude Discolored Battlegrips", note = "", role = "Physical" },
    ["fleshless girdle"] = { itemName = "Fleshless Girdle", note = "", role = "Tank" },
    ["waistguard of divine grace"] = { itemName = "Waistguard of Divine Grace", note = "", role = "Spellpower" },
    ["origin of nightmares"] = { itemName = "Origin of Nightmares", note = "", role = "Physical" },
    ["twilight mist"] = { itemName = "Twilight Mist", note = "", role = "Physical" },
    ["plague igniter"] = { itemName = "Plague Igniter", note = "", role = "Spellpower" },
    ["cowl of vanity"] = { itemName = "Cowl of Vanity", note = "", role = "Spellpower" },
    ["sympathetic amice"] = { itemName = "Sympathetic Amice", note = "", role = "Spellpower" },
    ["mantle of the fatigued sage"] = { itemName = "Mantle of the Fatigued Sage", note = "", role = "Spellpower" },
    ["tunic of indulgence"] = { itemName = "Tunic of Indulgence", note = "", role = "Physical" },
    ["desecrated past"] = { itemName = "Desecrated Past", note = "", role = "Spellpower" },
    ["fallout impervious tunic"] = { itemName = "Fallout Impervious Tunic", note = "", role = "Spellpower" },
    ["spaulders of incoherence"] = { itemName = "Spaulders of Incoherence", note = "", role = "Spellpower" },
    ["depraved linked belt"] = { itemName = "Depraved Linked Belt", note = "", role = "Physical" },
    ["slime stream bands"] = { itemName = "Slime Stream Bands", note = "", role = "Physical" },
    ["chestguard of the exhausted"] = { itemName = "Chestguard of the Exhausted", note = "", role = "Tank" },
    ["girdle of chivalry"] = { itemName = "Girdle of Chivalry", note = "", role = "Physical" },
    ["bracers of liberation"] = { itemName = "Bracers of Liberation", note = "", role = "Spellpower" },
    ["legplates of the lost conqueror"] = { itemName = "Legplates of the Lost Conqueror", note = "Paladin, Priest, Warlock", role = "ALL" },
    ["legplates of the lost protector"] = { itemName = "Legplates of the Lost Protector", note = "Warrior, Hunter, Shaman", role = "ALL" },
    ["legplates of the lost vanquisher"] = { itemName = "Legplates of the Lost Vanquisher", note = "Rogue, Death Knight, Mage, Druid", role = "ALL" },
    ["spire of sunset"] = { itemName = "Spire of Sunset", note = "", role = "Spellpower" },
    ["wraps of the persecuted"] = { itemName = "Wraps of the Persecuted", note = "", role = "Spellpower" },
    ["cincture of polarity"] = { itemName = "Cincture of Polarity", note = "", role = "Spellpower" },
    ["cover of silence"] = { itemName = "Cover of Silence", note = "", role = "Physical" },
    ["headpiece of fungal bloom"] = { itemName = "Headpiece of Fungal Bloom", note = "", role = "Spellpower" },
    ["benefactor's gauntlets"] = { itemName = "Benefactor's Gauntlets", note = "", role = "Spellpower" },
    ["pauldrons of the abandoned"] = { itemName = "Pauldrons of the Abandoned", note = "", role = "Physical" },
    ["sabatons of endurance"] = { itemName = "Sabatons of Endurance", note = "", role = "Tank" },
    ["faceguard of the succumbed"] = { itemName = "Faceguard of the Succumbed", note = "", role = "Spellpower" },
    ["riveted abomination leggings"] = { itemName = "Riveted Abomination Leggings", note = "", role = "Physical" },
    ["heroic key to the focusing iris"] = { itemName = "Heroic Key to the Focusing Iris", note = "LC", role = "ALL" },
    ["murder"] = { itemName = "Murder", note = "", role = "Physical" },
    ["bandit's insignia"] = { itemName = "Bandit's Insignia", note = "", role = "Physical" },
    ["rune of repulsion"] = { itemName = "Rune of Repulsion", note = "", role = "Tank" },
    ["extract of necromantic power"] = { itemName = "Extract of Necromantic Power", note = "", role = "Spellpower" },
    ["soul of the dead"] = { itemName = "Soul of the Dead", note = "", role = "Spellpower" },
    ["gatekeeper"] = { itemName = "Gatekeeper", note = "", role = "Tank" },
    ["ring of decaying beauty"] = { itemName = "Ring of Decaying Beauty", note = "", role = "Spellpower" },
    ["icy blast amulet"] = { itemName = "Icy Blast Amulet", note = "", role = "Physical" },
    ["cosmic lights"] = { itemName = "Cosmic Lights", note = "", role = "Spellpower" },
    ["ceaseless pity"] = { itemName = "Ceaseless Pity", note = "", role = "Spellpower" },
    ["sympathy"] = { itemName = "Sympathy", note = "", role = "Spellpower" },
    ["gloves of grandeur"] = { itemName = "Gloves of Grandeur", note = "", role = "Spellpower" },
    ["legwraps of the defeated dragon"] = { itemName = "Legwraps of the Defeated Dragon", note = "", role = "Spellpower" },
    ["gloves of fast reactions"] = { itemName = "Gloves of Fast Reactions", note = "", role = "Physical" },
    ["legguards of the boneyard"] = { itemName = "Legguards of the Boneyard", note = "", role = "Spellpower" },
    ["boots of the great construct"] = { itemName = "Boots of the Great Construct", note = "", role = "Physical" },
    ["breastplate of frozen pain"] = { itemName = "Breastplate of Frozen Pain", note = "", role = "Physical" },
    ["platehelm of the great wyrm"] = { itemName = "Platehelm of the Great Wyrm", note = "", role = "Tank" },
    ["bone-inlaid legguards"] = { itemName = "Bone-Inlaid Legguards", note = "", role = "Spellpower" },
    ["noble birthright pauldrons"] = { itemName = "Noble Birthright Pauldrons", note = "", role = "Spellpower" },
    ["crown of the lost conqueror"] = { itemName = "Crown of the Lost Conqueror", note = "Paladin, Priest, Warlock", role = "ALL" },
    ["crown of the lost protector"] = { itemName = "Crown of the Lost Protector", note = "Warrior, Hunter, Shaman", role = "ALL" },
    ["crown of the lost vanquisher"] = { itemName = "Crown of the Lost Vanquisher", note = "Rogue, Death Knight, Mage, Druid", role = "ALL" },
    ["calamity's grasp"] = { itemName = "Calamity's Grasp", note = "", role = "Physical" },
    ["betrayer of humanity"] = { itemName = "Betrayer of Humanity", note = "LC", role = "Physical" },
    ["envoy of mortality"] = { itemName = "Envoy of Mortality", note = "", role = "Physical" },
    ["sinister revenge"] = { itemName = "Sinister Revenge", note = "", role = "Physical" },
    ["journey's end"] = { itemName = "Journey's End", note = "", role = "Physical" },
    ["torch of holy fire"] = { itemName = "Torch of Holy Fire", note = "LC", role = "Spellpower" },
    ["the turning tide"] = { itemName = "The Turning Tide", note = "LC", role = "Spellpower" },
    ["wall of terror"] = { itemName = "Wall of Terror", note = "", role = "Tank" },
    ["voice of reason"] = { itemName = "Voice of Reason", note = "", role = "Spellpower" },
    ["last laugh"] = { itemName = "Last Laugh", note = "", role = "Tank" },
    ["drape of the deadly foe"] = { itemName = "Drape of the Deadly Foe", note = "LC", role = "Physical" },
    ["cape of the unworthy wizard"] = { itemName = "Cape of the Unworthy Wizard", note = "", role = "Spellpower" },
    ["signet of manifested pain"] = { itemName = "Signet of Manifested Pain", note = "", role = "Spellpower" },
    ["boundless ambition"] = { itemName = "Boundless Ambition", note = "", role = "Tank" },
    ["leggings of mortal arrogance"] = { itemName = "Leggings of Mortal Arrogance", note = "", role = "Spellpower" },
    ["gloves of the lost conqueror"] = { itemName = "Gloves of the Lost Conqueror", note = "Paladin, Priest, Warlock", role = "ALL" },
    ["gloves of the lost protector"] = { itemName = "Gloves of the Lost Protector", note = "Warrior, Hunter, Shaman", role = "ALL" },
    ["gloves of the lost vanquisher"] = { itemName = "Gloves of the Lost Vanquisher", note = "Rogue, Death Knight, Mage, Druid", role = "ALL" },
    ["satchel of spoils"] = { itemName = "Satchel of Spoils", note = "", role = "ALL" },
    ["dragon hide bag"] = { itemName = "Dragon Hide Bag", note = "", role = "ALL" },
    ["gale-proof cloak"] = { itemName = "Gale-Proof Cloak", note = "", role = "Tank" },
    ["signet of the accord"] = { itemName = "Signet of the Accord", note = "", role = "Tank" },
    ["circle of arcane streams"] = { itemName = "Circle of Arcane Streams", note = "", role = "Spellpower" },
    ["volitant amulet"] = { itemName = "Volitant Amulet", note = "", role = "Spellpower" },
    ["majestic dragon figurine"] = { itemName = "Majestic Dragon Figurine", note = "", role = "Spellpower" },
    ["crimson steel"] = { itemName = "Crimson Steel", note = "", role = "Physical" },
    ["blade-scarred tunic"] = { itemName = "Blade-Scarred Tunic", note = "", role = "Physical" },
    ["legguards of composure"] = { itemName = "Legguards of Composure", note = "", role = "Spellpower" },
    ["titan's outlook"] = { itemName = "Titan's Outlook", note = "", role = "Physical" },
    ["remembrance girdle"] = { itemName = "Remembrance Girdle", note = "", role = "Spellpower" },
    ["greatring of collision"] = { itemName = "Greatring of Collision", note = "", role = "Physical" },
    ["enamored cowl"] = { itemName = "Enamored Cowl", note = "", role = "Spellpower" },
    ["chestguard of flagrant prowess"] = { itemName = "Chestguard of Flagrant Prowess", note = "", role = "Physical" },
    ["belabored legplates"] = { itemName = "Belabored Legplates", note = "", role = "Physical" },
    ["reins of the black drake"] = { itemName = "Reins of the Black Drake", note = "LC", role = "ALL" },
    ["gauntlets of the lost conqueror"] = { itemName = "Gauntlets of the Lost Conqueror", note = "Paladin, Priest, Warlock", role = "ALL" },
    ["gauntlets of the lost protector"] = { itemName = "Gauntlets of the Lost Protector", note = "Warrior, Hunter, Shaman", role = "ALL" },
    ["gauntlets of the lost vanquisher"] = { itemName = "Gauntlets of the Lost Vanquisher", note = "Rogue, Death Knight, Mage, Druid", role = "ALL" },
    ["large satchel of spoils"] = { itemName = "Large Satchel of Spoils", note = "", role = "ALL" },
    ["dragon hide bag"] = { itemName = "Dragon Hide Bag", note = "", role = "ALL" },
    ["fury of the five flights"] = { itemName = "Fury of the Five Flights", note = "LC", role = "Physical" },
    ["illustration of the dragon soul"] = { itemName = "Illustration of the Dragon Soul", note = "LC", role = "Spellpower" },
    ["staff of restraint"] = { itemName = "Staff of Restraint", note = "", role = "Spellpower" },
    ["the sanctum's flowing vestments"] = { itemName = "The Sanctum's Flowing Vestments", note = "", role = "Spellpower" },
    ["mantle of the eternal sentinel"] = { itemName = "Mantle of the Eternal Sentinel", note = "", role = "Spellpower" },
    ["concealment shoulderpads"] = { itemName = "Concealment Shoulderpads", note = "", role = "Physical" },
    ["hyaline helm of the sniper"] = { itemName = "Hyaline Helm of the Sniper", note = "", role = "Physical" },
    ["bountiful gauntlets"] = { itemName = "Bountiful Gauntlets", note = "", role = "Spellpower" },
    ["council chamber epaulets"] = { itemName = "Council Chamber Epaulets", note = "", role = "Spellpower" },
    ["upstanding spaulders"] = { itemName = "Upstanding Spaulders", note = "", role = "Physical" },
    ["dragonstorm breastplate"] = { itemName = "Dragonstorm Breastplate", note = "", role = "Tank" },
    ["chestplate of the great aspects"] = { itemName = "Chestplate of the Great Aspects", note = "", role = "Spellpower" },
    ["dragon brood legguards"] = { itemName = "Dragon Brood Legguards", note = "", role = "Tank" },
    ["wyrmrest band"] = { itemName = "Wyrmrest Band", note = "", role = "Spellpower" },
    ["pennant cloak"] = { itemName = "Pennant Cloak", note = "LC", role = "Spellpower" },
    ["unsullied cuffs"] = { itemName = "Unsullied Cuffs", note = "LC", role = "Spellpower" },
    ["headpiece of reconciliation"] = { itemName = "Headpiece of Reconciliation", note = "", role = "Spellpower" },
    ["leggings of the honored"] = { itemName = "Leggings of the Honored", note = "", role = "Physical" },
    ["obsidian greathelm"] = { itemName = "Obsidian Greathelm", note = "LC", role = "Physical" },
    ["reins of the twilight drake"] = { itemName = "Reins of the Twilight Drake", note = "LC", role = "ALL" },
    ["reins of the blue drake"] = { itemName = "Reins of the Blue Drake", note = "LC", role = "ALL" },
    ["surge needle ring"] = { itemName = "Surge Needle Ring", note = "BOE", role = "Physical" },
    ["necklace of the glittering chamber"] = { itemName = "Necklace of the Glittering Chamber", note = "", role = "Spellpower" },
    ["ice spire scepter"] = { itemName = "Ice Spire Scepter", note = "", role = "Spellpower" },
    ["black ice"] = { itemName = "Black Ice", note = "", role = "Physical" },
    ["barricade of eternity"] = { itemName = "Barricade of Eternity", note = "", role = "Tank" },
    ["greatstaff of the nexus"] = { itemName = "Greatstaff of the Nexus", note = "", role = "Spellpower" },
    ["hailstorm"] = { itemName = "Hailstorm", note = "", role = "Physical" },
    ["gown of the spell-weaver"] = { itemName = "Gown of the Spell-Weaver", note = "", role = "Spellpower" },
    ["footsteps of malygos"] = { itemName = "Footsteps of Malygos", note = "", role = "Spellpower" },
    ["focusing energy epaulets"] = { itemName = "Focusing Energy Epaulets", note = "", role = "Spellpower" },
    ["reins of the azure drake"] = { itemName = "Reins of the Azure Drake", note = "", role = "ALL" },
    ["mark of norgannon"] = { itemName = "Mark of Norgannon", note = "", role = "Physical" },
    ["living ice crystals"] = { itemName = "Living Ice Crystals", note = "", role = "Spellpower" },
    ["blanketing robes of snow"] = { itemName = "Blanketing Robes of Snow", note = "", role = "Spellpower" },
    ["arcanic tramplers"] = { itemName = "Arcanic Tramplers", note = "", role = "Spellpower" },
    ["hood of rationality"] = { itemName = "Hood of Rationality", note = "", role = "Spellpower" },
    ["leggings of the wanton spellcaster"] = { itemName = "Leggings of the Wanton Spellcaster", note = "", role = "" },
    ["mantle of dissemination"] = { itemName = "Mantle of Dissemination", note = "", role = "" },
    ["leash of heedless magic"] = { itemName = "Leash of Heedless Magic", note = "", role = "" },
    ["chestguard of the recluse"] = { itemName = "Chestguard of the Recluse", note = "", role = "" },
    ["frosted adroit handguards"] = { itemName = "Frosted Adroit Handguards", note = "", role = "" },
    ["spaulders of catatonia"] = { itemName = "Spaulders of Catatonia", note = "", role = "" },
    ["unravelling strands of sanity"] = { itemName = "Unravelling Strands of Sanity", note = "", role = "" },
    ["tunic of the artifact guardian"] = { itemName = "Tunic of the Artifact Guardian", note = "", role = "" },
    ["boots of the renewed flight"] = { itemName = "Boots of the Renewed Flight", note = "", role = "" },
    ["winter spectacle gloves"] = { itemName = "Winter Spectacle Gloves", note = "", role = "" },
    ["blue aspect helm"] = { itemName = "Blue Aspect Helm", note = "", role = "" },
    ["melancholy sabatons"] = { itemName = "Melancholy Sabatons", note = "", role = "" },
    ["boots of healing energies"] = { itemName = "Boots of Healing Energies", note = "", role = "" },
    ["legplates of sovereignty"] = { itemName = "Legplates of Sovereignty", note = "", role = "" },
    ["elevated lair pauldrons"] = { itemName = "Elevated Lair Pauldrons", note = "", role = "" },
}

function addon:InitializeConfig()
    self.config = self.db.config
    self:NormalizeAllConfig()
end

function addon:NormalizeClassName(value)
    local normalized = util:NormalizeKey(value)
    return configClassAliases[normalized] or normalized
end

function addon:NormalizeStatus(value)
    local normalized = util:NormalizeKey(value)
    if normalized == "alt" or normalized == "designated alt" then
        normalized = "designatedalt"
    end
    if normalized ~= "main" and normalized ~= "designatedalt" then
        normalized = "nil"
    end
    return normalized
end

function addon:ParseClassSpecToken(token)
    token = util:NormalizeKey(token)
    if token == "" or token == "rest" then
        return {
            isRest = true,
            raw = "rest",
        }
    end

    local className
    local specName = ""

    for _, candidateClass in ipairs(orderedClassNames) do
        local prefix = candidateClass .. " "
        local suffix = " " .. candidateClass

        if token == candidateClass then
            className = candidateClass
            specName = ""
            break
        elseif string.sub(token, 1, string.len(prefix)) == prefix then
            className = candidateClass
            specName = string.sub(token, string.len(prefix) + 1)
            break
        elseif string.sub(token, -string.len(suffix)) == suffix then
            className = candidateClass
            specName = string.sub(token, 1, string.len(token) - string.len(suffix))
            break
        end
    end

    specName = util:NormalizeKey(specName)

    return {
        raw = token,
        className = className,
        specName = specName,
        matchKeys = {
            util:NormalizeKey((className or "") .. " " .. (specName or "")),
            util:NormalizeKey((specName or "") .. " " .. (className or "")),
        },
    }
end

function addon:ParseRosterImport(text)
    local rosterEntries = {}
    for _, line in ipairs(util:SplitLines(text)) do
        local parts = util:Split(line, ",")
        local rawName = string.trim(parts[1] or "")
        local descriptor = string.trim(parts[2] or "")
        local status = self:NormalizeStatus(parts[3] or "")
        if rawName ~= "" then
            local parsed = self:ParseClassSpecToken(descriptor)
            rosterEntries[#rosterEntries + 1] = {
                name = rawName,
                className = parsed.className,
                specName = parsed.specName,
                status = status,
                descriptor = descriptor,
            }
        end
    end
    return rosterEntries
end

function addon:NormalizeRosterEntries(entries)
    local normalizedEntries = {}
    local seen = {}

    for _, entry in ipairs(entries or {}) do
        local name = string.trim(entry.name or "")
        if name ~= "" then
            local key = util:NormalizeKey(name)
            if not seen[key] then
                local className = self:NormalizeClassName(entry.className or "")
                local specName = util:NormalizeKey(entry.specName or "")
                local status = self:NormalizeStatus(entry.status or "")
                normalizedEntries[#normalizedEntries + 1] = {
                    name = name,
                    className = className,
                    specName = specName,
                    status = status,
                    descriptor = util:NormalizeKey((className or "") .. " " .. (specName or "")),
                }
                seen[key] = true
            end
        end
    end

    table.sort(normalizedEntries, function(left, right)
        return util:NormalizeKey(left.name) < util:NormalizeKey(right.name)
    end)

    return normalizedEntries
end

function addon:BuildRosterMap(entries)
    local roster = {}
    for _, entry in ipairs(entries or {}) do
        roster[util:NormalizeKey(entry.name)] = {
            name = entry.name,
            className = entry.className,
            specName = entry.specName,
            status = entry.status,
            descriptor = entry.descriptor or util:NormalizeKey((entry.className or "") .. " " .. (entry.specName or "")),
        }
    end
    return roster
end

function addon:SerializeRosterEntries(entries)
    local lines = {}
    for _, entry in ipairs(entries or {}) do
        local status = entry.status == "designatedalt" and "designatedAlt" or (entry.status == "main" and "main" or "unknown")
        local descriptor = string.trim((entry.className or "") .. " " .. (entry.specName or ""))
        lines[#lines + 1] = string.format("%s, %s, %s", entry.name or "", descriptor, status)
    end
    return table.concat(lines, "\n")
end

function addon:ParseTieredRuleText(text, parser)
    local rules = {}

    for _, line in ipairs(util:SplitLines(text)) do
        local parts = util:Split(line, ",")
        local itemName = string.trim(parts[1] or "")
        local ruleText = string.trim(parts[2] or "")
        if itemName ~= "" and ruleText ~= "" then
            local tiers = {}

            for tierIndex, tierText in ipairs(util:Split(ruleText, ">")) do
                local entries = {}
                tierText = string.trim(tierText)
                for _, token in ipairs(util:Split(tierText, "/")) do
                    local parsed = parser(self, token)
                    if parsed then
                        if parsed.isRest then
                            table.insert(entries, {
                                raw = "rest",
                                isRest = true,
                            })
                        else
                            table.insert(entries, parsed)
                        end
                    end
                end

                if #entries > 0 then
                    tiers[#tiers + 1] = {
                        index = tierIndex,
                        raw = tierText,
                        entries = entries,
                    }
                end
            end

            local key = util:NormalizeKey(itemName)
            rules[key] = {
                itemName = itemName,
                tiers = tiers,
                raw = ruleText,
                key = key,
            }
        end
    end

    return rules
end

function addon:ParseNamedToken(token)
    token = util:NormalizeKey(token)
    if token == "" then
        return nil
    end
    if token == "lc" or token == "loot council" then
        return {
            isLootCouncil = true,
            raw = "LC",
        }
    end
    if token == "rest" then
        return {
            isRest = true,
            raw = "rest",
        }
    end
    return {
        raw = token,
        playerKey = util:NormalizeKey(token),
    }
end

function addon:NormalizeAllConfig()
    local rosterEntries = self.config.rosterEntries
    local rosterImportText = self.config.rosterImportText or ""
    local shouldUseDefaultRoster = rosterImportText == "" or rosterImportText == (self.legacySampleRosterImportText or "")

    if shouldUseDefaultRoster and (type(rosterEntries) ~= "table" or #rosterEntries <= 2) then
        rosterEntries = util:CloneTable(self.defaultRosterEntries or {})
    elseif type(rosterEntries) ~= "table" or #rosterEntries == 0 then
        rosterEntries = self:ParseRosterImport(self.config.rosterImportText or "")
    end
    if type(rosterEntries) ~= "table" or #rosterEntries == 0 then
        rosterEntries = util:CloneTable(self.defaultRosterEntries or {})
    end

    self.config.rosterEntries = self:NormalizeRosterEntries(rosterEntries)
    self.config.roster = self:BuildRosterMap(self.config.rosterEntries)
    self.config.rosterImportText = self:SerializeRosterEntries(self.config.rosterEntries)
    self.config.lootRules = self:ParseTieredRuleText(self.config.lootPriorityText or "", self.ParseClassSpecToken)
    self.config.namedRules = self:ParseTieredRuleText(self.config.namedItemsText or "", self.ParseNamedToken)
end

function addon:GetItemInfoEntry(itemName)
    local key = util:NormalizeKey(itemName or "")
    if key == "" then
        return nil
    end

    return (self.defaultItemInfo or {})[key]
end

function addon:GetItemInfoText(itemName)
    local entry = self:GetItemInfoEntry(itemName)
    if not entry then
        return ""
    end

    local note = string.trim(entry.note or "")
    local role = string.trim(entry.role or "")

    if note ~= "" and role ~= "" then
        return string.format("%s, %s", note, role)
    end

    return note ~= "" and note or role
end

function addon:GetItemAllowedClasses(itemName)
    local entry = self:GetItemInfoEntry(itemName)
    if not entry then
        return nil
    end

    local note = string.trim(entry.note or "")
    if note == "" then
        return nil
    end

    local allowed = {}
    for _, token in ipairs(util:Split(note, ",")) do
        local normalized = util:NormalizeKey(token)
        local className = configClassAliases[normalized]
        if className then
            allowed[className] = true
        end
    end

    return next(allowed) and allowed or nil
end

function addon:IsClassAllowedForItem(itemName, className)
    local allowed = self:GetItemAllowedClasses(itemName)
    if not allowed then
        return true
    end

    local normalizedClass = configClassAliases[util:NormalizeKey(className or "")]
    if not normalizedClass then
        return true
    end

    return allowed[normalizedClass] == true
end

function addon:IsPlayerAllowedForItem(itemName, playerName)
    if not itemName or itemName == "" then
        return true
    end

    local playerKey = util:NormalizeKey(playerName or "")
    local localPlayerKey = util:NormalizeKey(util:GetPlayerName("player") or "")
    local className

    if playerKey ~= "" and playerKey == localPlayerKey then
        local localizedClass = select(2, UnitClass("player"))
        if localizedClass and localizedClass ~= "" then
            className = string.gsub(string.lower(localizedClass), "deathknight", "death knight")
        end
    end

    if not className or className == "" then
        local attendee = self.GetAttendee and self:GetAttendee(playerName)
        local rosterProfile = self.GetRosterProfile and self:GetRosterProfile(playerName)
        className = (attendee and attendee.className) or (rosterProfile and rosterProfile.className) or ""
    end

    return self:IsClassAllowedForItem(itemName, className)
end

function addon:SaveImports(rosterText, lootText, namedText)
    if rosterText ~= nil then
        self.config.rosterEntries = self:ParseRosterImport(rosterText or "")
        self.config.rosterImportText = rosterText or ""
    end
    self.config.lootPriorityText = lootText or self.config.lootPriorityText or ""
    self.config.namedItemsText = namedText or self.config.namedItemsText or ""
    self.config.revision = (self.config.revision or 0) + 1
    self:NormalizeAllConfig()
    self:RefreshRoster()
    self:TriggerCallback("CONFIG_UPDATED")
    self:Print("Configuration saved.")
end

function addon:SaveRosterText(rosterText, suppressPrint)
    self.config.rosterEntries = self:ParseRosterImport(rosterText or "")
    self.config.rosterImportText = rosterText or ""
    self.config.revision = (self.config.revision or 0) + 1
    self:NormalizeAllConfig()
    self:RefreshRoster()
    self:TriggerCallback("CONFIG_UPDATED")
    if not suppressPrint then
        self:Print("Roster saved.")
    end
end

function addon:SaveNamedItemsText(namedText, suppressPrint)
    self.config.namedItemsText = namedText or ""
    self.config.revision = (self.config.revision or 0) + 1
    self:NormalizeAllConfig()
    self:RefreshRoster()
    self:TriggerCallback("CONFIG_UPDATED")
    if not suppressPrint then
        self:Print("Named items saved.")
    end
end

function addon:GetRosterProfile(playerName)
    if not playerName then
        return nil
    end
    return self.config.roster[util:NormalizeKey(playerName)]
end

function addon:GetLootRule(itemName)
    return self.config.lootRules[util:NormalizeKey(itemName or "")]
end

function addon:GetNamedRule(itemName)
    return self.config.namedRules[util:NormalizeKey(itemName or "")]
end

function addon:GetRosterEntries()
    return self.config.rosterEntries or {}
end
