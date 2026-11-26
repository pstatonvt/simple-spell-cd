local ADDON_NAME = ...
local ADDON_TITLE = "Simple Spell CD Tracker"

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

local LIST_ROWS = 7
local ROW_HEIGHT = 24
local MAX_SEARCH_RESULTS = 40
local ALERT_SOUND = (SOUNDKIT and SOUNDKIT.ALARM_CLOCK_WARNING_3) or 12889

-------------------------------------------------------------------------------
-- Saved variables
-------------------------------------------------------------------------------
-- Account-wide: look and behaviour. SimpleSpellCDTrackerDB
local DEFAULTS = {
    barAlpha = 1.0,
    bgAlpha = 0.6,
    barWidth = 200,
    barHeight = 22,
    spacing = 3,
    style = "bars", -- "bars" or "icons"
    reverse = false, -- bars grow upward / icons grow to the left
    showIcons = true,
    locked = true,
    hideOutOfCombat = false,
    onlyOnCooldown = false,
    alertSound = true,
    alertFlash = true,
    colors = {
        ready = { 0.15, 0.85, 0.20 },
        cooldown = { 0.90, 0.15, 0.15 },
        warning = { 0.95, 0.85, 0.10 },
    },
}

-- Per character: what to track. SimpleSpellCDTrackerCharDB
-- Each entry is a spell { name, id, alert } or an item
-- { type = "item", id = itemID, name, spellID = use-effect spell, alert }.
local CHAR_DEFAULTS = {
    spells = {},
    -- Last full cooldown length seen out of combat, by entry key. Used to run
    -- our own timer in combat, where the game hides real cooldown values.
    knownDurations = {},
}

local db, charDB -- set at login

local function DeepCopy(src)
    if type(src) ~= "table" then return src end
    local out = {}
    for k, v in pairs(src) do
        out[k] = DeepCopy(v)
    end
    return out
end

-- Keys whose saved value replaces the default as a whole instead of being
-- merged slot by slot (merging a list would mix default entries into it).
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
local BOOLEANS = { "reverse", "showIcons", "locked", "hideOutOfCombat", "onlyOnCooldown", "alertSound", "alertFlash" }

local function IsNumber(v)
    return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

local function Clamp(v, lo, hi)
    return math.min(hi, math.max(lo, v))
end

local function EntryKey(entry)
    if entry.type == "item" then
        return "item:" .. tostring(entry.id)
    end
    return entry.name
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

-- Returns a clean copy of a tracked list plus the set of keys in it.
local function SanitizeEntries(list)
    local out, seen = {}, {}
    if type(list) ~= "table" then return out, seen end
    for _, e in ipairs(list) do
        if type(e) == "table" and type(e.name) == "string" and e.name ~= "" then
            local clean
            if e.type == "item" then
                if IsNumber(e.id) then
                    clean = { type = "item", id = e.id, name = e.name,
                        spellID = IsNumber(e.spellID) and e.spellID or nil }
                end
            else
                clean = { name = e.name, id = IsNumber(e.id) and e.id or nil }
            end
            if clean then
                clean.alert = e.alert == true or nil
                local key = EntryKey(clean)
                if not seen[key] then
                    seen[key] = true
                    table.insert(out, clean)
                end
            end
        end
    end
    return out, seen
end

-- Fix anything in saved settings that has the wrong type or is out of range,
-- so a damaged or hand-edited settings file can't break the addon.
local function SanitizeDB(d)
    for key, range in pairs(LIMITS) do
        d[key] = IsNumber(d[key]) and Clamp(d[key], range[1], range[2]) or DEFAULTS[key]
    end
    for _, key in ipairs(BOOLEANS) do
        if type(d[key]) ~= "boolean" then d[key] = DEFAULTS[key] end
    end
    if d.style ~= "bars" and d.style ~= "icons" then d.style = DEFAULTS.style end
    for key, default in pairs(DEFAULTS.colors) do
        d.colors[key] = SanitizeColor(d.colors[key], default)
    end
    d.position = SanitizePosition(d.position)
    d.optionsPosition = SanitizePosition(d.optionsPosition)

    -- Before 1.3.0 the tracked list was account-wide. Keep it aside so it can
    -- be handed to the character it belongs to.
    if type(d.spells) == "table" then
        if #d.spells > 0 and type(d.legacy) ~= "table" then
            d.legacy = { spells = d.spells, durations = type(d.knownDurations) == "table" and d.knownDurations or {} }
        end
        d.spells = nil
    end
    d.knownDurations = nil
    if type(d.legacy) ~= "table" or type(d.legacy.spells) ~= "table" then d.legacy = nil end
end

local function SanitizeCharDB(c)
    local spells, seen = SanitizeEntries(c.spells)
    c.spells = spells
    local durations = {}
    for key, d in pairs(c.knownDurations) do
        if seen[key] and IsNumber(d) and d > 0 then durations[key] = d end
    end
    c.knownDurations = durations
    if type(c.migrated) ~= "boolean" then c.migrated = nil end
end

local function Print(msg)
    print("|cffff7d0a" .. ADDON_TITLE .. "|r: " .. msg)
end

-------------------------------------------------------------------------------
-- Game data helpers
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

-- Base cooldown in seconds, or nil if unknown.
local function GetBaseCooldown(spellID)
    if not spellID or not GetSpellBaseCooldown then return nil end
    local ms = GetSpellBaseCooldown(spellID)
    if not ms or IsSecret(ms) then return nil end
    return ms / 1000
end

local function GetItemName(itemID)
    if C_Item and C_Item.GetItemNameByID then
        local name = C_Item.GetItemNameByID(itemID)
        if name then return name end
    end
    if GetItemInfo then
        return (GetItemInfo(itemID))
    end
end

-- The spell an item casts when used, or nil if it has no use effect.
local function GetItemUseSpell(itemID)
    local fn = (C_Item and C_Item.GetItemSpell) or GetItemSpell
    if not fn then return nil end
    local _, spellID = fn(itemID)
    return spellID
end

local function PlayerHasItem(itemID)
    local count = (C_Item and C_Item.GetItemCount) or GetItemCount
    local equipped = (C_Item and C_Item.IsEquippedItem) or IsEquippedItem
    if equipped and equipped(itemID) then return true end
    if count then
        local n = count(itemID)
        return n ~= nil and n > 0
    end
    return true
