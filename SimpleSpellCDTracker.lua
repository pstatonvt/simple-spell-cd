local ADDON_NAME = ...

-------------------------------------------------------------------------------
-- Style
-------------------------------------------------------------------------------
local FONT = STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"
local FLAT = "Interface\\Buttons\\WHITE8x8"
local SPARK = "Interface\\CastingBar\\UI-CastingBar-Spark"
local QUESTION_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"

local ACCENT = { 1.00, 0.49, 0.04 } -- warm orange, matches the logo
local DANGER = { 0.85, 0.25, 0.25 }
local PANEL_BG = { 0.06, 0.06, 0.07, 0.97 }
local PANEL_BORDER = { 0, 0, 0, 1 }
local HEADER_BG = { 0.10, 0.10, 0.12, 1 }
local WIDGET_BG = { 0.13, 0.13, 0.15, 1 }
local WIDGET_BORDER = { 0.30, 0.30, 0.32, 1 }
local TEXT_MAIN = { 0.92, 0.92, 0.92 }
local TEXT_DIM = { 0.58, 0.58, 0.62 }
local UNAVAILABLE = { 0.32, 0.32, 0.35 }

local LIST_ROWS = 8
local ROW_HEIGHT = 24
local MAX_SEARCH_RESULTS = 40

-------------------------------------------------------------------------------
-- Saved variables
-------------------------------------------------------------------------------
local DEFAULTS = {
    barAlpha = 1.0,
    bgAlpha = 0.6,
    barWidth = 200,
    barHeight = 22,
    spacing = 3,
    showIcons = true,
    locked = true,
    hideOutOfCombat = false,
    colors = {
        ready = { 0.15, 0.85, 0.20 },
        cooldown = { 0.90, 0.15, 0.15 },
        warning = { 0.95, 0.85, 0.10 },
    },
    spells = {},
    -- Last full cooldown length seen out of combat, by spell name. Used to run
    -- our own timer in combat, where the game hides real cooldown values.
    knownDurations = {},
}

local function DeepCopy(src)
    if type(src) ~= "table" then return src end
    local out = {}
    for k, v in pairs(src) do
        out[k] = DeepCopy(v)
    end
    return out
end

-- Keys whose saved value replaces the default as a whole instead of being
-- merged slot by slot. Merging a list would bring removed defaults back and
-- copy default fields (like a spell id) onto whatever spell sits in that slot.
local REPLACE_WHOLE = { spells = true }

local function CopyDefaults(src, dst)
    if type(dst) ~= "table" then dst = {} end
    for k, v in pairs(src) do
        if REPLACE_WHOLE[k] then
            if type(dst[k]) ~= "table" then
                dst[k] = DeepCopy(v)
            end
        elseif type(v) == "table" then
            dst[k] = CopyDefaults(v, dst[k])
        elseif dst[k] == nil then
            dst[k] = v
        end
    end
    return dst
end

local LIMITS = {
    barAlpha = { 0.05, 1 },
    bgAlpha = { 0, 1 },
    barWidth = { 120, 320 },
    barHeight = { 14, 40 },
    spacing = { 0, 10 },
}

local function IsNumber(v)
    return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

local function Clamp(v, lo, hi)
    return math.min(hi, math.max(lo, v))
end

local function SanitizeColor(c, default)
    local out = {}
    for i = 1, 3 do
        local v = type(c) == "table" and c[i]
        out[i] = IsNumber(v) and Clamp(v, 0, 1) or default[i]
    end
    return out
end

local function SanitizePosition(p)
    if type(p) ~= "table" or type(p[1]) ~= "string" or not IsNumber(p[3]) or not IsNumber(p[4]) then
        return nil
    end
    if p[2] ~= nil and type(p[2]) ~= "string" then return nil end
    return p
end

-- Fix anything in saved settings that has the wrong type or is out of range,
-- so a damaged or hand-edited settings file can't break the addon.
local function SanitizeDB(db)
    for key, range in pairs(LIMITS) do
        db[key] = IsNumber(db[key]) and Clamp(db[key], range[1], range[2]) or DEFAULTS[key]
    end
    for _, key in ipairs({ "showIcons", "locked", "hideOutOfCombat" }) do
        if type(db[key]) ~= "boolean" then db[key] = DEFAULTS[key] end
    end
    for key, default in pairs(DEFAULTS.colors) do
        db.colors[key] = SanitizeColor(db.colors[key], default)
    end

    local spells, seen = {}, {}
    for _, entry in ipairs(db.spells) do
        if type(entry) == "table" and type(entry.name) == "string" and entry.name ~= "" and not seen[entry.name] then
            seen[entry.name] = true
            table.insert(spells, { name = entry.name, id = IsNumber(entry.id) and entry.id or nil })
        end
    end
    db.spells = spells

    local durations = {}
    for name, d in pairs(db.knownDurations) do
        if seen[name] and IsNumber(d) and d > 0 then durations[name] = d end
    end
    db.knownDurations = durations

    db.position = SanitizePosition(db.position)
    db.optionsPosition = SanitizePosition(db.optionsPosition)
end

local function Print(msg)
    print("|cffff7d0aSimple Spell CD Tracker|r: " .. msg)
end

-------------------------------------------------------------------------------
-- Spell helpers
-------------------------------------------------------------------------------
local function IsSecret(value)
    return issecretvalue ~= nil and issecretvalue(value) and true or false
end

local function GetSpellNameByID(id)
    if C_Spell and C_Spell.GetSpellName then
        return C_Spell.GetSpellName(id)
    end
    if GetSpellInfo then
        return (GetSpellInfo(id))
    end
end

local function GetSpellIcon(entry)
    local key = entry.id or entry.name
    local tex
    if C_Spell and C_Spell.GetSpellTexture then
        tex = C_Spell.GetSpellTexture(key)
    end
    if not tex and GetSpellTexture then
        tex = GetSpellTexture(key)
    end
    return tex or QUESTION_ICON
end

-- Base cooldown in seconds, or nil if unknown.
local function GetBaseCooldown(spellID)
    if not spellID or not GetSpellBaseCooldown then return nil end
    local ms = GetSpellBaseCooldown(spellID)
    if not ms or IsSecret(ms) then return nil end
    return ms / 1000
end

-- Earlier versions merged the default list into saved spells, which could give
-- a spell another spell's id. Drop any id that doesn't match the spell's name.
local function RepairSpellIDs(spells)
    for _, entry in ipairs(spells) do
        if entry.id then
            local idName = GetSpellNameByID(entry.id)
            if idName and idName ~= entry.name then
                entry.id = nil
            end
        end
    end
end

-- False only when the player clearly doesn't have the spell (other spec, not
-- learned yet). Anything we can't check counts as available.
local function IsSpellAvailable(entry)
    local ok, result = pcall(function()
        if entry.id and IsPlayerSpell and IsPlayerSpell(entry.id) then return true end
        if entry.id and IsSpellKnown and IsSpellKnown(entry.id) then return true end
        -- Older clients use a different ID per rank, so also look it up by name.
        if C_Spell and C_Spell.GetSpellInfo then
            if C_Spell.GetSpellInfo(entry.name) then return true end
        elseif GetSpellInfo then
            if GetSpellInfo(entry.name) then return true end
        end
        if not (IsPlayerSpell or IsSpellKnown) then return true end
        return false
    end)
    if not ok or IsSecret(result) then return true end
    return result and true or false
