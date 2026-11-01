local ADDON, ns = ...
local L = ns.L

local floor, ceil, max, min = math.floor, math.ceil, math.max, math.min
local format = string.format

local DAY = 86400
local MIN_TIME = 1104537600 -- 01.01.2005, nothing to see before WoW existed

local GRAPH_W, GRAPH_H = 610, 240
local ICON = "Interface\\Icons\\Ability_Rogue_Sprint"

-- min/max/default: number of bars; static modes aggregate all data into fixed slots.
local MODES = {
    { key = "hour",      label = L.MODE_HOUR,      unit = L.UNIT_HOUR,  default = 24, min = 12, max = 72 },
    { key = "day",       label = L.MODE_DAY,       unit = L.UNIT_DAY,   default = 30, min = 7,  max = 90 },
    { key = "week",      label = L.MODE_WEEK,      unit = L.UNIT_WEEK,  default = 12, min = 4,  max = 52 },
    { key = "month",     label = L.MODE_MONTH,     unit = L.UNIT_MONTH, default = 12, min = 3,  max = 36 },
    { key = "year",      label = L.MODE_YEAR,      unit = L.UNIT_YEAR,  default = 5,  min = 3,  max = 20 },
    { key = "hourofday", label = L.MODE_HOUROFDAY, static = 24 },
    { key = "weekday",   label = L.MODE_WEEKDAY,   static = 7 },
}
local MODE_BY_KEY = {}
for _, m in ipairs(MODES) do MODE_BY_KEY[m.key] = m end

local view   -- ns.db.view
local offset = 0 -- bars shifted into the past
local current -- last aggregated data, used by tooltips

---------------------------------------------------------------------------
-- Time helpers (local time)
---------------------------------------------------------------------------

-- Monday = 1 ... Sunday = 7
local function WeekdayIndex(d)
    return (d.wday + 5) % 7 + 1
end

-- pattern tokens: YYYY, MM, DD (see Locales.lua)
local function FormatDate(pattern, t)
    local d = date("*t", t)
    return (pattern:gsub("YYYY", tostring(d.year)):gsub("MM", format("%02d", d.month)):gsub("DD", format("%02d", d.day)))
end

local function DayStart(t)
    local d = date("*t", t)
    return time({ year = d.year, month = d.month, day = d.day, hour = 0 })
end

local function PeriodStart(mode, t)
    if mode == "hour" then return floor(t / 3600) * 3600 end
    if mode == "day" then return DayStart(t) end
    local d = date("*t", t)
    if mode == "week" then
        -- noon of Monday, so DST changes can't push us into the wrong day
        return DayStart(DayStart(t) - (WeekdayIndex(d) - 1) * DAY + DAY / 2)
    end
    if mode == "month" then return time({ year = d.year, month = d.month, day = 1, hour = 0 }) end
    return time({ year = d.year, month = 1, day = 1, hour = 0 })
end

local function PeriodShift(mode, start, n)
    if mode == "hour" then return start + n * 3600 end
    if mode == "day" then return DayStart(start + n * DAY + DAY / 2) end
    if mode == "week" then return DayStart(start + n * 7 * DAY + DAY / 2) end
    -- time() can't handle dates before 1970, so refuse anything before WoW existed
    local d = date("*t", start)
    local year, month = d.year + n, 1
    if mode == "month" then
        local m = d.month - 1 + n
        year, month = d.year + floor(m / 12), m % 12 + 1
    end
    if year < 2005 then return nil end
    return time({ year = year, month = month, day = 1, hour = 0 })
end

local function ISOWeek(monday)
    local thu = date("*t", monday + 3 * DAY + DAY / 2)
    return floor((thu.yday - 1) / 7) + 1, thu.year
end

local function ShortLabel(mode, t, i)
    if mode == "hourofday" then return tostring(i - 1) end
    if mode == "weekday" then return L.WEEKDAYS[i] end
    local d = date("*t", t)
    if mode == "hour" then
        if d.hour == 0 then return FormatDate(L.DATE_SHORT, t) end
        return format("%02d:00", d.hour)
    end
    if mode == "day" then return FormatDate(L.DATE_SHORT, t) end
    if mode == "week" then return L.WEEK_SHORT:format((ISOWeek(t))) end
    if mode == "month" then return format("%s %02d", L.MONTHS[d.month], d.year % 100) end
    return tostring(d.year)