end

-- True when the player has the spell. With strict = false, anything we can't
-- check counts as available; with strict = true it counts as not available.
local function IsSpellAvailable(entry, strict)
    local ok, result = pcall(function()
        if entry.id and IsPlayerSpell and IsPlayerSpell(entry.id) then return true end
        if entry.id and IsSpellKnown and IsSpellKnown(entry.id) then return true end
        -- Older clients use a different ID per rank, so also look it up by name.
        if C_Spell and C_Spell.GetSpellInfo then
            if C_Spell.GetSpellInfo(entry.name) then return true end
        elseif GetSpellInfo then
            if GetSpellInfo(entry.name) then return true end
        end
        if not (IsPlayerSpell or IsSpellKnown) then return not strict end
        return false
    end)
    if not ok or IsSecret(result) then return not strict end
    return result and true or false
end

local function IsEntryAvailable(entry)
    if entry.type == "item" then
        local ok, has = pcall(PlayerHasItem, entry.id)
        if not ok or IsSecret(has) then return true end
        return has
    end
    return IsSpellAvailable(entry, false)
end

local function GetEntryIcon(entry)
    local ok, tex = pcall(function()
        if entry.type == "item" then
            local fn = (C_Item and C_Item.GetItemIconByID) or GetItemIcon
            return fn and fn(entry.id)
        end
        local key = entry.id or entry.name
        local t
        if C_Spell and C_Spell.GetSpellTexture then t = C_Spell.GetSpellTexture(key) end
        if not t and GetSpellTexture then t = GetSpellTexture(key) end
        return t
    end)
    return (ok and tex) or QUESTION_ICON
end

local function GetCooldownInfo(entry)
    if entry.type == "item" then
        local fn = (C_Container and C_Container.GetItemCooldown) or GetItemCooldown
        if fn then
            local startTime, duration, enabled = fn(entry.id)
            return startTime or 0, duration or 0, enabled
        end
        return 0, 0, 1
    end

    if GetSpellCooldown then
        local startTime, duration, enabled = GetSpellCooldown(entry.name)
        if (not duration or duration == 0) and entry.id then
            local s2, d2, e2 = GetSpellCooldown(entry.id)
            if d2 and d2 > 0 then
                startTime, duration, enabled = s2, d2, e2
            end
        end
        return startTime or 0, duration or 0, enabled
    end

    if C_Spell and C_Spell.GetSpellCooldown then
        -- Try the saved ID first, then the name (which follows the player's
        -- current rank/version of the spell).
        local info = entry.id and C_Spell.GetSpellCooldown(entry.id)
        if not info or not info.duration or info.duration == 0 then
            info = C_Spell.GetSpellCooldown(entry.name) or info
        end
        if info then
            return info.startTime or 0, info.duration or 0, info.isEnabled
        end
    end

    return 0, 0, 1
end

-- Returns start, duration, enabled when the game lets us read them, or nil when
-- the values are secret (in combat) or the call fails.
local function ReadCooldown(entry)
    local ok, startTime, duration, enabled = pcall(GetCooldownInfo, entry)
    if not ok or IsSecret(startTime) or IsSecret(duration) or IsSecret(enabled) then
        return nil
    end
    return startTime, duration, enabled
end

-- Current and max charges for spells with more than one charge, else nil.
local function GetCharges(entry)
    if entry.type == "item" or not entry.id then return nil end
    local ok, cur, max = pcall(function()
        if C_Spell and C_Spell.GetSpellCharges then
            local c = C_Spell.GetSpellCharges(entry.id)
            if c then return c.currentCharges, c.maxCharges end
            return nil
        elseif GetSpellCharges then
            return GetSpellCharges(entry.id)
        end
    end)
    if not ok or IsSecret(cur) or IsSecret(max) or not IsNumber(cur) or not IsNumber(max) or max <= 1 then
        return nil
    end
    return cur, max
end

-- Earlier versions could give a spell another spell's id. Drop any id that
-- doesn't match the spell's name.
local function RepairSpellIDs(list)
    for _, entry in ipairs(list) do
        if entry.type ~= "item" and entry.id then
            local ok, idName = pcall(GetSpellNameByID, entry.id)
            if ok and idName and not IsSecret(idName) and idName ~= entry.name then
                entry.id = nil
            end
        end
    end
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

local function ClearCooldown(cd)
    if cd.Clear then
        cd:Clear()
    else
        cd:SetCooldown(0, 0)
    end
end

-------------------------------------------------------------------------------
-- Frame, position and visibility
-------------------------------------------------------------------------------
local ToggleOptions -- defined after the options panel
local UpdateVisibility -- defined after the options panel
local optionsFrame

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
moverLabel:SetText(ADDON_TITLE .. " - drag to move")

-- The corner that stays fixed as bars are added or hidden: the top-left
-- normally, the bottom-left when bars grow upward, the top-right when icons
-- grow to the left.
local function GetAnchorCorner()
    if db.reverse then
        return db.style == "icons" and "TOPRIGHT" or "BOTTOMLEFT"
    end
    return "TOPLEFT"
end

-- Positions are stored as { point, relativePoint, x, y } against UIParent.
local function ApplyFramePosition(frame, key, defaultPoint, defaultX, defaultY)
    frame:ClearAllPoints()
    local p = db[key]
    if type(p) == "table" and p[1] and p[3] and p[4] then
        frame:SetPoint(p[1], UIParent, p[2] or p[1], p[3], p[4])
    else
        frame:SetPoint(defaultPoint, UIParent, defaultPoint, defaultX, defaultY)
    end
end

local function SaveFramePosition(frame, key, corner)
    corner = corner or "TOPLEFT"
    local x = corner:find("RIGHT") and frame:GetRight() or frame:GetLeft()
    local y = corner:find("BOTTOM") and frame:GetBottom() or frame:GetTop()
    if not x or not y then return end
    local scale = frame:GetEffectiveScale() / UIParent:GetEffectiveScale()
    db[key] = { corner, "BOTTOMLEFT", x * scale, y * scale }
end

local function ApplyPosition()
    ApplyFramePosition(container, "position", "CENTER", 0, -120)