end

local function GetCooldownInfo(spellEntry)
    if GetSpellCooldown then
        local startTime, duration, enabled = GetSpellCooldown(spellEntry.name)
        if (not duration or duration == 0) and spellEntry.id then
            local s2, d2, e2 = GetSpellCooldown(spellEntry.id)
            if d2 and d2 > 0 then
                startTime, duration, enabled = s2, d2, e2
            end
        end
        return startTime or 0, duration or 0, enabled
    end

    if C_Spell and C_Spell.GetSpellCooldown then
        -- Try the saved ID first, then the name (which follows the player's
        -- current rank/version of the spell).
        local info = spellEntry.id and C_Spell.GetSpellCooldown(spellEntry.id)
        if not info or not info.duration or info.duration == 0 then
            info = C_Spell.GetSpellCooldown(spellEntry.name) or info
        end
        if info then
            return info.startTime or 0, info.duration or 0, info.isEnabled
        end
    end

    return 0, 0, 1
end

-- Returns start, duration, enabled when the game lets us read them, or nil when
-- the values are secret (in combat) or the call fails.
local function ReadCooldown(spellEntry)
    local ok, startTime, duration, enabled = pcall(GetCooldownInfo, spellEntry)
    if not ok or IsSecret(startTime) or IsSecret(duration) or IsSecret(enabled) then
        return nil
    end
    return startTime, duration, enabled
end

local function FormatTime(seconds)
    if seconds >= 60 then
        local total = math.ceil(seconds)
        return string.format("%d:%02d", math.floor(total / 60), total % 60)
    elseif seconds >= 10 then
        return string.format("%d", math.ceil(seconds))
    end
    return string.format("%.1f", seconds)
end

local function GetVersion()
    local getMeta = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
    return getMeta and getMeta(ADDON_NAME, "Version")
end

-------------------------------------------------------------------------------
-- UI helpers
-------------------------------------------------------------------------------
local function AddBackdrop(frame, bgColor, borderColor)
    local border = frame:CreateTexture(nil, "BACKGROUND", nil, -8)
    border:SetAllPoints(frame)
    border:SetColorTexture(borderColor[1], borderColor[2], borderColor[3], borderColor[4] or 1)
    local bg = frame:CreateTexture(nil, "BACKGROUND", nil, -7)
    bg:SetPoint("TOPLEFT", frame, "TOPLEFT", 1, -1)
    bg:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -1, 1)
    bg:SetColorTexture(bgColor[1], bgColor[2], bgColor[3], bgColor[4] or 1)
    return bg, border
end

local function CreateText(parent, size, color, flags)
    local fs = parent:CreateFontString(nil, "OVERLAY")
    fs:SetFont(FONT, size, flags or "")
    fs:SetTextColor(color[1], color[2], color[3])
    fs:SetJustifyH("LEFT")
    return fs
end

local function SetTexColor(tex, c, a)
    tex:SetColorTexture(c[1], c[2], c[3], a or c[4] or 1)
end

-------------------------------------------------------------------------------
-- Cooldown bars
-------------------------------------------------------------------------------
local ToggleOptions -- defined after the options panel
local UpdateVisibility -- defined after the options panel

local container = CreateFrame("Frame", "SimpleSpellCDTrackerContainer", UIParent)
container:SetSize(200, 22)
container:SetPoint("CENTER", UIParent, "CENTER", 0, -120)
container:SetMovable(true)
container:SetClampedToScreen(true)
container:RegisterForDrag("LeftButton")
if container.SetDontSavePosition then container:SetDontSavePosition(true) end

-- Shown while the bars are unlocked so there's something to grab.
local moverOutline = container:CreateTexture(nil, "BACKGROUND", nil, -8)
moverOutline:SetPoint("TOPLEFT", container, "TOPLEFT", -5, 5)
moverOutline:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", 5, -5)
SetTexColor(moverOutline, ACCENT, 0.8)
local moverFill = container:CreateTexture(nil, "BACKGROUND", nil, -7)
moverFill:SetPoint("TOPLEFT", container, "TOPLEFT", -4, 4)
moverFill:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", 4, -4)
moverFill:SetColorTexture(0, 0, 0, 0.6)
local moverLabel = CreateText(container, 10, ACCENT, "OUTLINE")
moverLabel:SetPoint("BOTTOM", container, "TOP", 0, 8)
moverLabel:SetText("Simple Spell CD Tracker - drag to move")

-- Positions are stored as { point, relativePoint, x, y } against UIParent.
-- After a drag we always store the frame's top-left corner, so the top edge
-- stays put when the frame changes size (adding spells, changing bar height).
local function ApplyFramePosition(frame, key, defaultPoint, defaultX, defaultY)
    frame:ClearAllPoints()
    local p = SimpleSpellCDTrackerDB[key]
    if type(p) == "table" and p[1] and p[3] and p[4] then
        frame:SetPoint(p[1], UIParent, p[2] or p[1], p[3], p[4])
    else
        frame:SetPoint(defaultPoint, UIParent, defaultPoint, defaultX, defaultY)
    end
end

local function SaveFramePosition(frame, key)
    local left, top = frame:GetLeft(), frame:GetTop()
    if not left or not top then return end
    local scale = frame:GetEffectiveScale() / UIParent:GetEffectiveScale()
    SimpleSpellCDTrackerDB[key] = { "TOPLEFT", "BOTTOMLEFT", left * scale, top * scale }
end

local function ApplyPosition()
    ApplyFramePosition(container, "position", "CENTER", 0, -120)
end

local function SavePosition()
    SaveFramePosition(container, "position")
    ApplyPosition() -- re-anchor at top-left right away
end

local function StartDrag()
    if SimpleSpellCDTrackerDB and not SimpleSpellCDTrackerDB.locked then
        container:StartMoving()
    end
end

local function StopDrag()
    container:StopMovingOrSizing()
    if SimpleSpellCDTrackerDB and not SimpleSpellCDTrackerDB.locked then
        SavePosition()
    end
end

container:SetScript("OnDragStart", StartDrag)
container:SetScript("OnDragStop", StopDrag)

local function UpdateLockState()
    local unlocked = not SimpleSpellCDTrackerDB.locked
    container:EnableMouse(unlocked)
    moverOutline:SetShown(unlocked)
    moverFill:SetShown(unlocked)
    moverLabel:SetShown(unlocked)
    if UpdateVisibility then UpdateVisibility() end
end

