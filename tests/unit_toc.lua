-- Packaging guard for WeirdLoot.toc file paths.
--
-- The 3.3.5a client resolves toc file entries with BACKSLASH separators and silently skips entries
-- written with forward slashes -- the file simply never loads in-game, with no Lua error. The Linux
-- test harness loadfile()s the same paths with "/", so a forward-slash toc entry loads fine in tests
-- yet vanishes in-game. That exact mismatch shipped with the Data/ split: Data/BlacklistPresets/*.lua
-- and Data/RosterDefaults.lua used "/", so the blacklist preset dropdown and the default roster came
-- up empty in-game while every test stayed green. This guard fails the battery if any toc file path
-- reintroduces a forward slash.

local F = dofile("tests/_framework.lua").get()
local H = F
F.beginSuite("toc packaging battery")

H.test("WeirdLoot.toc: every file path uses backslashes, never forward slashes", function()
    local fh = assert(io.open("WeirdLoot.toc", "r"))
    local offenders = {}
    local lineNo = 0
    for line in fh:lines() do
        lineNo = lineNo + 1
        local trimmed = (line:gsub("^%s+", ""):gsub("%s+$", ""))
        -- file-load lines only: skip blanks, directives (##) and comments (--)
        if trimmed ~= "" and not trimmed:find("^##") and not trimmed:find("^%-%-") then
            if trimmed:find("/") then
                offenders[#offenders + 1] = "line " .. lineNo .. ": " .. trimmed
            end
        end
    end
    fh:close()
    H.eq(#offenders, 0, "forward-slash toc paths (won't load in-game): " .. table.concat(offenders, " | "))
end)

H.test("addon.version is pulled from the .toc, not hardcoded", function()
    local fh = assert(io.open("WeirdLoot.toc", "r"))
    local tocVersion
    for line in fh:lines() do tocVersion = line:match("^## Version:%s*(.-)%s*$"); if tocVersion then break end end
    fh:close()
    H.check(tocVersion and tocVersion ~= "", "the toc declares a ## Version:")
    local w = H.makeWorld("Masterlooter", true)
    H.eq(w.addon.version, tocVersion, "Core.lua reads its version from the toc via GetAddOnMetadata")
end)

F.endSuite()