end

-- Save where the bars are right now, using the current fixed corner.
local function SavePosition()
    SaveFramePosition(container, "position", GetAnchorCorner())
    ApplyPosition()
end

local function StartDrag()
    if db and not db.locked then
        container:StartMoving()
    end
end

local function StopDrag()
    container:StopMovingOrSizing()
    if db and not db.locked then
        SavePosition()
    end
end

container:SetScript("OnDragStart", StartDrag)
container:SetScript("OnDragStop", StopDrag)

local function UpdateLockState()
    local unlocked = not db.locked
    container:EnableMouse(unlocked)
    moverOutline:SetShown(unlocked)
    moverFill:SetShown(unlocked)
    moverLabel:SetShown(unlocked)
    if UpdateVisibility then UpdateVisibility() end
end

-- While unlocked or while the options window is open, show every bar so the
-- player can see what they're arranging.
local function IsPreviewing()
    return not db.locked or (optionsFrame ~= nil and optionsFrame:IsShown())
end

-------------------------------------------------------------------------------
-- Bars
-------------------------------------------------------------------------------
-- Active cooldowns by entry key: { start = GetTime(), duration = seconds }.
-- Filled from the game's cooldown data when it's readable, and from our own
-- cast tracking when it isn't (in combat the game returns secret values).
local cdState = {}
local barPool = {}

local function ShowBarTooltip(owner, item)
    local entry = item.spell
    if not entry then return end
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    local shown = false
    if entry.type == "item" then
        if GameTooltip.SetItemByID then
            shown = pcall(GameTooltip.SetItemByID, GameTooltip, entry.id)
        end
    elseif entry.id and GameTooltip.SetSpellByID then
        shown = pcall(GameTooltip.SetSpellByID, GameTooltip, entry.id)
    end
    if not shown then
        GameTooltip:ClearLines()
        GameTooltip:AddLine(entry.name, 1, 1, 1)
    end
    if item.available == false then
        local what = entry.type == "item" and "You don't have this item." or "You don't currently have this spell."
        GameTooltip:AddLine(what, DANGER[1], DANGER[2], DANGER[3])
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Right-click for options", TEXT_DIM[1], TEXT_DIM[2], TEXT_DIM[3])
    if not db.locked then
        GameTooltip:AddLine("Drag to move", TEXT_DIM[1], TEXT_DIM[2], TEXT_DIM[3])
    end
    GameTooltip:Show()
end

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

    -- 1px frame around icon and bar, also the separator between them. In icon
    -- style it takes the state colour.
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

    -- Text and effects sit above the bar and the cooldown swipe.
    local textLayer = CreateFrame("Frame", nil, holder)
    textLayer:SetAllPoints(holder)
    textLayer:SetFrameLevel(holder:GetFrameLevel() + 5)

    item.time = CreateText(textLayer, 11, TEXT_MAIN, "OUTLINE")
    item.name = CreateText(textLayer, 11, TEXT_MAIN, "OUTLINE")
    if item.name.SetWordWrap then item.name:SetWordWrap(false) end
    item.charges = CreateText(textLayer, 10, TEXT_MAIN, "OUTLINE")
    item.charges:SetJustifyH("RIGHT")

    -- Ready flash: a quick white pulse over the whole bar.
    item.flash = textLayer:CreateTexture(nil, "BACKGROUND")
    item.flash:SetAllPoints(holder)
    item.flash:SetColorTexture(1, 1, 1, 1)
    item.flash:SetBlendMode("ADD")
    item.flash:SetAlpha(0)
    local anim = item.flash:CreateAnimationGroup()
    for i = 1, 4 do
        local a = anim:CreateAnimation("Alpha")
        a:SetFromAlpha(i % 2 == 1 and 0 or 0.45)
        a:SetToAlpha(i % 2 == 1 and 0.45 or 0)
        a:SetDuration(0.18)
        a:SetOrder(i)
    end
    anim:SetScript("OnFinished", function() item.flash:SetAlpha(0) end)
    item.flashAnim = anim

    item.holder = holder
    return item
end