local function ShowBarTooltip(owner, item)
    if not item.spell then return end
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    local shown = false
    if item.spell.id and GameTooltip.SetSpellByID then
        shown = pcall(GameTooltip.SetSpellByID, GameTooltip, item.spell.id)
    end
    if not shown then
        GameTooltip:ClearLines()
        GameTooltip:AddLine(item.spell.name, 1, 1, 1)
    end
    if item.available == false then
        GameTooltip:AddLine("You don't currently have this spell.", DANGER[1], DANGER[2], DANGER[3])
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Right-click for options", TEXT_DIM[1], TEXT_DIM[2], TEXT_DIM[3])
    if not SimpleSpellCDTrackerDB.locked then
        GameTooltip:AddLine("Drag to move", TEXT_DIM[1], TEXT_DIM[2], TEXT_DIM[3])
    end
    GameTooltip:Show()
end

local barPool = {}

local function CreateBar()
    local item = {}

    local holder = CreateFrame("Button", nil, container)
    holder:RegisterForClicks("RightButtonUp")
    holder:RegisterForDrag("LeftButton")
    holder:SetScript("OnDragStart", StartDrag)
    holder:SetScript("OnDragStop", StopDrag)
    holder:SetScript("OnClick", function(_, button)
        if button == "RightButton" then ToggleOptions() end
    end)
    holder:SetScript("OnEnter", function(self) ShowBarTooltip(self, item) end)
    holder:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- 1px black frame around icon and bar, also the separator between them.
    item.edge = holder:CreateTexture(nil, "BACKGROUND", nil, -8)
    item.edge:SetAllPoints(holder)

    item.icon = holder:CreateTexture(nil, "ARTWORK")
    item.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    item.cooldown = CreateFrame("Cooldown", nil, holder, "CooldownFrameTemplate")
    item.cooldown:SetAllPoints(item.icon)
    if item.cooldown.SetHideCountdownNumbers then item.cooldown:SetHideCountdownNumbers(true) end
    if item.cooldown.SetDrawEdge then item.cooldown:SetDrawEdge(false) end

    item.bar = CreateFrame("StatusBar", nil, holder)
    item.bar:SetStatusBarTexture(FLAT)
    item.bar:SetMinMaxValues(0, 1)
    item.bar:SetValue(1)

    -- Behind the bar fill, on the holder so bar opacity doesn't affect it.
    item.bg = holder:CreateTexture(nil, "BACKGROUND", nil, -7)
    item.bg:SetAllPoints(item.bar)

    item.shine = item.bar:CreateTexture(nil, "OVERLAY")
    item.shine:SetPoint("TOPLEFT", item.bar, "TOPLEFT")
    item.shine:SetPoint("TOPRIGHT", item.bar, "TOPRIGHT")
    item.shine:SetColorTexture(1, 1, 1, 0.07)

    item.spark = item.bar:CreateTexture(nil, "OVERLAY")
    item.spark:SetTexture(SPARK)
    item.spark:SetBlendMode("ADD")
    item.spark:SetPoint("CENTER", item.bar:GetStatusBarTexture(), "RIGHT", 0, 0)
    item.spark:Hide()

    local textLayer = CreateFrame("Frame", nil, holder)
    textLayer:SetAllPoints(item.bar)
    textLayer:SetFrameLevel(item.bar:GetFrameLevel() + 2)

    item.time = CreateText(textLayer, 11, TEXT_MAIN, "OUTLINE")
    item.time:SetPoint("RIGHT", textLayer, "RIGHT", -6, 0)
    item.time:SetJustifyH("RIGHT")

    item.name = CreateText(textLayer, 11, TEXT_MAIN, "OUTLINE")
    item.name:SetPoint("LEFT", textLayer, "LEFT", 6, 0)
    item.name:SetPoint("RIGHT", item.time, "LEFT", -4, 0)
    if item.name.SetWordWrap then item.name:SetWordWrap(false) end

    item.holder = holder
    return item
end

local function RebuildBars()
    local db = SimpleSpellCDTrackerDB
    local w, h, gap = db.barWidth, db.barHeight, db.spacing
    local count = #db.spells
    local fontSize = math.max(9, math.floor(h * 0.48 + 0.5))

    for i = count + 1, #barPool do
        barPool[i].holder:Hide()
        barPool[i].spell = nil
    end

    container:SetSize(w, math.max(h, count * (h + gap) - gap))

    for i, entry in ipairs(db.spells) do
        local item = barPool[i]
        if not item then
            item = CreateBar()
            barPool[i] = item
        end
        item.spell = entry
        item.cdStart = nil -- force the icon swipe to refresh
        item.available = IsSpellAvailable(entry)

        local holder = item.holder
        holder:SetSize(w, h)
        holder:ClearAllPoints()
        holder:SetPoint("TOPLEFT", container, "TOPLEFT", 0, -((i - 1) * (h + gap)))

        item.edge:SetColorTexture(0, 0, 0, db.bgAlpha)

        item.bar:ClearAllPoints()
        if db.showIcons then
            item.icon:ClearAllPoints()
            item.icon:SetPoint("TOPLEFT", holder, "TOPLEFT", 1, -1)
            item.icon:SetSize(h - 2, h - 2)
            item.icon:SetTexture(GetSpellIcon(entry))
            item.icon:Show()
            item.cooldown:Show()
            item.bar:SetPoint("TOPLEFT", item.icon, "TOPRIGHT", 1, 0)
        else
            item.icon:Hide()
            item.cooldown:Hide()
            item.bar:SetPoint("TOPLEFT", holder, "TOPLEFT", 1, -1)
        end
        item.bar:SetPoint("BOTTOMRIGHT", holder, "BOTTOMRIGHT", -1, 1)

        item.bar:SetAlpha(db.barAlpha)
        item.icon:SetAlpha(db.barAlpha)
        item.cooldown:SetAlpha(db.barAlpha)
        item.shine:SetHeight(math.max(1, (h - 2) / 2))
        item.spark:SetSize(10, h * 1.8)

        item.name:SetFont(FONT, fontSize, "OUTLINE")
        item.time:SetFont(FONT, fontSize, "OUTLINE")
        item.name:SetText(entry.name)

        holder:Show()
    end

    UpdateLockState()
end

-- Called when the spellbook changes (login, spec swap, new spell learned):
-- icons may have loaded and spells may have become available or unavailable.
local function RefreshSpellInfo()
    for i = 1, #SimpleSpellCDTrackerDB.spells do
        local item = barPool[i]
        if item and item.spell then
            item.available = IsSpellAvailable(item.spell)
            if SimpleSpellCDTrackerDB.showIcons then
                item.icon:SetTexture(GetSpellIcon(item.spell))
            end
        end
    end
end

-------------------------------------------------------------------------------
-- Cooldown tracking
-------------------------------------------------------------------------------
-- Active cooldowns by spell name: { start = GetTime(), duration = seconds }.
-- Filled from the game's cooldown data when it's readable, and from our own
-- cast tracking when it isn't (in combat the game returns secret values).
local cdState = {}

