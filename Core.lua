local ADDON, ns = ...
local L = ns.L

local floor = math.floor

local PREFIX = "|cff33ff99JumpCounter|r: "

ns.sessionJumps = 0

function ns.Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. msg)
end

-- 1234567 -> "1,234,567" (separator depends on the client language)
function ns.FormatNumber(n)
    local sep = L.THOUSANDS
    local s = tostring(floor(n or 0)):reverse():gsub("(%d%d%d)", "%1" .. sep):reverse()
    if s:sub(1, #sep) == sep then s = s:sub(#sep + 1) end
    return s
end

-- 10, 25, 50, 100, 250, 500, 1000, 2500, ...
function ns.IsMilestone(n)
    local base = 10
    while base <= n do
        if n == base or n == base * 2.5 or n == base * 5 then
            return true
        end
        base = base * 10
    end
    return false
end

function ns.AccountTotal()
    local sum = 0
    for _, c in pairs(ns.db.chars) do
        sum = sum + (c.total or 0)
    end
    return sum
end

function ns.CharDisplayName(key, c)
    local name = c and c.name and (c.name .. " - " .. (c.realm or "?")) or key
    local color = c and c.class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[c.class]
    if color then
        return string.format("|cff%02x%02x%02x%s|r", floor(color.r * 255), floor(color.g * 255), floor(color.b * 255), name)
    end
    return name
end

---------------------------------------------------------------------------
-- Saved data
---------------------------------------------------------------------------

-- JumpCounterDB.chars["Name-Realm"] = { total, hours = { [hour since epoch] = count }, name, realm, class }
local function InitDB()
    JumpCounterDB = JumpCounterDB or {}
    local db = JumpCounterDB
    db.chars = db.chars or {}
    db.minimap = db.minimap or { angle = 215, hide = false }
    if db.announce == nil then db.announce = true end
    db.view = db.view or {}
    db.view.mode = db.view.mode or "day"
    db.view.char = db.view.char or "ALL"
    db.view.counts = db.view.counts or {}
    ns.db = db
end

local function InitChar()
    local name, realm = UnitName("player"), GetRealmName()
    local key = name .. "-" .. realm
    local c = ns.db.chars[key] or { total = 0, hours = {} }
    c.name, c.realm = name, realm
    c.class = select(2, UnitClass("player"))
    ns.db.chars[key] = c
    ns.charKey, ns.char = key, c
end

---------------------------------------------------------------------------
-- Milestones
---------------------------------------------------------------------------

local function GroupChannel()
    local home = LE_PARTY_CATEGORY_HOME
    if IsInRaid(home) then return "RAID" end
    if IsInGroup(home) then return "PARTY" end
end

-- groupText = nil: only show it to the player, never post it to the group
local function Celebrate(groupText, localText, noticeText)
    local channel = groupText and ns.db.announce and GroupChannel()
    if channel then
        SendChatMessage(groupText, channel)
    else
        ns.Print("|cffffd100" .. localText .. "|r")
    end
    if RaidNotice_AddMessage and RaidWarningFrame then
        RaidNotice_AddMessage(RaidWarningFrame, noticeText, ChatTypeInfo["RAID_WARNING"])
    end
    PlaySound(888) -- LEVELUPSOUND
end

local function CheckMilestones(charTotal, accountTotal)
    if ns.IsMilestone(charTotal) then
        local n = ns.FormatNumber(charTotal)
        Celebrate(L.MILESTONE_GROUP:format(n), L.MILESTONE_LOCAL:format(n), L.MILESTONE_NOTICE:format(n))
    end
    -- With only one character the account total equals the character total, so skip the duplicate.
    if accountTotal ~= charTotal and ns.IsMilestone(accountTotal) then
        local n = ns.FormatNumber(accountTotal)
        Celebrate(nil, L.ACCOUNT_LOCAL:format(n), L.ACCOUNT_NOTICE:format(n))
    end
end

---------------------------------------------------------------------------
-- Jump detection
---------------------------------------------------------------------------

local function AddJump()
    local c = ns.char
    if not c then return end
    local h = floor(time() / 3600)
    c.hours[h] = (c.hours[h] or 0) + 1
    c.total = c.total + 1
    ns.sessionJumps = ns.sessionJumps + 1
    CheckMilestones(c.total, ns.AccountTotal())
    if ns.OnJump then ns.OnJump() end
end

-- A press only counts once the character actually leaves the ground within this time,
-- so presses that don't lift off (rearing mount, rooted, ...) are ignored.
local CONFIRM_WINDOW = 0.5

-- Falling state of the previous frame, so a press while already airborne is not counted,
-- no matter whether the client sets the falling flag before or after our hook runs.
local wasFalling, fallStart, lastJump, pendingSince = false, 0, 0, nil

local watcher = CreateFrame("Frame")
watcher:SetScript("OnUpdate", function()
    local now = GetTime()
    local falling = IsFalling()
    if falling and not wasFalling then fallStart = now end
    wasFalling = falling
    if pendingSince then
        if falling then
            pendingSince = nil
            AddJump()
        elseif now - pendingSince > CONFIRM_WINDOW then
            pendingSince = nil
        end
    end
end)

hooksecurefunc("JumpOrAscendStart", function()
    local now = GetTime()
    if pendingSince then return end
    if wasFalling and IsFalling() and now - fallStart > 0.15 then return end
    if now - lastJump < 0.25 then return end
    if IsSwimming() or (IsFlying and IsFlying()) or UnitOnTaxi("player") then return end
    if not HasFullControl() or UnitIsDead("player") then return end
    -- a standing mount only rears up instead of jumping
    if IsMounted() and GetUnitSpeed("player") == 0 then return end
    lastJump = now
    if IsFalling() then
        AddJump()
    else
        pendingSince = now
    end
end)

---------------------------------------------------------------------------
-- Events & slash commands
---------------------------------------------------------------------------

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON then
        InitDB()
    elseif event == "PLAYER_LOGIN" then
        InitChar()
        ns.InitUI()
    end
end)