-- Position the bars that should be visible. Cheap to call every update: it
-- only moves frames when the visible set changes (or when forced).
local lastLayout
local function LayoutBars(force)
    local list = charDB.spells
    local showAll = not db.onlyOnCooldown or IsPreviewing()
    local visible, sig = {}, { showAll and "a" or "f" }
    for i = 1, #list do
        local item = barPool[i]
        if item and item.spell then
            local show = showAll or (item.available ~= false and cdState[item.key] ~= nil)
            if show then
                visible[#visible + 1] = item
                sig[#sig + 1] = i
            end
            item.holder:SetShown(show)
        end
    end
    local signature = table.concat(sig, ",")
    if not force and signature == lastLayout then return end
    lastLayout = signature

    local iconMode = db.style == "icons"
    local gap = db.spacing
    local w, h = barPool[1] and barPool[1].holder:GetWidth() or db.barWidth, barPool[1] and barPool[1].holder:GetHeight() or db.barHeight
    if not w or w == 0 then w = db.barWidth end
    if not h or h == 0 then h = db.barHeight end
    local corner = GetAnchorCorner()
    local n = math.max(1, #visible)

    if iconMode then
        container:SetSize(n * (w + gap) - gap, h)
    else
        container:SetSize(w, n * (h + gap) - gap)
    end

    for k, item in ipairs(visible) do
        local offset = (k - 1) * ((iconMode and w or h) + gap)
        item.holder:ClearAllPoints()
        if iconMode then
            if corner == "TOPRIGHT" then
                item.holder:SetPoint("TOPRIGHT", container, "TOPRIGHT", -offset, 0)
            else
                item.holder:SetPoint("TOPLEFT", container, "TOPLEFT", offset, 0)
            end
        elseif corner == "BOTTOMLEFT" then
            item.holder:SetPoint("BOTTOMLEFT", container, "BOTTOMLEFT", 0, offset)
        else
            item.holder:SetPoint("TOPLEFT", container, "TOPLEFT", 0, -offset)
        end
    end
end

-- Apply the current settings to every bar (size, style, icons, fonts).
local function ConfigureBars()
    local list = charDB.spells
    local iconMode = db.style == "icons"
    local h = db.barHeight
    local size = iconMode and math.floor(h * 1.4 + 0.5) or h
    local fontSize = iconMode and math.max(9, math.floor(size * 0.36 + 0.5)) or math.max(9, math.floor(h * 0.48 + 0.5))

    for i = #list + 1, #barPool do
        barPool[i].holder:Hide()
        barPool[i].spell = nil
        barPool[i].key = nil
    end

    for i, entry in ipairs(list) do
        local item = barPool[i]
        if not item then
            item = CreateBar()
            barPool[i] = item
        end
        item.spell = entry
        item.key = EntryKey(entry)
        item.cdStart = nil -- force the icon swipe to refresh
        item.wasCooling = nil -- no ready alert right after (re)configuring
        item.available = IsEntryAvailable(entry)

        item.holder:SetSize(iconMode and size or db.barWidth, size)
        item.edge:SetColorTexture(0, 0, 0, db.bgAlpha)

        local showIcon = iconMode or db.showIcons
        item.icon:ClearAllPoints()
        if showIcon then
            item.icon:SetPoint("TOPLEFT", item.holder, "TOPLEFT", 1, -1)
            item.icon:SetSize(size - 2, size - 2)
            item.icon:SetTexture(GetEntryIcon(entry))
            item.icon:Show()
            item.cooldown:Show()
        else
            item.icon:Hide()
            item.cooldown:Hide()
        end

        item.bar:ClearAllPoints()
        item.time:ClearAllPoints()
        item.name:ClearAllPoints()
        if iconMode then
            item.bar:Hide()
            item.bg:Hide()
            item.name:Hide()
            item.time:SetPoint("CENTER", item.icon, "CENTER", 0, 0)
            item.time:SetJustifyH("CENTER")
        else
            if showIcon then
                item.bar:SetPoint("TOPLEFT", item.icon, "TOPRIGHT", 1, 0)
            else
                item.bar:SetPoint("TOPLEFT", item.holder, "TOPLEFT", 1, -1)
            end
            item.bar:SetPoint("BOTTOMRIGHT", item.holder, "BOTTOMRIGHT", -1, 1)
            item.bar:Show()
            item.bg:Show()
            item.name:Show()
            item.time:SetPoint("RIGHT", item.bar, "RIGHT", -6, 0)
            item.time:SetJustifyH("RIGHT")
            item.name:SetPoint("LEFT", item.bar, "LEFT", 6, 0)
            item.name:SetPoint("RIGHT", item.time, "LEFT", -4, 0)
        end

        item.charges:ClearAllPoints()
        item.charges:SetPoint("BOTTOMRIGHT", item.icon, "BOTTOMRIGHT", -1, 2)

        item.bar:SetAlpha(db.barAlpha)
        item.icon:SetAlpha(db.barAlpha)
        item.cooldown:SetAlpha(db.barAlpha)
        item.shine:SetHeight(math.max(1, (h - 2) / 2))
        item.spark:SetSize(10, h * 1.8)

        item.name:SetFont(FONT, fontSize, "OUTLINE")
        item.time:SetFont(FONT, fontSize, "OUTLINE")
        item.charges:SetFont(FONT, math.max(8, fontSize - 1), "OUTLINE")
        item.name:SetText(entry.name)
    end

    LayoutBars(true)
    UpdateLockState()
end

-- Called when the spellbook, bags or equipment change: icons may have loaded
-- and spells/items may have become available or unavailable.
local function RefreshEntryInfo()
    for i = 1, #charDB.spells do
        local item = barPool[i]
        if item and item.spell then
            item.available = IsEntryAvailable(item.spell)
            if item.icon:IsShown() then
                item.icon:SetTexture(GetEntryIcon(item.spell))
            end
            if item.spell.type == "item" and not item.spell.spellID then
                local ok, spellID = pcall(GetItemUseSpell, item.spell.id)
                if ok and IsNumber(spellID) then item.spell.spellID = spellID end
            end
        end
    end
    LayoutBars(true)
end

-------------------------------------------------------------------------------
-- Cooldown tracking
-------------------------------------------------------------------------------
local function OnPlayerSpellCast(spellID)
    if not spellID or IsSecret(spellID) then return end
    local castName = GetSpellNameByID(spellID)
    if IsSecret(castName) then castName = nil end
    for _, entry in ipairs(charDB.spells) do
        local match
        if entry.type == "item" then
            match = entry.spellID == spellID
        else
            match = entry.id == spellID or (castName ~= nil and castName == entry.name)
        end
        if match then
            local key = EntryKey(entry)
            local duration = charDB.knownDurations[key] or GetBaseCooldown(spellID)
            if duration and duration > 2 then
                cdState[key] = { start = GetTime(), duration = duration }
            end
        end
    end
end

local function UpdateBars()
    local now = GetTime()
    local cReady, cCool, cWarn = db.colors.ready, db.colors.cooldown, db.colors.warning
    local iconMode = db.style == "icons"
    local playSound = false

    for i = 1, #charDB.spells do
        local item = barPool[i]
        local entry = item and item.spell
        if entry then
            local key = item.key
            local startTime, duration, enabled = ReadCooldown(entry)
            if startTime then
                local isEnabled = (enabled == 1 or enabled == true or enabled == nil)
                if not isEnabled then
                    -- Cooldown is waiting to start (e.g. a potion used in
                    -- combat): keep whatever we're already showing.
                elseif duration > 2 and startTime > 0 then
                    cdState[key] = { start = startTime, duration = duration }
                    charDB.knownDurations[key] = duration
                else
                    cdState[key] = nil
                end
            end

            local state = cdState[key]
            local remaining = 0
            if state then
                remaining = state.start + state.duration - now
                if remaining <= 0 then
                    cdState[key] = nil
                    state = nil
                end
            end

            -- Ready alert when a cooldown finishes.
            local cooling = state ~= nil
            if item.wasCooling and not cooling and entry.alert and item.available ~= false then
                if db.alertFlash then
                    item.flashAnim:Stop()
                    item.flashAnim:Play()
                end
                if db.alertSound then playSound = true end
            end
            item.wasCooling = cooling

            local charges = GetCharges(entry)
            local nameText = entry.name
            if charges and not item.icon:IsShown() then
                nameText = nameText .. " (" .. charges .. ")"
            end
            item.name:SetText(nameText)
            item.charges:SetText(charges and item.icon:IsShown() and tostring(charges) or "")

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
                    ClearCooldown(item.cooldown)
                end
            elseif state then
                local progress = math.min(1, math.max(0, 1 - remaining / state.duration))
                c = remaining <= 60 and cWarn or cCool
                item.name:SetTextColor(TEXT_MAIN[1], TEXT_MAIN[2], TEXT_MAIN[3])
                item.bar:SetValue(progress)
                item.time:SetText(FormatTime(remaining))
                item.spark:SetShown(not iconMode and progress > 0.005 and progress < 0.995)
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
                    ClearCooldown(item.cooldown)
                end
            end

            if iconMode then
                item.edge:SetColorTexture(c[1], c[2], c[3], db.barAlpha)
            else
                item.bar:SetStatusBarColor(c[1], c[2], c[3], 1)
                item.bg:SetColorTexture(c[1] * 0.2, c[2] * 0.2, c[3] * 0.2, db.bgAlpha)
            end
        end
    end

    if playSound and PlaySound then
        pcall(PlaySound, ALERT_SOUND, "Master")
    end

    LayoutBars(false)
end

-------------------------------------------------------------------------------
-- Search: spells and items
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

-- Calls callback(itemID) for every item the player is wearing or carrying.
local function ForEachOwnedItem(callback)
    if GetInventoryItemID then
        for slot = 1, 19 do
            local id = GetInventoryItemID("player", slot)
            if id then callback(id) end
        end
    end
    local numSlots = (C_Container and C_Container.GetContainerNumSlots) or GetContainerNumSlots
    local itemAt = (C_Container and C_Container.GetContainerItemID) or GetContainerItemID
    if numSlots and itemAt then
        for bag = 0, 4 do
            for slot = 1, numSlots(bag) or 0 do
                local id = itemAt(bag, slot)
                if id then callback(id) end
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

local function SearchEntries(filterText)
    local results, seen = {}, {}
    local query = string.lower(filterText or "")
    local function Matches(name)
        return query == "" or string.find(string.lower(name), query, 1, true) ~= nil
    end

    -- 1. Spellbook: with no query, list spells that have a real cooldown.
    ForEachSpellbookSpell(function(name, spellID, isPassive)
        if seen[name] or isPassive then return end
        local base = GetBaseCooldown(spellID)
        local hasCooldown = (not GetSpellBaseCooldown) or (base and base > 0)
        if (query == "" and hasCooldown) or (query ~= "" and Matches(name)) then
            seen[name] = true
            table.insert(results, { name = name, id = spellID })
        end
    end)

    -- 2. Usable items the player is wearing or carrying.
    ForEachOwnedItem(function(itemID)
        local key = "item:" .. itemID
        if seen[key] then return end
        local spellID = GetItemUseSpell(itemID)
        if not spellID then return end
        local name = GetItemName(itemID)
        if name and Matches(name) then
            seen[key] = true
            table.insert(results, { type = "item", id = itemID, name = name, spellID = spellID })
        end
    end)

    -- 3. Any spell with a cooldown, from the background index, once the query
    --    has 2+ characters.
    if string.len(query) >= 2 then
        for i = 1, #indexNames do
            if #results >= MAX_SEARCH_RESULTS then break end
            local name = indexNames[i]
            if not seen[name] and Matches(name) then
                seen[name] = true
                table.insert(results, { name = name, id = indexIDs[i] })
            end
        end
    end

    table.sort(results, function(a, b) return a.name < b.name end)
    return results
end

-- Returns the results, or nil if the search couldn't run (e.g. the game is
-- hiding data in combat).
local function GetSearchResults(filterText)
    local ok, results = pcall(SearchEntries, filterText)
    if ok then return results end
    return nil
end

-------------------------------------------------------------------------------
-- Options widgets
-------------------------------------------------------------------------------
local function ShowTooltip(owner, text)
    if not text then return end
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    GameTooltip:SetText(text, 1, 1, 1, 1, true)
    GameTooltip:Show()
end

local function CreateFlatButton(parent, text, w, h)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(w, h)
    b.bgTex, b.borderTex = AddBackdrop(b, WIDGET_BG, PANEL_BORDER)
    b.label = CreateText(b, 11, TEXT_MAIN)
    b.label:SetPoint("CENTER", b, "CENTER", 0, 0)
    b.label:SetJustifyH("CENTER")
    b.label:SetText(text)
    b.hoverColor = ACCENT
    b.restColor = PANEL_BORDER
    b:SetScript("OnEnter", function(self)
        if self:IsEnabled() then SetTexColor(self.borderTex, self.hoverColor) end
        ShowTooltip(self, self.tooltip)
    end)
    b:SetScript("OnLeave", function(self)
        SetTexColor(self.borderTex, self.restColor)
        GameTooltip:Hide()
    end)
    b:SetScript("OnMouseDown", function(self)
        if self:IsEnabled() then self.label:SetPoint("CENTER", self, "CENTER", 1, -1) end
    end)
    b:SetScript("OnMouseUp", function(self) self.label:SetPoint("CENTER", self, "CENTER", 0, 0) end)
    return b
end

local function SetButtonEnabled(btn, enabled)
    if enabled then
        btn:Enable()
        btn.label:SetTextColor(TEXT_MAIN[1], TEXT_MAIN[2], TEXT_MAIN[3])
    else
        btn:Disable()
        btn.label:SetTextColor(TEXT_DIM[1], TEXT_DIM[2], TEXT_DIM[3])
    end
    if btn.arrow then
        local c = enabled and TEXT_MAIN or UNAVAILABLE
        for _, t in ipairs(btn.arrow) do SetTexColor(t, c) end
    end
end

-- Small arrow drawn from flat strips, so it looks the same on every client.
local function CreateArrowButton(parent, up)
    local b = CreateFlatButton(parent, "", 18, 18)
    b.arrow = {}
    for i = 1, 4 do
        local t = b:CreateTexture(nil, "ARTWORK")
        t:SetSize(i * 2 - 1, 1)
        t:SetPoint("CENTER", b, "CENTER", 0, up and (2 - i) or (i - 3))
        SetTexColor(t, TEXT_MAIN)
        b.arrow[i] = t
    end
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

local function CreateCheckbox(parent, label, getter, setter, tooltip)
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
    b:SetScript("OnEnter", function(self)
        SetTexColor(border, ACCENT)
        ShowTooltip(self, tooltip)
    end)
    b:SetScript("OnLeave", function()
        SetTexColor(border, WIDGET_BORDER)
        GameTooltip:Hide()
    end)
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
        SetTexColor(swatch, db.colors[colorKey])
    end

    local function ApplyColor(r, g, bl)
        db.colors[colorKey] = SanitizeColor({ r, g, bl }, DEFAULTS.colors[colorKey])
        b:Refresh()
    end

    b:SetScript("OnEnter", function() SetTexColor(border, ACCENT) end)
    b:SetScript("OnLeave", function() SetTexColor(border, WIDGET_BORDER) end)
    b:SetScript("OnClick", function()
        local cur = db.colors[colorKey]
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

-- Two-or-more-way choice shown as joined buttons; the selected one is lit.
local function CreateSegmented(parent, options, getter, setter)
    local holder = CreateFrame("Frame", nil, parent)
    holder:SetSize(#options * 52, 20)
    local buttons = {}
    for i, opt in ipairs(options) do
        local b = CreateFlatButton(holder, opt.label, 52, 20)
        b:SetPoint("LEFT", holder, "LEFT", (i - 1) * 51, 0)
        b:SetScript("OnClick", function()
            if getter() ~= opt.value then
                setter(opt.value)
                holder:Refresh()
            end
        end)
        buttons[i] = b
    end
    function holder:Refresh()
        for i, opt in ipairs(options) do
            local b = buttons[i]
            local on = getter() == opt.value
            b.restColor = on and ACCENT or PANEL_BORDER
            SetTexColor(b.borderTex, b.restColor)
            local c = on and ACCENT or TEXT_MAIN
            b.label:SetTextColor(c[1], c[2], c[3])
        end
    end
    holder:Refresh()
    return holder
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
local function CreateOptionsPanel()
    local controls = {}

    local f = CreateFrame("Frame", "SimpleSpellCDTrackerOptions", UIParent)
    f:SetSize(360, 576)
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
    title:SetText(ADDON_TITLE)
    local version = GetVersion()
    local subtitle = CreateText(titleBar, 11, TEXT_DIM)
    subtitle:SetPoint("LEFT", title, "RIGHT", 6, -1)
    subtitle:SetText("Options" .. (version and ("   v" .. version) or ""))

    local closeBtn = CreateFlatButton(titleBar, "X", 20, 20)
    closeBtn:SetPoint("RIGHT", titleBar, "RIGHT", -6, 0)
    closeBtn.hoverColor = DANGER
    closeBtn:SetScript("OnClick", function() f:Hide() end)

    local function AddCheckbox(label, key, x, y, onChange, tooltip)
        local cb = CreateCheckbox(f, label, function() return db[key] end, function(v)
            db[key] = v
            if onChange then onChange() end
        end, tooltip)
        cb:SetPoint("TOPLEFT", f, "TOPLEFT", x, y)
        table.insert(controls, cb)
        return cb
    end

    -- General
    CreateSectionHeader(f, "General", -46)

    AddCheckbox("Lock bars", "locked", 16, -66, UpdateLockState,
        "Untick to drag the bars somewhere else.")
    AddCheckbox("Show spell icons", "showIcons", 112, -66, ConfigureBars,
        "Show the spell or item icon at the left of each bar.")

    local resetBtn = CreateFlatButton(f, "Reset Position", 100, 20)
    resetBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -16, -65)
    resetBtn:SetScript("OnClick", function()
        db.position = nil
        ApplyPosition()
    end)

    AddCheckbox("Hide out of combat", "hideOutOfCombat", 16, -88, function() UpdateVisibility() end,
        "Only show the bars in combat.\nThey still show while unlocked or while this window is open.")
    AddCheckbox("Show only on cooldown", "onlyOnCooldown", 160, -88, function() LayoutBars(true) end,
        "Hide bars for spells that are ready.\nAll bars still show while unlocked or while this window is open.")

    AddCheckbox("Alert sound", "alertSound", 16, -110, nil,
        "Play a sound when a cooldown with alerts on becomes ready.\nTurn alerts on per spell in the list below.")
    AddCheckbox("Alert flash", "alertFlash", 112, -110, nil,
        "Flash the bar when a cooldown with alerts on becomes ready.\nTurn alerts on per spell in the list below.")

    -- Appearance
    CreateSectionHeader(f, "Appearance", -140)

    local styleLabel = CreateText(f, 11, TEXT_DIM)
    styleLabel:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -162)
    styleLabel:SetText("Style")
    local style = CreateSegmented(f, { { label = "Bars", value = "bars" }, { label = "Icons", value = "icons" } },
        function() return db.style end,
        function(v)
            db.style = v
            ConfigureBars()
            SavePosition() -- keep the fixed corner where it is for the new style
        end)
    style:SetPoint("TOPLEFT", f, "TOPLEFT", 52, -158)
    table.insert(controls, style)

    AddCheckbox("Reverse direction", "reverse", 188, -159, function()
        SavePosition() -- re-anchor on the new fixed corner without moving
        LayoutBars(true)
    end, "Bars grow upward instead of down.\nIcons grow to the left instead of right.")

    local function AddSlider(label, key, x, y, minV, maxV, step, formatter)
        local s = CreateSlider(f, label, minV, maxV, step, formatter,
            function() return db[key] end,
            function(v) db[key] = v; ConfigureBars() end)
        s:SetPoint("TOPLEFT", f, "TOPLEFT", x, y)
        table.insert(controls, s)
    end
    AddSlider("Bar Width", "barWidth", 16, -186, 120, 320, 5, FormatPixels)
    AddSlider("Bar / Icon Size", "barHeight", 188, -186, 14, 40, 1, FormatPixels)
    AddSlider("Bar Opacity", "barAlpha", 16, -228, 0.05, 1.0, 0.05, FormatPercent)
    AddSlider("Background Opacity", "bgAlpha", 188, -228, 0, 1.0, 0.05, FormatPercent)

    -- Colors
    CreateSectionHeader(f, "Colors", -276)
    local swatches = {
        { "Ready", "ready", 16 },
        { "Cooldown", "cooldown", 128 },
        { "Under 60s", "warning", 240 },
    }
    for _, s in ipairs(swatches) do
        local sw = CreateColorSwatch(f, s[1], s[2])
        sw:SetPoint("TOPLEFT", f, "TOPLEFT", s[3], -294)
        table.insert(controls, sw)
    end

    -- Tracked cooldowns
    CreateSectionHeader(f, "Tracked Cooldowns", -330, 16 + 64 + 8)

    local addBtn = CreateFlatButton(f, "+ Add", 64, 20)
    addBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -16, -324)

    local searchBox = CreateFrame("EditBox", nil, f)
    searchBox:SetSize(328, 22)
    searchBox:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -350)
    searchBox:SetAutoFocus(false)
    searchBox:SetFont(FONT, 12, "")
    searchBox:SetTextColor(TEXT_MAIN[1], TEXT_MAIN[2], TEXT_MAIN[3])
    searchBox:SetTextInsets(8, 8, 0, 0)
    searchBox:SetMaxLetters(50)
    local _, searchBorder = AddBackdrop(searchBox, { 0.03, 0.03, 0.04, 1 }, WIDGET_BORDER)
    local placeholder = CreateText(searchBox, 12, TEXT_DIM)
    placeholder:SetPoint("LEFT", searchBox, "LEFT", 8, 0)
    placeholder:SetText("Search spells and items...")
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

        row.btn = CreateFlatButton(row, "", 56, 18)
        row.btn:SetPoint("RIGHT", row, "RIGHT", -3, 0)

        row.downBtn = CreateArrowButton(row, false)
        row.downBtn:SetPoint("RIGHT", row.btn, "LEFT", -3, 0)
        row.downBtn.tooltip = "Move down"
        row.upBtn = CreateArrowButton(row, true)
        row.upBtn:SetPoint("RIGHT", row.downBtn, "LEFT", -2, 0)
        row.upBtn.tooltip = "Move up"
        row.alertBtn = CreateFlatButton(row, "Alert", 40, 18)
        row.alertBtn:SetPoint("RIGHT", row.upBtn, "LEFT", -3, 0)
        row.alertBtn.tooltip = "Alert when this cooldown is ready\n(sound and/or flash, set under General)"

        row.sub = CreateText(row, 10, TEXT_DIM)
        row.sub:SetPoint("RIGHT", row.btn, "LEFT", -8, 0)
        row.sub:SetJustifyH("RIGHT")

        row.text = CreateText(row, 11, TEXT_MAIN)
        if row.text.SetWordWrap then row.text:SetWordWrap(false) end

        rows[i] = row
    end

    local searchMode, offset, entries = false, 0, charDB.spells
    local searchFailed = false
    local RefreshList

    local function IsTracked(entry)
        local key = EntryKey(entry)
        for _, e in ipairs(charDB.spells) do
            if EntryKey(e) == key then return true end
        end
        return false
    end

    local function ListChanged()
        charDB.migrated = true -- the player has their own list now
        ConfigureBars()
        RefreshList()
    end

    local function SetAlertLook(btn, on)
        btn.restColor = on and ACCENT or PANEL_BORDER
        SetTexColor(btn.borderTex, btn.restColor)
        local c = on and ACCENT or TEXT_DIM
        btn.label:SetTextColor(c[1], c[2], c[3])
    end

    RefreshList = function()
        if not searchMode then entries = charDB.spells end
        local maxOffset = math.max(0, #entries - LIST_ROWS)
        offset = math.min(math.max(0, offset), maxOffset)

        for i = 1, LIST_ROWS do
            local row = rows[i]
            local idx = offset + i
            local entry = entries[idx]
            if entry then
                row.icon:SetTexture(GetEntryIcon(entry))
                row.text:SetText(entry.name)
                row.text:ClearAllPoints()
                row.text:SetPoint("LEFT", row.icon, "RIGHT", 8, 0)
                if searchMode then
                    row.sub:SetText(entry.type == "item" and "Item" or (entry.id and ("#" .. entry.id) or ""))
                    row.sub:Show()
                    row.alertBtn:Hide()
                    row.upBtn:Hide()
                    row.downBtn:Hide()
                    row.text:SetPoint("RIGHT", row.sub, "LEFT", -6, 0)

                    local tracked = IsTracked(entry)
                    row.btn.label:SetText(tracked and "Added" or "Add")
                    row.btn.hoverColor = ACCENT
                    SetButtonEnabled(row.btn, not tracked)
                    row.btn:SetScript("OnClick", function()
                        if not IsTracked(entry) then
                            table.insert(charDB.spells, {
                                type = entry.type, id = entry.id, name = entry.name, spellID = entry.spellID,
                            })
                            ListChanged()
                        end
                    end)
                else
                    row.sub:Hide()
                    row.alertBtn:Show()
                    row.upBtn:Show()
                    row.downBtn:Show()
                    row.text:SetPoint("RIGHT", row.alertBtn, "LEFT", -6, 0)

                    SetAlertLook(row.alertBtn, entry.alert)
                    row.alertBtn:SetScript("OnClick", function()
                        entry.alert = (not entry.alert) or nil
                        SetAlertLook(row.alertBtn, entry.alert)
                    end)

                    SetButtonEnabled(row.upBtn, idx > 1)
                    row.upBtn:SetScript("OnClick", function()
                        local l = charDB.spells
                        if idx > 1 then
                            l[idx], l[idx - 1] = l[idx - 1], l[idx]
                            if offset > 0 and i == 1 then offset = offset - 1 end
                            ListChanged()
                        end
                    end)
                    SetButtonEnabled(row.downBtn, idx < #entries)
                    row.downBtn:SetScript("OnClick", function()
                        local l = charDB.spells
                        if idx < #l then
                            l[idx], l[idx + 1] = l[idx + 1], l[idx]
                            if i == LIST_ROWS then offset = offset + 1 end
                            ListChanged()
                        end
                    end)

                    row.btn.label:SetText("Remove")
                    row.btn.hoverColor = DANGER
                    SetButtonEnabled(row.btn, true)
                    row.btn:SetScript("OnClick", function()
                        local removed = table.remove(charDB.spells, idx)
                        if removed then
                            local key = EntryKey(removed)
                            cdState[key] = nil
                            charDB.knownDurations[key] = nil
                        end
                        ListChanged()
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
                msg = "Nothing tracked yet.\nClick + Add to choose spells or items."
            elseif searchFailed then
                msg = "Search isn't available right now.\nTry again out of combat."
            elseif not indexDone and string.len(searchBox:GetText()) >= 2 then
                msg = "Loading the full spell list...\nResults will appear in a few seconds."
            elseif searchBox:GetText() == "" then
                msg = "Type a spell or item name to search."
            else
                msg = "No matching spells or items."
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
        local results = GetSearchResults(searchBox:GetText())
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
            list:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -378)
            RunSearch()
        else
            addBtn.label:SetText("+ Add")
            searchBox:ClearFocus()
            searchBox:Hide()
            list:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -350)
            entries = charDB.spells
            RefreshList()
        end
    end

    addBtn:SetScript("OnClick", function() SetSearchMode(not searchMode) end)

    list:SetScript("OnMouseWheel", function(_, delta)
        offset = offset - delta
        RefreshList()
    end)

    -- Wait for typing to pause before searching.
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

    function f:RefreshList()
        if not searchMode then RefreshList() end
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

local function OpenOptions()
    if optionsFrame then optionsFrame:Show() end
end

-- A page under Esc > Options > AddOns that points to the real window.
local function RegisterSettingsPage()
    local panel = CreateFrame("Frame")
    panel.name = ADDON_TITLE

    local title = CreateText(panel, 16, ACCENT)
    title:SetPoint("TOPLEFT", panel, "TOPLEFT", 16, -16)
    title:SetText(ADDON_TITLE)
    local desc = CreateText(panel, 12, TEXT_MAIN)
    desc:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -10)
    desc:SetText("All settings are in the " .. ADDON_TITLE .. " window.\nYou can also open it with /sscd or by right-clicking a bar.")

    local open = CreateFlatButton(panel, "Open Options", 120, 24)
    open:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", 0, -14)
    open:SetScript("OnClick", function()
        if not (InCombatLockdown and InCombatLockdown()) and HideUIPanel then
            if SettingsPanel and SettingsPanel:IsShown() then
                pcall(HideUIPanel, SettingsPanel)
            elseif InterfaceOptionsFrame and InterfaceOptionsFrame:IsShown() then
                pcall(HideUIPanel, InterfaceOptionsFrame)
            end
        end
        OpenOptions()
    end)

    if Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory then
        local category = Settings.RegisterCanvasLayoutCategory(panel, ADDON_TITLE)
        Settings.RegisterAddOnCategory(category)
    elseif InterfaceOptions_AddCategory then
        InterfaceOptions_AddCategory(panel)
    end