local function OnPlayerSpellCast(spellID)
    if not spellID or IsSecret(spellID) then return end
    local castName = GetSpellNameByID(spellID)
    if IsSecret(castName) then castName = nil end
    for _, entry in ipairs(SimpleSpellCDTrackerDB.spells) do
        if entry.id == spellID or (castName and castName == entry.name) then
            local duration = SimpleSpellCDTrackerDB.knownDurations[entry.name] or GetBaseCooldown(spellID)
            if duration and duration > 2 then
                cdState[entry.name] = { start = GetTime(), duration = duration }
            end
        end
    end
end

local function UpdateBars()
    local db = SimpleSpellCDTrackerDB
    local now = GetTime()
    local cReady, cCool, cWarn = db.colors.ready, db.colors.cooldown, db.colors.warning

    for i = 1, #db.spells do
        local item = barPool[i]
        local entry = item and item.spell
        if entry then
            local startTime, duration, enabled = ReadCooldown(entry)
            if startTime then
                local isEnabled = (enabled == 1 or enabled == true or enabled == nil)
                if isEnabled and duration > 2 and startTime > 0 then
                    cdState[entry.name] = { start = startTime, duration = duration }
                    db.knownDurations[entry.name] = duration
                else
                    cdState[entry.name] = nil
                end
            end

            local state = cdState[entry.name]
            local remaining = 0
            if state then
                remaining = state.start + state.duration - now
                if remaining <= 0 then
                    cdState[entry.name] = nil
                    state = nil
                end
            end

            local c
            if item.available == false then
                c = UNAVAILABLE
                item.bar:SetValue(1)
                item.time:SetText("")
                item.spark:Hide()
                item.icon:SetDesaturated(true)
                item.name:SetTextColor(TEXT_DIM[1], TEXT_DIM[2], TEXT_DIM[3])
                if item.cdStart ~= 0 then
                    item.cdStart = 0
                    if item.cooldown.Clear then
                        item.cooldown:Clear()
                    else
                        item.cooldown:SetCooldown(0, 0)
                    end
                end
            elseif state then
                item.name:SetTextColor(TEXT_MAIN[1], TEXT_MAIN[2], TEXT_MAIN[3])
                local progress = math.min(1, math.max(0, 1 - remaining / state.duration))
                c = remaining <= 60 and cWarn or cCool
                item.bar:SetValue(progress)
                item.time:SetText(FormatTime(remaining))
                item.spark:SetShown(progress > 0.005 and progress < 0.995)
                item.icon:SetDesaturated(true)
                if item.cdStart ~= state.start then
                    item.cdStart = state.start
                    item.cooldown:SetCooldown(state.start, state.duration)
                end
            else
                c = cReady
                item.name:SetTextColor(TEXT_MAIN[1], TEXT_MAIN[2], TEXT_MAIN[3])
                item.bar:SetValue(1)
                item.time:SetText("")
                item.spark:Hide()
                item.icon:SetDesaturated(false)
                if item.cdStart ~= 0 then
                    item.cdStart = 0
                    if item.cooldown.Clear then
                        item.cooldown:Clear()
                    else
                        item.cooldown:SetCooldown(0, 0)
                    end
                end
            end

            item.bar:SetStatusBarColor(c[1], c[2], c[3], 1)
            item.bg:SetColorTexture(c[1] * 0.2, c[2] * 0.2, c[3] * 0.2, db.bgAlpha)
        end
    end
end

-------------------------------------------------------------------------------
-- Spell search
-------------------------------------------------------------------------------
-- Calls callback(name, spellID, isPassive) for each spell in the spellbook.
local function ForEachSpellbookSpell(callback)
    if C_SpellBook and C_SpellBook.GetNumSpellBookSkillLines and C_SpellBook.GetSpellBookItemInfo then
        local bank = (Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player) or 0
        for line = 1, C_SpellBook.GetNumSpellBookSkillLines() do
            local info = C_SpellBook.GetSpellBookSkillLineInfo(line)
            if info then
                for slot = info.itemIndexOffset + 1, info.itemIndexOffset + info.numSpellBookItems do
                    local spell = C_SpellBook.GetSpellBookItemInfo(slot, bank)
                    if spell and spell.name and spell.spellID then
                        callback(spell.name, spell.spellID, spell.isPassive)
                    end
                end
            end
        end
        return
    end

    if GetNumSpellTabs and GetSpellTabInfo and GetSpellBookItemName then
        for t = 1, GetNumSpellTabs() do
            local _, _, offset, numEntries = GetSpellTabInfo(t)
            for s = offset + 1, offset + numEntries do
                local name = GetSpellBookItemName(s, "spell")
                if name then
                    local spellID
                    if GetSpellBookItemInfo then
                        local _, id = GetSpellBookItemInfo(s, "spell")
                        spellID = id
                    end
                    local isPassive = IsPassiveSpell and IsPassiveSpell(s, "spell")
                    callback(name, spellID, isPassive)
                end
            end
        end
    end
end

-- Index of every spell ID that has a real cooldown, for searching by name.
-- Building it touches hundreds of thousands of IDs, so it's done a slice per
-- frame in the background (and paused in combat, where names can be hidden).
local INDEX_MAX_ID = 500000
local INDEX_PER_FRAME = 2500
local indexNames, indexIDs, indexSeen = {}, {}, {}
local indexNextID, indexDone = 1, false
local onIndexDone -- set by the options panel