end

local function LongLabel(mode, t, i)
    if mode == "hourofday" then return L.TIME_RANGE:format(i - 1, i % 24) .. " " .. L.ALL_DAYS end
    if mode == "weekday" then return L.WEEKDAYS_LONG[i] .. " " .. L.ALL_WEEKS end
    local d = date("*t", t)
    if mode == "hour" then
        return format("%s, %s, %s", L.WEEKDAYS[WeekdayIndex(d)], FormatDate(L.DATE, t), L.TIME_RANGE:format(d.hour, (d.hour + 1) % 24))
    end
    if mode == "day" then return L.WEEKDAYS_LONG[WeekdayIndex(d)] .. ", " .. FormatDate(L.DATE, t) end
    if mode == "week" then
        return format("%s (%s - %s)", L.WEEK_LONG:format(ISOWeek(t)), FormatDate(L.DATE_SHORT, t), FormatDate(L.DATE_SHORT, t + 6 * DAY + DAY / 2))
    end
    if mode == "month" then return L.MONTHS_LONG[d.month] .. " " .. d.year end
    return tostring(d.year)
end

local function RangeText(data)
    local mode, s = data.mode.key, data.starts
    if not s then return L.WHOLE_PERIOD end
    local first, last, stop = s[1], s[data.n], s[data.n + 1]
    if mode == "hour" then
        return FormatDate(L.DATE_SHORT, first) .. date(" %H:00", first) .. " - " .. FormatDate(L.DATE_SHORT, stop) .. date(" %H:00", stop)
    end
    if mode == "day" or mode == "week" then return FormatDate(L.DATE, first) .. " - " .. FormatDate(L.DATE, stop - DAY / 2) end
    if mode == "month" then return ShortLabel("month", first) .. " - " .. ShortLabel("month", last) end
    return date("%Y", first) .. " - " .. date("%Y", last)
end

---------------------------------------------------------------------------
-- Aggregation
---------------------------------------------------------------------------

local function BarCount(mode)
    if mode.static then return mode.static end
    return max(mode.min, min(mode.max, view.counts[mode.key] or mode.default))
end

local function FirstStart(mode, n, off)
    return PeriodShift(mode.key, PeriodStart(mode.key, time()), -(n - 1) - off)
end

local function IsValidRange(mode, n, off)
    local first = FirstStart(mode, n, off)
    return first and first >= MIN_TIME
end

local function BuildData()
    local mode = MODE_BY_KEY[view.mode] or MODE_BY_KEY.day
    local n = BarCount(mode)
    local starts
    if not mode.static then
        local first = FirstStart(mode, n, offset)
        starts = {}
        for i = 1, n + 1 do starts[i] = PeriodShift(mode.key, first, i - 1) end
    end

    local buckets = {}
    for i = 1, n do buckets[i] = { total = 0, chars = {} } end

    for key, c in pairs(ns.db.chars) do
        if view.char == "ALL" or view.char == key then
            for h, cnt in pairs(c.hours) do
                local t = h * 3600
                local i
                if mode.key == "hourofday" then
                    i = date("*t", t).hour + 1
                elseif mode.key == "weekday" then
                    i = WeekdayIndex(date("*t", t))
                elseif t >= starts[1] and t < starts[n + 1] then
                    local lo, hi = 1, n
                    while lo < hi do
                        local mid = floor((lo + hi + 1) / 2)
                        if starts[mid] <= t then lo = mid else hi = mid - 1 end
                    end
                    i = lo
                end
                if i then
                    local b = buckets[i]
                    b.total = b.total + cnt
                    b.chars[key] = (b.chars[key] or 0) + cnt
                end
            end
        end
    end

    return { mode = mode, n = n, starts = starts, buckets = buckets }
end

local function SelectionTotal()
    if view.char == "ALL" then return ns.AccountTotal() end
    local c = ns.db.chars[view.char]
    return c and c.total or 0
end

local function SelectionName()
    if view.char == "ALL" then return L.ALL_CHARS end
    return ns.CharDisplayName(view.char, ns.db.chars[view.char])
end

local function BarColor()
    if view.char ~= "ALL" then
        local c = ns.db.chars[view.char]
        local color = c and c.class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[c.class]
        if color then return color.r, color.g, color.b end
    end
    return 1, 0.82, 0
end