end

local inCombat = false

-- With "Hide out of combat" on, the bars show only in combat, plus while
-- unlocked (to position them) or while the options window is open (to see
-- changes). Cooldowns are still tracked while the bars are hidden.
UpdateVisibility = function()
    if not db then return end
    local show = not db.hideOutOfCombat or inCombat or IsPreviewing()
    container:SetShown(show and true or false)
    if charDB then LayoutBars(true) end
end

-- Before 1.3.0 the tracked list was shared by all characters. Give it to the
-- first character that actually has one of those spells.
local function MigrateLegacyList()
    local legacy = db.legacy
    if not legacy or charDB.migrated or #charDB.spells > 0 then return false end
    local list = SanitizeEntries(legacy.spells)
    local belongsHere = false
    for _, e in ipairs(list) do
        if e.type ~= "item" and IsSpellAvailable(e, true) then
            belongsHere = true
            break
        end
    end
    if not belongsHere then return false end
    charDB.spells = list
    for _, e in ipairs(list) do
        local key = EntryKey(e)
        local d = type(legacy.durations) == "table" and legacy.durations[key]
        if IsNumber(d) and d > 0 then charDB.knownDurations[key] = d end
    end
    charDB.migrated = true
    return true
end

-------------------------------------------------------------------------------
-- Slash commands
-------------------------------------------------------------------------------
local initialized = false