local function IndexSlice()
    local last = math.min(INDEX_MAX_ID, indexNextID + INDEX_PER_FRAME - 1)
    for id = indexNextID, last do
        local name = GetSpellNameByID(id)
        if name and not IsSecret(name) and not indexSeen[name] then
            local base = GetBaseCooldown(id)
            if base and base > 2 then
                indexSeen[name] = true
                indexNames[#indexNames + 1] = name
                indexIDs[#indexIDs + 1] = id
            end
        end
    end
    indexNextID = last + 1
    return indexNextID > INDEX_MAX_ID
end

local indexer = CreateFrame("Frame")
indexer:Hide()
indexer:SetScript("OnUpdate", function(self)
    if InCombatLockdown and InCombatLockdown() then return end
    local ok, finished = pcall(IndexSlice)
    if not ok or finished then
        indexDone = true
        indexSeen = nil
        self:Hide()
        if onIndexDone then pcall(onIndexDone) end
    end
end)

local function StartSpellIndex()
    if not indexDone then indexer:Show() end
end

local function SearchSpells(filterText)
    local results, seen = {}, {}
    local query = string.lower(filterText or "")

    -- 1. Spellbook: with no query, list spells that have a real cooldown.
    ForEachSpellbookSpell(function(name, spellID, isPassive)
        if seen[name] or isPassive then return end
        local base = GetBaseCooldown(spellID)
        local hasCooldown = (not GetSpellBaseCooldown) or (base and base > 0)
        if (query == "" and hasCooldown) or (query ~= "" and string.find(string.lower(name), query, 1, true)) then
            seen[name] = true
            table.insert(results, { name = name, id = spellID })
        end
    end)

    -- 2. Any spell with a cooldown, from the background index, once the query
    --    has 2+ characters.
    if string.len(query) >= 2 then
        for i = 1, #indexNames do
            if #results >= MAX_SEARCH_RESULTS then break end
            local name = indexNames[i]
            if not seen[name] and string.find(string.lower(name), query, 1, true) then
                seen[name] = true
                table.insert(results, { name = name, id = indexIDs[i] })
            end
        end
    end

    table.sort(results, function(a, b) return a.name < b.name end)
    return results
end

-- Returns the results, or nil if the search couldn't run (e.g. the game is
-- hiding spell data in combat).
local function GetSearchableSpells(filterText)
    local ok, results = pcall(SearchSpells, filterText)
    if ok then return results end
    return nil
end

-------------------------------------------------------------------------------
-- Options widgets
-------------------------------------------------------------------------------
local function CreateFlatButton(parent, text, w, h)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(w, h)
    b.bgTex, b.borderTex = AddBackdrop(b, WIDGET_BG, PANEL_BORDER)
    b.label = CreateText(b, 11, TEXT_MAIN)
    b.label:SetPoint("CENTER", b, "CENTER", 0, 0)
    b.label:SetJustifyH("CENTER")
    b.label:SetText(text)
    b.hoverColor = ACCENT
    b:SetScript("OnEnter", function(self)
        if self:IsEnabled() then SetTexColor(self.borderTex, self.hoverColor) end
    end)
    b:SetScript("OnLeave", function(self) SetTexColor(self.borderTex, PANEL_BORDER) end)
    b:SetScript("OnMouseDown", function(self)
        if self:IsEnabled() then self.label:SetPoint("CENTER", self, "CENTER", 1, -1) end
    end)
    b:SetScript("OnMouseUp", function(self) self.label:SetPoint("CENTER", self, "CENTER", 0, 0) end)
    return b
end

local function CreateSectionHeader(parent, text, y, rightInset)
    local fs = CreateText(parent, 10, ACCENT)
    fs:SetPoint("TOPLEFT", parent, "TOPLEFT", 16, y)
    fs:SetText(string.upper(text))
    local line = parent:CreateTexture(nil, "ARTWORK")
    line:SetHeight(1)
    line:SetPoint("LEFT", fs, "RIGHT", 8, 0)
    line:SetPoint("RIGHT", parent, "RIGHT", -(rightInset or 16), 0)
    line:SetColorTexture(1, 1, 1, 0.08)
    return fs
end

local function CreateCheckbox(parent, label, getter, setter)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(120, 18)
    local box = CreateFrame("Frame", nil, b)
    box:SetSize(14, 14)
    box:SetPoint("LEFT", b, "LEFT", 0, 0)
    local _, border = AddBackdrop(box, WIDGET_BG, WIDGET_BORDER)
    local mark = box:CreateTexture(nil, "ARTWORK")
    mark:SetPoint("TOPLEFT", box, "TOPLEFT", 3, -3)
    mark:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", -3, 3)
    SetTexColor(mark, ACCENT)
    local text = CreateText(b, 11, TEXT_MAIN)
    text:SetPoint("LEFT", box, "RIGHT", 8, 0)
    text:SetText(label)
    -- Clickable area ends at the label, so neighbouring checkboxes don't overlap.
    b:SetWidth(14 + 8 + math.ceil(text:GetStringWidth()) + 4)

    function b:Refresh()
        mark:SetShown(getter() and true or false)
    end
    b:SetScript("OnClick", function(self)
        setter(not getter())
        self:Refresh()
    end)
    b:SetScript("OnEnter", function() SetTexColor(border, ACCENT) end)
    b:SetScript("OnLeave", function() SetTexColor(border, WIDGET_BORDER) end)
    b:Refresh()
    return b
end

local function CreateSlider(parent, label, minV, maxV, step, formatter, getter, setter)
    local holder = CreateFrame("Frame", nil, parent)
    holder:SetSize(156, 34)

    local title = CreateText(holder, 11, TEXT_DIM)
    title:SetPoint("TOPLEFT", holder, "TOPLEFT", 0, 0)
    title:SetText(label)
    local valueText = CreateText(holder, 11, TEXT_MAIN)
    valueText:SetPoint("TOPRIGHT", holder, "TOPRIGHT", 0, 0)
    valueText:SetJustifyH("RIGHT")

    local s = CreateFrame("Slider", nil, holder)
    s:SetOrientation("HORIZONTAL")
    s:SetHeight(14)
    s:SetPoint("BOTTOMLEFT", holder, "BOTTOMLEFT", 0, 0)
    s:SetPoint("BOTTOMRIGHT", holder, "BOTTOMRIGHT", 0, 0)
    s:SetHitRectInsets(0, 0, -4, -4)

    local track = s:CreateTexture(nil, "BACKGROUND")
    track:SetHeight(4)
    track:SetPoint("LEFT", s, "LEFT", 0, 0)
    track:SetPoint("RIGHT", s, "RIGHT", 0, 0)
    track:SetColorTexture(0.20, 0.20, 0.22, 1)

    s:SetThumbTexture(FLAT)
    local thumb = s:GetThumbTexture()
    thumb:SetSize(8, 14)
    thumb:SetVertexColor(0.95, 0.95, 0.95, 1)
    thumb:SetDrawLayer("OVERLAY")

    local fill = s:CreateTexture(nil, "ARTWORK")
    fill:SetHeight(4)
    fill:SetPoint("LEFT", track, "LEFT", 0, 0)
    fill:SetPoint("RIGHT", thumb, "CENTER", 0, 0)
    SetTexColor(fill, ACCENT)

    s:SetMinMaxValues(minV, maxV)
    s:SetValueStep(step)
    if s.SetObeyStepOnDrag then s:SetObeyStepOnDrag(true) end

    local function Snap(v)
        return math.floor((v - minV) / step + 0.5) * step + minV
    end

    s:SetValue(getter())
    valueText:SetText(formatter(getter()))

    s:SetScript("OnValueChanged", function(_, v)
        v = Snap(v)
        valueText:SetText(formatter(v))
        if v ~= getter() then setter(v) end
    end)
    s:EnableMouseWheel(true)
    s:SetScript("OnMouseWheel", function(self, delta)
        self:SetValue(math.min(maxV, math.max(minV, self:GetValue() + delta * step)))
    end)

    function holder:Refresh()
        s:SetValue(getter())
        valueText:SetText(formatter(getter()))
    end
    return holder
end

local function CreateColorSwatch(parent, labelText, colorKey)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(100, 20)
    local box = CreateFrame("Frame", nil, b)
    box:SetSize(18, 18)
    box:SetPoint("LEFT", b, "LEFT", 0, 0)
    local _, border = AddBackdrop(box, { 0, 0, 0, 1 }, WIDGET_BORDER)
    local swatch = box:CreateTexture(nil, "ARTWORK")
    swatch:SetPoint("TOPLEFT", box, "TOPLEFT", 2, -2)
    swatch:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", -2, 2)
    local text = CreateText(b, 11, TEXT_MAIN)
    text:SetPoint("LEFT", box, "RIGHT", 8, 0)
    text:SetText(labelText)

    function b:Refresh()
        SetTexColor(swatch, SimpleSpellCDTrackerDB.colors[colorKey])
    end

    local function ApplyColor(r, g, bl)
        SimpleSpellCDTrackerDB.colors[colorKey] = { r, g, bl }
        b:Refresh()
    end

    b:SetScript("OnEnter", function() SetTexColor(border, ACCENT) end)
    b:SetScript("OnLeave", function() SetTexColor(border, WIDGET_BORDER) end)
    b:SetScript("OnClick", function()
        local cur = SimpleSpellCDTrackerDB.colors[colorKey]
        local prevR, prevG, prevB = cur[1], cur[2], cur[3]

        if ColorPickerFrame.SetupColorPickerAndShow then
            ColorPickerFrame:SetupColorPickerAndShow({
                r = prevR,
                g = prevG,
                b = prevB,
                hasOpacity = false,
                swatchFunc = function()
                    ApplyColor(ColorPickerFrame:GetColorRGB())
                end,
                cancelFunc = function()
                    ApplyColor(prevR, prevG, prevB)
                end,
            })
        else
            ColorPickerFrame.func = function()
                ApplyColor(ColorPickerFrame:GetColorRGB())
            end
            ColorPickerFrame.cancelFunc = function()
                ApplyColor(prevR, prevG, prevB)
            end
            ColorPickerFrame.hasOpacity = false
            ColorPickerFrame:SetColorRGB(prevR, prevG, prevB)
            ColorPickerFrame:Show()
        end
    end)

    b:Refresh()
    return b
end

local function FormatPercent(v)
    return string.format("%d%%", math.floor(v * 100 + 0.5))
end

local function FormatPixels(v)
    return string.format("%d px", math.floor(v + 0.5))
end

-------------------------------------------------------------------------------
-- Options panel
-------------------------------------------------------------------------------
local optionsFrame

local function CreateOptionsPanel()
    local db = SimpleSpellCDTrackerDB
    local controls = {}

    local f = CreateFrame("Frame", "SimpleSpellCDTrackerOptions", UIParent)
    f:SetSize(360, 562)
    ApplyFramePosition(f, "optionsPosition", "CENTER", 0, 40)
    f:SetFrameStrata("DIALOG")
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    if f.SetDontSavePosition then f:SetDontSavePosition(true) end -- we save it ourselves
    f:EnableMouse(true)
    f:Hide()
    AddBackdrop(f, PANEL_BG, PANEL_BORDER)
    if UISpecialFrames then table.insert(UISpecialFrames, "SimpleSpellCDTrackerOptions") end

    -- Title bar (drag handle)
    local titleBar = CreateFrame("Frame", nil, f)
    titleBar:SetPoint("TOPLEFT", f, "TOPLEFT", 1, -1)
    titleBar:SetPoint("TOPRIGHT", f, "TOPRIGHT", -1, -1)
    titleBar:SetHeight(32)
    titleBar:EnableMouse(true)
    titleBar:RegisterForDrag("LeftButton")
    titleBar:SetScript("OnDragStart", function() f:StartMoving() end)
    titleBar:SetScript("OnDragStop", function()
        f:StopMovingOrSizing()
        SaveFramePosition(f, "optionsPosition")
        ApplyFramePosition(f, "optionsPosition", "CENTER", 0, 40)
    end)

    local titleBg = titleBar:CreateTexture(nil, "BACKGROUND")
    titleBg:SetAllPoints(titleBar)
    SetTexColor(titleBg, HEADER_BG)
    local accentLine = titleBar:CreateTexture(nil, "ARTWORK")
    accentLine:SetHeight(1)
    accentLine:SetPoint("BOTTOMLEFT", titleBar, "BOTTOMLEFT", 0, 0)
    accentLine:SetPoint("BOTTOMRIGHT", titleBar, "BOTTOMRIGHT", 0, 0)
    SetTexColor(accentLine, ACCENT, 0.8)

    local title = CreateText(titleBar, 14, ACCENT)
    title:SetPoint("LEFT", titleBar, "LEFT", 12, 0)
    title:SetText("Simple Spell CD Tracker")
    local version = GetVersion()
    local subtitle = CreateText(titleBar, 11, TEXT_DIM)
    subtitle:SetPoint("LEFT", title, "RIGHT", 6, -1)
    subtitle:SetText("Options" .. (version and ("   v" .. version) or ""))

    local closeBtn = CreateFlatButton(titleBar, "X", 20, 20)
    closeBtn:SetPoint("RIGHT", titleBar, "RIGHT", -6, 0)
    closeBtn.hoverColor = DANGER
    closeBtn:SetScript("OnClick", function() f:Hide() end)

    -- General
    CreateSectionHeader(f, "General", -46)

    local lockCheck = CreateCheckbox(f, "Lock bars", function() return db.locked end, function(v)
        db.locked = v
        UpdateLockState()
    end)
    lockCheck:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -66)
    table.insert(controls, lockCheck)

    local iconCheck = CreateCheckbox(f, "Show spell icons", function() return db.showIcons end, function(v)
        db.showIcons = v
        RebuildBars()
    end)
    iconCheck:SetPoint("TOPLEFT", f, "TOPLEFT", 112, -66)
    table.insert(controls, iconCheck)

    local combatCheck = CreateCheckbox(f, "Hide out of combat", function() return db.hideOutOfCombat end, function(v)
        db.hideOutOfCombat = v
        UpdateVisibility()
    end)
    combatCheck:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -88)
    table.insert(controls, combatCheck)

    local combatHint = CreateText(f, 10, TEXT_DIM)
    combatHint:SetPoint("LEFT", combatCheck, "RIGHT", 8, 0)
    combatHint:SetText("(always shown while unlocked)")

    local resetBtn = CreateFlatButton(f, "Reset Position", 100, 20)
    resetBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -16, -65)
    resetBtn:SetScript("OnClick", function()
        db.position = nil
        ApplyPosition()
    end)

    -- Appearance
    CreateSectionHeader(f, "Appearance", -122)

    local widthSlider = CreateSlider(f, "Bar Width", 120, 320, 5, FormatPixels,
        function() return db.barWidth end,
        function(v) db.barWidth = v; RebuildBars() end)
    widthSlider:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -140)
    table.insert(controls, widthSlider)

    local heightSlider = CreateSlider(f, "Bar Height", 14, 40, 1, FormatPixels,
        function() return db.barHeight end,
        function(v) db.barHeight = v; RebuildBars() end)
    heightSlider:SetPoint("TOPLEFT", f, "TOPLEFT", 188, -140)
    table.insert(controls, heightSlider)

    local barAlphaSlider = CreateSlider(f, "Bar Opacity", 0.05, 1.0, 0.05, FormatPercent,
        function() return db.barAlpha end,
        function(v) db.barAlpha = v; RebuildBars() end)
    barAlphaSlider:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -182)
    table.insert(controls, barAlphaSlider)

    local bgAlphaSlider = CreateSlider(f, "Background Opacity", 0, 1.0, 0.05, FormatPercent,
        function() return db.bgAlpha end,
        function(v) db.bgAlpha = v; RebuildBars() end)
    bgAlphaSlider:SetPoint("TOPLEFT", f, "TOPLEFT", 188, -182)
    table.insert(controls, bgAlphaSlider)

    -- Colors
    CreateSectionHeader(f, "Colors", -230)
    local swatches = {
        { "Ready", "ready", 16 },
        { "Cooldown", "cooldown", 128 },
        { "Under 60s", "warning", 240 },
    }
    for _, s in ipairs(swatches) do
        local sw = CreateColorSwatch(f, s[1], s[2])
        sw:SetPoint("TOPLEFT", f, "TOPLEFT", s[3], -248)
        table.insert(controls, sw)
    end

    -- Tracked cooldowns
    CreateSectionHeader(f, "Tracked Cooldowns", -284, 16 + 64 + 8)

    local addBtn = CreateFlatButton(f, "+ Add", 64, 20)
    addBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -16, -278)

    local searchBox = CreateFrame("EditBox", nil, f)
    searchBox:SetSize(328, 22)
    searchBox:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -304)
    searchBox:SetAutoFocus(false)
    searchBox:SetFont(FONT, 12, "")
    searchBox:SetTextColor(TEXT_MAIN[1], TEXT_MAIN[2], TEXT_MAIN[3])
    searchBox:SetTextInsets(8, 8, 0, 0)
    searchBox:SetMaxLetters(50)
    local _, searchBorder = AddBackdrop(searchBox, { 0.03, 0.03, 0.04, 1 }, WIDGET_BORDER)
    local placeholder = CreateText(searchBox, 12, TEXT_DIM)
    placeholder:SetPoint("LEFT", searchBox, "LEFT", 8, 0)
    placeholder:SetText("Search spells by name...")
    searchBox:SetScript("OnEditFocusGained", function() SetTexColor(searchBorder, ACCENT) end)
    searchBox:SetScript("OnEditFocusLost", function() SetTexColor(searchBorder, WIDGET_BORDER) end)
    searchBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    searchBox:Hide()

    local list = CreateFrame("Frame", nil, f)
    list:SetSize(328, LIST_ROWS * ROW_HEIGHT)
    list:EnableMouseWheel(true)

    local scrollTrack = list:CreateTexture(nil, "BACKGROUND")
    scrollTrack:SetWidth(3)
    scrollTrack:SetPoint("TOPRIGHT", list, "TOPRIGHT", 0, 0)
    scrollTrack:SetPoint("BOTTOMRIGHT", list, "BOTTOMRIGHT", 0, 0)
    scrollTrack:SetColorTexture(1, 1, 1, 0.05)
    local scrollThumb = list:CreateTexture(nil, "ARTWORK")
    scrollThumb:SetWidth(3)
    SetTexColor(scrollThumb, ACCENT, 0.7)

    local emptyText = CreateText(list, 11, TEXT_DIM)
    emptyText:SetPoint("CENTER", list, "CENTER", 0, 0)
    emptyText:SetJustifyH("CENTER")

    local rows = {}
    for i = 1, LIST_ROWS do
        local row = CreateFrame("Frame", nil, list)
        row:SetSize(322, ROW_HEIGHT - 2)
        row:SetPoint("TOPLEFT", list, "TOPLEFT", 0, -((i - 1) * ROW_HEIGHT))
        row:EnableMouse(true)

        local rbg = row:CreateTexture(nil, "BACKGROUND")
        rbg:SetAllPoints(row)
        SetTexColor(rbg, WIDGET_BG, 0.6)
        local hover = row:CreateTexture(nil, "BORDER")
        hover:SetAllPoints(row)
        hover:SetColorTexture(1, 1, 1, 0.04)
        hover:Hide()
        row:SetScript("OnEnter", function() hover:Show() end)
        row:SetScript("OnLeave", function() hover:Hide() end)

        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(16, 16)
        row.icon:SetPoint("LEFT", row, "LEFT", 4, 0)
        row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

        row.btn = CreateFlatButton(row, "", 60, 18)
        row.btn:SetPoint("RIGHT", row, "RIGHT", -3, 0)

        row.sub = CreateText(row, 10, TEXT_DIM)
        row.sub:SetPoint("RIGHT", row.btn, "LEFT", -8, 0)
        row.sub:SetJustifyH("RIGHT")

        row.text = CreateText(row, 11, TEXT_MAIN)
        row.text:SetPoint("LEFT", row.icon, "RIGHT", 8, 0)
        row.text:SetPoint("RIGHT", row.sub, "LEFT", -6, 0)
        if row.text.SetWordWrap then row.text:SetWordWrap(false) end

        rows[i] = row
    end

    local searchMode, offset, entries = false, 0, db.spells
    local searchFailed = false
    local RefreshList

    local function IsTracked(name)
        for _, sp in ipairs(db.spells) do
            if sp.name == name then return true end
        end
        return false
    end

    local function SetButtonEnabled(btn, enabled)
        if enabled then
            btn:Enable()
            btn.label:SetTextColor(TEXT_MAIN[1], TEXT_MAIN[2], TEXT_MAIN[3])
        else
            btn:Disable()
            btn.label:SetTextColor(TEXT_DIM[1], TEXT_DIM[2], TEXT_DIM[3])
        end
    end

    RefreshList = function()
        local maxOffset = math.max(0, #entries - LIST_ROWS)
        offset = math.min(math.max(0, offset), maxOffset)

        for i = 1, LIST_ROWS do
            local row = rows[i]
            local idx = offset + i
            local entry = entries[idx]
            if entry then
                row.icon:SetTexture(GetSpellIcon(entry))
                row.text:SetText(entry.name)
                row.sub:SetText(entry.id and ("#" .. entry.id) or "")
                if searchMode then
                    local tracked = IsTracked(entry.name)
                    row.btn.label:SetText(tracked and "Added" or "Add")
                    row.btn.hoverColor = ACCENT
                    SetButtonEnabled(row.btn, not tracked)
                    row.btn:SetScript("OnClick", function()
                        if not IsTracked(entry.name) then
                            table.insert(db.spells, { name = entry.name, id = entry.id })
                            RebuildBars()
                        end
                        RefreshList()
                    end)
                else
                    row.btn.label:SetText("Remove")
                    row.btn.hoverColor = DANGER
                    SetButtonEnabled(row.btn, true)
                    row.btn:SetScript("OnClick", function()
                        local removed = table.remove(db.spells, idx)
                        if removed then
                            cdState[removed.name] = nil
                            db.knownDurations[removed.name] = nil
                        end
                        RebuildBars()
                        RefreshList()
                    end)
                end
                row:Show()
            else
                row:Hide()
            end
        end

        if #entries == 0 then
            local msg
            if not searchMode then
                msg = "No cooldowns tracked yet.\nClick + Add to choose spells."
            elseif searchFailed then
                msg = "Spell search isn't available right now.\nTry again out of combat."
            elseif not indexDone and string.len(searchBox:GetText()) >= 2 then
                msg = "Loading the full spell list...\nResults will appear in a few seconds."
            elseif searchBox:GetText() == "" then
                msg = "Type a spell name to search."
            else
                msg = "No matching spells."
            end
            emptyText:SetText(msg)
            emptyText:Show()
        else
            emptyText:Hide()
        end

        if #entries > LIST_ROWS then
            local trackH = list:GetHeight()
            local thumbH = math.max(16, trackH * LIST_ROWS / #entries)
            scrollThumb:SetHeight(thumbH)
            scrollThumb:ClearAllPoints()
            scrollThumb:SetPoint("TOPRIGHT", list, "TOPRIGHT", 0, -((trackH - thumbH) * offset / maxOffset))
            scrollThumb:Show()
            scrollTrack:Show()
        else
            scrollThumb:Hide()
            scrollTrack:Hide()
        end
    end

    local function RunSearch()
        local results = GetSearchableSpells(searchBox:GetText())
        searchFailed = results == nil
        entries = results or {}
        offset = 0
        RefreshList()
    end

    -- When the background index finishes, refresh an open search.
    onIndexDone = function()
        if searchMode and f:IsShown() then RunSearch() end
    end

    local function SetSearchMode(on)
        searchMode = on
        offset = 0
        list:ClearAllPoints()
        if on then
            StartSpellIndex()
            addBtn.label:SetText("Done")
            searchBox:Show()
            searchBox:SetText("")
            searchBox:SetFocus()
            list:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -332)
            RunSearch()
            return
        else
            addBtn.label:SetText("+ Add")
            searchBox:ClearFocus()
            searchBox:Hide()
            list:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -304)
            entries = db.spells
        end
        RefreshList()
    end

    addBtn:SetScript("OnClick", function() SetSearchMode(not searchMode) end)

    list:SetScript("OnMouseWheel", function(_, delta)
        offset = offset - delta
        RefreshList()
    end)

    -- Searching by ID is slow, so wait for typing to pause.
    local searchToken = 0
    searchBox:SetScript("OnTextChanged", function(self)
        placeholder:SetShown(self:GetText() == "")
        if not searchMode then return end
        searchToken = searchToken + 1
        local token = searchToken
        local function Run()
            if token ~= searchToken or not searchMode then return end
            RunSearch()
        end
        if C_Timer and C_Timer.After then
            C_Timer.After(0.25, Run)
        else
            Run()
        end
    end)

    searchBox:SetScript("OnEscapePressed", function(self)
        if self:GetText() ~= "" then
            self:SetText("")
        else
            SetSearchMode(false)
        end
    end)

    local footer = CreateText(f, 10, TEXT_DIM)
    footer:SetPoint("BOTTOM", f, "BOTTOM", 0, 12)
    footer:SetJustifyH("CENTER")
    footer:SetText("Right-click a bar or type /sscd to open this window")

    function f:RefreshControls()
        for _, c in ipairs(controls) do c:Refresh() end
    end

    f:SetScript("OnShow", function(self)
        self:RefreshControls()
        SetSearchMode(false)
        UpdateVisibility() -- preview the bars while configuring
    end)
    f:SetScript("OnHide", function()
        UpdateVisibility()
    end)

    return f