local function NiceStep(x)
    if x <= 1 then return 1 end
    local p = 10 ^ floor(math.log10(x))
    for _, f in ipairs({ 1, 2, 5, 10 }) do
        if f * p >= x then return f * p end
    end
    return 10 * p
end

local function Jumps(n)
    return L.JUMPS(n, ns.FormatNumber(n))
end

local function White(s)
    return "|cffffffff" .. s .. "|r"
end

---------------------------------------------------------------------------
-- Window
---------------------------------------------------------------------------

local frame, graph, emptyText, rangeText, charButton, charList, prevButton, nextButton, nowButton
local summary1, summary2
local bars, xLabels, yLabels, listButtons = {}, {}, {}, {}
local modeButtons = {}
local refreshPending

local Refresh

local function ShowBarTooltip(bar)
    if not current then return end
    local i = bar.index
    local b = current.buckets[i]
    bar.hl:Show()
    GameTooltip:SetOwner(bar, "ANCHOR_TOP")
    GameTooltip:AddLine(LongLabel(current.mode.key, current.starts and current.starts[i], i), 1, 1, 1)
    GameTooltip:AddLine(Jumps(b.total))
    if view.char == "ALL" and b.total > 0 then
        local keys = {}
        for key in pairs(b.chars) do keys[#keys + 1] = key end
        table.sort(keys, function(a, c) return b.chars[a] > b.chars[c] end)
        GameTooltip:AddLine(" ")
        for _, key in ipairs(keys) do
            GameTooltip:AddDoubleLine(ns.CharDisplayName(key, ns.db.chars[key]), ns.FormatNumber(b.chars[key]), 1, 1, 1, 1, 1, 1)
        end
    end
    GameTooltip:Show()
end

local function Pan(delta)
    local mode = MODE_BY_KEY[view.mode]
    if mode.static then return end
    local n = BarCount(mode)
    local target = max(0, offset + delta)
    while target > offset and not IsValidRange(mode, n, target) do target = target - 1 end
    if target ~= offset then
        offset = target
        Refresh()
    end
end

local function OnMouseWheel(_, delta)
    local mode = MODE_BY_KEY[view.mode]
    if mode.static then return end
    if IsShiftKeyDown() then
        Pan(delta)
        return
    end
    local n = BarCount(mode)
    local step = max(1, floor(n * 0.2))
    local newN = max(mode.min, min(mode.max, n - delta * step))
    if newN ~= n and IsValidRange(mode, newN, offset) then
        view.counts[mode.key] = newN
        Refresh()
    end
end

local function GetBar(i)
    local bar = bars[i]
    if bar then return bar end
    bar = CreateFrame("Frame", nil, graph)
    bar:EnableMouse(true)
    bar:EnableMouseWheel(true)
    bar.hl = bar:CreateTexture(nil, "BACKGROUND")
    bar.hl:SetAllPoints()
    bar.hl:SetColorTexture(1, 1, 1, 0.08)
    bar.hl:Hide()
    bar.fill = bar:CreateTexture(nil, "ARTWORK")
    bar.fill:SetPoint("BOTTOM")
    bar:SetScript("OnEnter", ShowBarTooltip)
    bar:SetScript("OnLeave", function(self)
        self.hl:Hide()
        GameTooltip:Hide()
    end)
    bar:SetScript("OnMouseWheel", OnMouseWheel)
    bars[i] = bar
    return bar
end

local function GetXLabel(i)
    local fs = xLabels[i]
    if not fs then
        fs = graph:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        xLabels[i] = fs
    end
    return fs
end

Refresh = function()
    if not frame or not frame:IsShown() then return end
    local data = BuildData()
    current = data
    local mode, n, buckets = data.mode, data.n, data.buckets

    for _, btn in ipairs(modeButtons) do
        if btn.mode == mode then btn:LockHighlight() else btn:UnlockHighlight() end
    end
    charButton:SetText(SelectionName())
    rangeText:SetText(RangeText(data))
    prevButton:SetShown(not mode.static)
    nextButton:SetShown(not mode.static)
    nowButton:SetShown(not mode.static)
    if not mode.static then
        if IsValidRange(mode, n, offset + 1) then prevButton:Enable() else prevButton:Disable() end
        if offset > 0 then nextButton:Enable(); nowButton:Enable() else nextButton:Disable(); nowButton:Disable() end
    end

    local sum, peak, peakIdx = 0, 0, nil
    for i, b in ipairs(buckets) do
        sum = sum + b.total
        if b.total > peak then peak, peakIdx = b.total, i end
    end

    -- y axis
    local step = NiceStep(peak / 4)
    local top = step * 4
    for k = 1, 4 do yLabels[k]:SetText(ns.FormatNumber(step * k)) end

    -- bars
    local colW = GRAPH_W / n
    local barW = max(1, colW * 0.75)
    local r, g, b = BarColor()
    for i = 1, n do
        local bar = GetBar(i)
        bar:ClearAllPoints()
        bar:SetPoint("BOTTOMLEFT", graph, "BOTTOMLEFT", (i - 1) * colW, 0)
        bar:SetSize(colW, GRAPH_H)
        bar.index = i
        local v = buckets[i].total
        if v > 0 then
            bar.fill:SetSize(barW, max(1, GRAPH_H * v / top))
            bar.fill:SetColorTexture(r, g, b, i == peakIdx and 1 or 0.7)
            bar.fill:Show()
        else
            bar.fill:Hide()
        end
        bar:Show()
    end
    for i = n + 1, #bars do bars[i]:Hide() end

    -- x axis labels: the newest bar is always labelled
    local stride, labelled = ceil(n / 10), 0
    if mode.key == "hourofday" then stride = 2 elseif mode.key == "weekday" then stride = 1 end
    for i = 1, n do
        local show
        if mode.static then show = (i - 1) % stride == 0 else show = (n - i) % stride == 0 end
        if show then
            labelled = labelled + 1
            local fs = GetXLabel(labelled)
            fs:ClearAllPoints()
            fs:SetPoint("TOP", graph, "BOTTOMLEFT", (i - 0.5) * colW, -4)
            fs:SetText(ShortLabel(mode.key, data.starts and data.starts[i], i))
            fs:Show()
        end
    end
    for i = labelled + 1, #xLabels do xLabels[i]:Hide() end

    emptyText:SetShown(sum == 0)

    -- summary
    local line = L.IN_RANGE:format(White(Jumps(sum)))
    if not mode.static then
        local avg = format("%.1f", sum / n):gsub("%.", L.DECIMAL)
        line = line .. "     " .. L.AVG_PER:format(mode.unit, White(avg))
    end
    if peakIdx then
        line = line .. "     " .. L.PEAK:format(White(ns.FormatNumber(peak)), LongLabel(mode.key, data.starts and data.starts[peakIdx], peakIdx))
    end
    summary1:SetText(line)
    summary2:SetText(L.TOTALS:format(SelectionName(), White(ns.FormatNumber(SelectionTotal())),
        White(ns.FormatNumber(ns.char.total)), White(ns.FormatNumber(ns.sessionJumps))))
end

local function GetListButton(i)
    local btn = listButtons[i]
    if btn then return btn end
    btn = CreateFrame("Button", nil, charList)
    btn:SetSize(270, 18)
    btn:SetPoint("TOPLEFT", 6, -6 - (i - 1) * 18)
    btn:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    btn.check = btn:CreateTexture(nil, "ARTWORK")
    btn.check:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
    btn.check:SetSize(16, 16)
    btn.check:SetPoint("LEFT", 2, 0)
    btn.name = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    btn.name:SetPoint("LEFT", 20, 0)
    btn.count = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    btn.count:SetPoint("RIGHT", -4, 0)
    btn:SetScript("OnClick", function(self)
        view.char = self.key
        charList:Hide()
        Refresh()
    end)
    listButtons[i] = btn
    return btn
end

local function ToggleCharList()
    if charList:IsShown() then
        charList:Hide()
        return
    end
    local chars = ns.db.chars
    local entries = { { key = "ALL", text = L.ALL_CHARS, total = ns.AccountTotal() } }
    local keys = {}
    for key in pairs(chars) do keys[#keys + 1] = key end
    table.sort(keys, function(a, b)
        if chars[a].total ~= chars[b].total then return chars[a].total > chars[b].total end
        return a < b
    end)
    for _, key in ipairs(keys) do
        entries[#entries + 1] = { key = key, text = ns.CharDisplayName(key, chars[key]), total = chars[key].total }
    end
    for i, e in ipairs(entries) do
        local btn = GetListButton(i)
        btn.key = e.key
        btn.name:SetText(e.text)
        btn.count:SetText(ns.FormatNumber(e.total))
        btn.check:SetShown(view.char == e.key)
        btn:Show()
    end
    for i = #entries + 1, #listButtons do listButtons[i]:Hide() end
    charList:SetHeight(#entries * 18 + 12)
    charList:Show()
end

local function CreateWindow()
    frame = CreateFrame("Frame", "JumpCounterFrame", UIParent, "BackdropTemplate")
    frame:SetSize(700, 432)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("HIGH")
    frame:SetToplevel(true)
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
    frame:Hide()
    tinsert(UISpecialFrames, "JumpCounterFrame")

    local header = frame:CreateTexture(nil, "ARTWORK")
    header:SetTexture("Interface\\DialogFrame\\UI-DialogBox-Header")
    header:SetSize(360, 64)
    header:SetPoint("TOP", 0, 12)
    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", header, "TOP", 0, -14)
    title:SetText(L.TITLE)

    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -6, -6)

    -- view modes
    for i, mode in ipairs(MODES) do
        local btn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
        btn:SetSize(90, 22)
        btn:SetPoint("TOPLEFT", 20 + (i - 1) * 94, -32)
        btn:SetText(mode.label)
        btn.mode = mode
        btn:SetScript("OnClick", function()
            view.mode = mode.key
            offset = 0
            Refresh()
        end)
        modeButtons[i] = btn
    end

    -- character selection
    charButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    charButton:SetSize(230, 22)
    charButton:SetPoint("TOPLEFT", 20, -62)
    charButton:SetScript("OnClick", ToggleCharList)

    charList = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    charList:SetWidth(282)
    charList:SetPoint("TOPLEFT", charButton, "BOTTOMLEFT", 0, -2)
    charList:SetFrameStrata("DIALOG")
    charList:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    charList:SetBackdropColor(0, 0, 0, 0.95)
    charList:EnableMouse(true)
    charList:Hide()
    frame:SetScript("OnHide", function() charList:Hide() end)

    -- navigation
    local function PageButton(name, x, onClick)
        local btn = CreateFrame("Button", nil, frame)
        btn:SetSize(26, 26)
        btn:SetPoint("TOPLEFT", x, -60)
        btn:SetNormalTexture("Interface\\Buttons\\UI-SpellbookIcon-" .. name .. "Page-Up")
        btn:SetPushedTexture("Interface\\Buttons\\UI-SpellbookIcon-" .. name .. "Page-Down")
        btn:SetDisabledTexture("Interface\\Buttons\\UI-SpellbookIcon-" .. name .. "Page-Disabled")
        btn:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
        btn:SetScript("OnClick", onClick)
        return btn
    end
    prevButton = PageButton("Prev", 268, function() Pan(BarCount(MODE_BY_KEY[view.mode])) end)
    nextButton = PageButton("Next", 572, function() Pan(-BarCount(MODE_BY_KEY[view.mode])) end)

    rangeText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    rangeText:SetPoint("LEFT", prevButton, "RIGHT", 4, 0)
    rangeText:SetPoint("RIGHT", nextButton, "LEFT", -4, 0)

    nowButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    nowButton:SetSize(80, 22)
    nowButton:SetPoint("TOPLEFT", 600, -62)
    nowButton:SetText(L.NOW)
    nowButton:SetScript("OnClick", function()
        offset = 0
        Refresh()
    end)

    -- graph
    graph = CreateFrame("Frame", nil, frame)
    graph:SetSize(GRAPH_W, GRAPH_H)
    graph:SetPoint("TOPLEFT", 66, -100)
    graph:EnableMouseWheel(true)
    graph:SetScript("OnMouseWheel", OnMouseWheel)

    local bg = graph:CreateTexture(nil, "BACKGROUND", nil, -1)
    bg:SetAllPoints()
    bg:SetColorTexture(0, 0, 0, 0.35)

    for k = 0, 4 do
        local y = GRAPH_H * k / 4
        local line = graph:CreateTexture(nil, "BORDER")
        line:SetColorTexture(1, 1, 1, k == 0 and 0.35 or 0.08)
        line:SetSize(GRAPH_W, 1)
        line:SetPoint("BOTTOMLEFT", 0, y)
        local label = graph:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        label:SetPoint("RIGHT", graph, "BOTTOMLEFT", -6, y)
        label:SetText("0")
        if k > 0 then yLabels[k] = label end
    end

    emptyText = graph:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    emptyText:SetPoint("CENTER")
    emptyText:SetText(L.EMPTY)

    summary1 = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    summary1:SetPoint("TOPLEFT", 22, -364)
    summary1:SetPoint("RIGHT", -22, 0)
    summary1:SetJustifyH("LEFT")
    summary2 = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    summary2:SetPoint("TOPLEFT", 22, -384)
    summary2:SetPoint("RIGHT", -22, 0)
    summary2:SetJustifyH("LEFT")

    local hint = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("BOTTOMRIGHT", -20, 16)
    hint:SetText(L.HINT)

    frame:SetScript("OnShow", Refresh)
end

function ns.ToggleWindow()
    if not frame then CreateWindow() end
    frame:SetShown(not frame:IsShown())
end

function ns.RefreshWindow()
    Refresh()
end

function ns.OnJump()
    ns.UpdateMinimapTooltip()
    if frame and frame:IsShown() and not refreshPending then
        refreshPending = true
        C_Timer.After(0.5, function()
            refreshPending = false
            Refresh()
        end)
    end
end

---------------------------------------------------------------------------
-- Minimap button
---------------------------------------------------------------------------

-- Registered through LibDataBroker + LibDBIcon, so minimap button managers (SexyMap, ...) and
-- LDB displays (Titan Panel, ...) can pick it up.
local ldb = LibStub("LibDataBroker-1.1")
local ldbi = LibStub("LibDBIcon-1.0")
local dataObject
local tooltipOwner -- minimap button or LDB display frame whose tooltip is open

local function MinimapTooltip(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine("JumpCounter")
    GameTooltip:AddDoubleLine(L.TT_THIS_CHAR, ns.FormatNumber(ns.char.total), 1, 1, 1, 1, 1, 1)
    GameTooltip:AddDoubleLine(L.TT_ALL_CHARS, ns.FormatNumber(ns.AccountTotal()), 1, 1, 1, 1, 1, 1)
    GameTooltip:AddDoubleLine(L.TT_SESSION, ns.FormatNumber(ns.sessionJumps), 1, 1, 1, 1, 1, 1)
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(L.TT_LEFT, 0.7, 0.7, 0.7)
    GameTooltip:AddLine(ns.db.announce and L.TT_RIGHT_OFF or L.TT_RIGHT_ON, 0.7, 0.7, 0.7)
    GameTooltip:AddLine(L.TT_DRAG, 0.7, 0.7, 0.7)
    GameTooltip:Show()
end

function ns.UpdateMinimapTooltip()
    if dataObject then dataObject.text = ns.FormatNumber(ns.char.total) end
    if tooltipOwner and GameTooltip:IsOwned(tooltipOwner) then
        MinimapTooltip(tooltipOwner)
    end
end

local function CreateMinimapButton()
    dataObject = ldb:NewDataObject("JumpCounter", {
        type = "data source",
        label = "JumpCounter",
        text = ns.FormatNumber(ns.char.total),
        icon = ICON,
        OnClick = function(self, mouseButton)
            if mouseButton == "RightButton" then
                ns.db.announce = not ns.db.announce
                ns.Print(L.ANNOUNCE:format(ns.db.announce and L.ON or L.OFF))
                MinimapTooltip(self)
            else
                ns.ToggleWindow()
            end
        end,
        OnEnter = function(self)
            tooltipOwner = self
            MinimapTooltip(self)
        end,
        OnLeave = function()
            tooltipOwner = nil
            GameTooltip:Hide()
        end,
    })
    -- LibDBIcon keeps minimapPos/hide in this table
    ldbi:Register("JumpCounter", dataObject, ns.db.minimap)
end

function ns.UpdateMinimapButton()
    if not dataObject then CreateMinimapButton() end
    if ns.db.minimap.hide then ldbi:Hide("JumpCounter") else ldbi:Show("JumpCounter") end
end

function ns.InitUI()
    view = ns.db.view
    if view.char ~= "ALL" and not ns.db.chars[view.char] then view.char = "ALL" end
    if not MODE_BY_KEY[view.mode] then view.mode = "day" end
    -- position of the old self-made button, same angle convention as LibDBIcon
    local mm = ns.db.minimap
    if mm.angle then
        mm.minimapPos = mm.minimapPos or mm.angle
        mm.angle = nil
    end
    ns.UpdateMinimapButton()
end