local function SetLocked(locked)
    db.locked = locked
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
        db.position = nil
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
local function SafeRegisterEvent(frame, event)
    pcall(frame.RegisterEvent, frame, event)
end

local function Initialize(eventFrame)
    SimpleSpellCDTrackerDB = CopyDefaults(DEFAULTS, SimpleSpellCDTrackerDB)
    db = SimpleSpellCDTrackerDB
    SanitizeDB(db)
    SimpleSpellCDTrackerCharDB = CopyDefaults(CHAR_DEFAULTS, SimpleSpellCDTrackerCharDB)
    charDB = SimpleSpellCDTrackerCharDB
    SanitizeCharDB(charDB)
    MigrateLegacyList()
    RepairSpellIDs(charDB.spells)

    ApplyPosition()
    inCombat = (UnitAffectingCombat and UnitAffectingCombat("player")) and true or false
    optionsFrame = CreateOptionsPanel()
    pcall(RegisterSettingsPage)
    ConfigureBars()

    eventFrame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
    SafeRegisterEvent(eventFrame, "SPELLS_CHANGED")
    SafeRegisterEvent(eventFrame, "BAG_UPDATE_DELAYED")
    SafeRegisterEvent(eventFrame, "PLAYER_EQUIPMENT_CHANGED")
    SafeRegisterEvent(eventFrame, "PLAYER_REGEN_DISABLED")
    SafeRegisterEvent(eventFrame, "PLAYER_REGEN_ENABLED")
    initialized = true

    if #charDB.spells == 0 then
        Print("nothing tracked on this character yet. Type /sscd to add spells or items.")
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
        local ok, migrated = pcall(MigrateLegacyList)
        if ok and migrated then
            ConfigureBars()
            if optionsFrame:IsShown() then optionsFrame:RefreshList() end
        end
        pcall(RefreshEntryInfo)
    elseif event == "BAG_UPDATE_DELAYED" or event == "PLAYER_EQUIPMENT_CHANGED" then
        pcall(RefreshEntryInfo)
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