end

ToggleOptions = function()
    if not optionsFrame then return end
    optionsFrame:SetShown(not optionsFrame:IsShown())
end

local inCombat = false

-- With "Hide out of combat" on, the bars show only in combat, plus while
-- unlocked (to position them) or while the options window is open (to see
-- changes). Cooldowns are still tracked while the bars are hidden.
UpdateVisibility = function()
    local db = SimpleSpellCDTrackerDB
    if not db then return end
    local show = not db.hideOutOfCombat
        or inCombat
        or not db.locked
        or (optionsFrame ~= nil and optionsFrame:IsShown())
    container:SetShown(show and true or false)
end

local initialized = false

local function SetLocked(locked)
    SimpleSpellCDTrackerDB.locked = locked
    UpdateLockState()
    if optionsFrame and optionsFrame:IsShown() then optionsFrame:RefreshControls() end
end

SLASH_SIMPLESPELLCD1 = "/sscd"
SLASH_SIMPLESPELLCD2 = "/spellcd"
SlashCmdList.SIMPLESPELLCD = function(msg)
    if not initialized then
        Print("still loading, try again in a moment.")
        return
    end
    local cmd = string.lower((msg or ""):match("^%s*(.-)%s*$"))
    if cmd == "" or cmd == "options" or cmd == "config" then
        ToggleOptions()
    elseif cmd == "lock" then
        SetLocked(true)
        Print("bars locked.")
    elseif cmd == "unlock" then
        SetLocked(false)
        Print("bars unlocked. Drag them to move, then type /sscd lock.")
    elseif cmd == "reset" then
        SimpleSpellCDTrackerDB.position = nil
        ApplyPosition()
        Print("bar position reset.")
    else
        Print("commands:")
        print("  /sscd - open options")
        print("  /sscd lock | unlock - lock or unlock the bars")
        print("  /sscd reset - move the bars back to the default position")
    end