local function DeleteChar(arg)
    local wanted = arg:lower()
    for key, c in pairs(ns.db.chars) do
        if key:lower() == wanted then
            if key == ns.charKey then
                c.total, c.hours = 0, {}
                ns.Print(L.CHAR_RESET:format(key))
            else
                ns.db.chars[key] = nil
                ns.Print(L.CHAR_DELETED:format(key))
            end
            if ns.db.view.char == key and not ns.db.chars[key] then ns.db.view.char = "ALL" end
            if ns.RefreshWindow then ns.RefreshWindow() end
            return
        end
    end
    ns.Print(L.CHAR_NOT_FOUND:format(arg))
end

SLASH_JUMPCOUNTER1 = "/jumps"
SLASH_JUMPCOUNTER2 = "/jumpcounter"
SLASH_JUMPCOUNTER3 = "/sprung"
SlashCmdList.JUMPCOUNTER = function(msg)
    local cmd, arg = (msg or ""):match("^%s*(%S*)%s*(.-)%s*$")
    cmd = cmd:lower()
    if cmd == "" or cmd == "show" then
        ns.ToggleWindow()
    elseif cmd == "minimap" then
        ns.db.minimap.hide = not ns.db.minimap.hide
        ns.UpdateMinimapButton()
        ns.Print(ns.db.minimap.hide and L.MINIMAP_HIDDEN or L.MINIMAP_SHOWN)
    elseif cmd == "announce" or cmd == "ansage" then
        ns.db.announce = not ns.db.announce
        ns.Print(L.ANNOUNCE:format(ns.db.announce and L.ON or L.OFF))
    elseif cmd == "stats" then
        ns.Print(L.STATS:format(ns.charKey, ns.FormatNumber(ns.char.total),
            ns.FormatNumber(ns.AccountTotal()), ns.FormatNumber(ns.sessionJumps)))
    elseif cmd == "delete" and arg ~= "" then
        DeleteChar(arg)
    else
        for _, line in ipairs(L.HELP) do ns.Print(line) end
    end
end