end

-------------------------------------------------------------------------------
-- Events
-------------------------------------------------------------------------------
local function Initialize(eventFrame)
    SimpleSpellCDTrackerDB = CopyDefaults(DEFAULTS, SimpleSpellCDTrackerDB)
    SanitizeDB(SimpleSpellCDTrackerDB)
    RepairSpellIDs(SimpleSpellCDTrackerDB.spells)
    ApplyPosition()
    inCombat = (UnitAffectingCombat and UnitAffectingCombat("player")) and true or false
    optionsFrame = CreateOptionsPanel()
    RebuildBars()
    eventFrame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
    eventFrame:RegisterEvent("SPELLS_CHANGED")
    eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
    eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
    initialized = true
    if #SimpleSpellCDTrackerDB.spells == 0 then
        Print("no spells tracked yet. Type /sscd to add some.")
    end
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "PLAYER_LOGIN" then
        local ok, err = pcall(Initialize, self)
        if not ok then
            Print("failed to load: " .. tostring(err))
        end
    elseif not initialized then
        return
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        local _, _, spellID = ...
        pcall(OnPlayerSpellCast, spellID)
    elseif event == "SPELLS_CHANGED" then
        pcall(RefreshSpellInfo)
    elseif event == "PLAYER_REGEN_DISABLED" then
        inCombat = true
        UpdateVisibility()
    elseif event == "PLAYER_REGEN_ENABLED" then
        inCombat = false
        UpdateVisibility()
    end
end)

-- Update loop (works in and out of combat). It runs on the event frame rather
-- than the bars so cooldowns keep being tracked while the bars are hidden.
-- Errors are caught and reported once in chat instead of 20 times a second.
local elapsedSinceUpdate = 0
local errorReported = false
eventFrame:SetScript("OnUpdate", function(_, elapsed)
    if not initialized then return end
    elapsedSinceUpdate = elapsedSinceUpdate + elapsed
    if elapsedSinceUpdate < 0.05 then return end
    elapsedSinceUpdate = 0

    local ok, err = pcall(UpdateBars)
    if not ok and not errorReported then
        errorReported = true
        Print("error (shown once per session): " .. tostring(err))
    end
end)
