-- Achievement Tracker Addon
-- Tracks achievement completions and displays counts

local AT = {}
AchievementTracker = AT

-- Addon event frame
local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("CHAT_MSG_ACHIEVEMENT")

-- Default database structure
local defaultDB = {
    achievements = {}, -- [achievementID] = count (simple counter)
    settings = {
        enableDebug = false,
        activeAchievementID = 41298, -- Ahead of the Curve: Chrome King Gallywix
        displayPrefix = "AotC this season", -- Customizable prefix for display
        fontSize = 12, -- Font size for display frame
        displayFrame = {
            x = 100,
            y = -100,
            visible = true,
        }
    }
}

-- Initialize addon
function AT:OnAddonLoaded()
    -- Initialize saved variables
    if not AchievementTrackerDB then
        AchievementTrackerDB = {}
    end

    -- Merge with defaults
    for key, value in pairs(defaultDB) do
        if AchievementTrackerDB[key] == nil then
            AchievementTrackerDB[key] = value
        elseif type(value) == "table" then
            for subkey, subvalue in pairs(value) do
                if AchievementTrackerDB[key][subkey] == nil then
                    AchievementTrackerDB[key][subkey] = subvalue
                end
            end
        end
    end

    AT.db = AchievementTrackerDB

    print("|cff00ff00Achievement Tracker|r loaded. Type |cffff0000/at help|r for commands.")

    -- Create settings panel
    AT:CreateSettingsPanel()

    -- Create display frame
    AT:CreateDisplayFrame()
end

-- Parse achievement message from chat
function AT:ParseAchievementMessage(message, sender)
    if AT.db.settings.enableDebug then
        print(string.format("|cff00ff00[AT Debug]|r Parsing: '%s' from %s", message or "nil", sender or "nil"))
    end

    -- Pattern for achievement messages
    local achievementID = string.match(message, "|Hachievement:(%d+):")
    if achievementID then
        achievementID = tonumber(achievementID)
        local achievementName = select(2, GetAchievementInfo(achievementID))

        if AT.db.settings.enableDebug then
            print(string.format("|cff00ff00[AT Debug]|r Found achievement: ID=%d, Name=%s", achievementID, achievementName or "Unknown"))
        end

        return sender, achievementID, achievementName
    end

    return nil, nil, nil
end

-- Check if we should track this achievement
function AT:ShouldTrackAchievement(achievementID)
    -- Always track the active achievement
    if achievementID == AT.db.settings.activeAchievementID then
        return true
    end

    -- Also track any achievement that's already in our database (previously tracked)
    return AT.db.achievements[achievementID] ~= nil
end

-- Record an achievement for a player
function AT:RecordAchievement(playerName, achievementID, achievementName)
    -- Check if we should track this achievement
    if not AT:ShouldTrackAchievement(achievementID) then
        return
    end

    -- Initialize counter if it doesn't exist
    if not AT.db.achievements[achievementID] then
        AT.db.achievements[achievementID] = 0
    end

    -- Increment the counter
    AT.db.achievements[achievementID] = AT.db.achievements[achievementID] + 1

    -- Debug output
    if AT.db.settings.enableDebug then
        print(string.format("|cff00ff00[AT Debug]|r Recorded achievement for %s: [%d] %s (Total: %d)",
              playerName, achievementID, achievementName, AT.db.achievements[achievementID]))
    end

    -- Update display frame if this is the active achievement
    if AT.db.settings.activeAchievementID == achievementID then
        AT:UpdateDisplayFrame()
    end
end

-- Event handler
function AT:OnEvent(event, ...)
    if event == "ADDON_LOADED" then
        local addonName = ...
        if addonName == "AchievementTracker" then
            AT:OnAddonLoaded()
        end
    elseif event == "CHAT_MSG_ACHIEVEMENT" then
        local message, sender = ...
        local playerName, achievementID, achievementName = AT:ParseAchievementMessage(message, sender)

        if playerName and achievementID and achievementName then
            AT:RecordAchievement(playerName, achievementID, achievementName)
        end
    end
end

frame:SetScript("OnEvent", function(self, event, ...)
    AT:OnEvent(event, ...)
end)
-- Slash command handler
SLASH_ACHIEVEMENTTRACKER1 = "/at"
SLASH_ACHIEVEMENTTRACKER2 = "/achievementtracker"

function SlashCmdList.ACHIEVEMENTTRACKER(msg)
    local args = {}
    for word in string.gmatch(msg, "%S+") do
        table.insert(args, word)
    end

    local command = args[1] and string.lower(args[1]) or "help"

    if command == "help" then
        print("|cff00ff00Achievement Tracker Commands:|r")
        print("|cffff0000/at help|r - Show this help")
        print("|cffff0000/at stats|r - Show achievement statistics")
        print("|cffff0000/at debug|r - Toggle debug mode")
        print("|cffff0000/at track <achievementID>|r - Add/remove tracked achievement")
        print("|cffff0000/at config|r - Open settings panel")
        print("|cffff0000/at list|r - Show currently tracked achievements")
        print("|cffff0000/at active <achievementID>|r - Set active achievement for display")
        print("|cffff0000/at show|r - Show/hide display frame")
        print("|cffff0000/at reset|r - Reset display frame position")

    elseif command == "stats" then
        AT:ShowTrackedAchievements()

    elseif command == "debug" then
        AT.db.settings.enableDebug = not AT.db.settings.enableDebug
        print(string.format("|cff00ff00[AT]|r Debug mode: %s",
              AT.db.settings.enableDebug and "ON" or "OFF"))

    elseif command == "track" then
        local achievementID = tonumber(args[2])
        if achievementID then
            AT:ToggleTrackedAchievement(achievementID)
        else
            print("|cffff0000Usage:|r /at track <achievementID>")
        end

    elseif command == "list" then
        AT:ShowTrackedAchievements()

    elseif command == "config" then
        InterfaceOptionsFrame_OpenToCategory("Achievement Tracker")
        InterfaceOptionsFrame_OpenToCategory("Achievement Tracker") -- Call twice for Blizzard UI bug

    elseif command == "active" then
        local achievementID = tonumber(args[2])
        if achievementID then
            AT:SetActiveAchievement(achievementID)
        else
            print("|cffff0000Usage:|r /at active <achievementID>")
        end

    elseif command == "show" then
        AT:ToggleDisplayFrame()

    elseif command == "reset" then
        AT:ResetDisplayFramePosition()

    else
        print("|cffff0000Unknown command:|r " .. command)
        print("Type |cffff0000/at help|r for available commands.")
    end
end

-- Toggle tracked achievement (using achievements object as source of truth)
function AT:ToggleTrackedAchievement(achievementID)
    if AT.db.achievements[achievementID] then
        -- Remove from tracking
        AT.db.achievements[achievementID] = nil
        print(string.format("|cff00ff00[AT]|r Removed achievement %d from tracking", achievementID))
    else
        -- Add to tracking with 0 count
        AT.db.achievements[achievementID] = 0
        print(string.format("|cff00ff00[AT]|r Added achievement %d to tracking", achievementID))
    end
end

-- Show tracked achievements
function AT:ShowTrackedAchievements()
    local activeID = AT.db.settings.activeAchievementID
    local count = 0

    print("|cff00ff00[AT]|r Currently tracked achievements:")
    for achievementID, achievementCount in pairs(AT.db.achievements) do
        local achievementName = select(2, GetAchievementInfo(achievementID)) or "Unknown Achievement"
        local activeMarker = (achievementID == activeID) and " |cffff8000[ACTIVE]|r" or ""
        print(string.format("  [%d] %s: %d times%s", achievementID, achievementName, achievementCount, activeMarker))
        count = count + 1
    end

    if count == 0 then
        print("|cff00ff00[AT]|r No achievements currently tracked")
    end

    -- Show active achievement info
    if activeID then
        local activeName = select(2, GetAchievementInfo(activeID)) or "Unknown Achievement"
        local activeCount = AT.db.achievements[activeID] or 0
        print(string.format("|cff00ff00[AT]|r Active display: [%d] %s (%d times)", activeID, activeName, activeCount))
    else
        print("|cff00ff00[AT]|r No active achievement set for display")
    end
end

-- Set active achievement
function AT:SetActiveAchievement(achievementID)
    AT.db.settings.activeAchievementID = achievementID
    local achievementName = select(2, GetAchievementInfo(achievementID)) or "Unknown Achievement"

    -- Ensure this achievement is being tracked
    if not AT.db.achievements[achievementID] then
        AT.db.achievements[achievementID] = 0
    end

    print(string.format("|cff00ff00[AT]|r Set active achievement: [%d] %s", achievementID, achievementName))
    AT:UpdateDisplayFrame()
end
-- Create simple settings panel
function AT:CreateSettingsPanel()
    local panel = CreateFrame("Frame", "AchievementTrackerSettingsPanel", UIParent)
    panel.name = "Achievement Tracker"

    -- Title
    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("Achievement Tracker Settings")

    -- Simple message for now
    local message = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    message:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -20)
    message:SetText("Use /at commands to manage achievements.\nSettings panel will be improved in future versions.")

    -- Register with settings
    if Settings and Settings.RegisterCanvasLayoutCategory then
        local category = Settings.RegisterCanvasLayoutCategory(panel, panel.name)
        Settings.RegisterAddOnCategory(category)
    else
        InterfaceOptions_AddCategory(panel)
    end
end

-- Create display frame
function AT:CreateDisplayFrame()
    if AT.displayFrame then
        return
    end

    -- Create the main frame
    AT.displayFrame = CreateFrame("Frame", "AchievementTrackerDisplay", UIParent, "BackdropTemplate")
    AT.displayFrame:SetSize(200, 30)
    AT.displayFrame:SetPoint("CENTER")
    AT.displayFrame:SetClampedToScreen(true)

    -- Set backdrop
    AT.displayFrame:SetBackdrop({
        bgFile = "Interface/Tooltips/UI-Tooltip-Background",
        edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
        tile = true,
        tileSize = 16,
        edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 }
    })
    AT.displayFrame:SetBackdropColor(0, 0, 0, 0.8)

    -- Enable mouse
    AT.displayFrame:EnableMouse(true)
    AT.displayFrame:SetMovable(true)
    AT.displayFrame:RegisterForDrag("LeftButton")

    -- Create text
    local text = AT.displayFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    text:SetPoint("CENTER")
    text:SetTextColor(1, 1, 1, 1)
    AT.displayFrame.text = text

    -- Mouse handlers
    AT.displayFrame:SetScript("OnMouseDown", function(self, button)
        if IsShiftKeyDown() and button == "LeftButton" then
            self:StartMoving()
        end
    end)

    AT.displayFrame:SetScript("OnMouseUp", function(self, button)
        self:StopMovingOrSizing()
        local point, _, _, x, y = self:GetPoint()
        AT.db.settings.displayFrame.x = x
        AT.db.settings.displayFrame.y = y
    end)

    -- Tooltip
    AT.displayFrame:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Achievement Tracker", 1, 1, 1)
        GameTooltip:AddLine("Hold Shift + Drag to move", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)

    AT.displayFrame:SetScript("OnLeave", function(self)
        GameTooltip:Hide()
    end)

    -- Show the frame
    AT.displayFrame:Show()

    -- Update the text
    AT:UpdateDisplayFrame()
end

-- Update display frame text
function AT:UpdateDisplayFrame()
    if not AT.displayFrame then
        return
    end

    local activeID = AT.db.settings.activeAchievementID
    if not activeID then
        AT.displayFrame.text:SetText("No active achievement set")
        return
    end

    local count = AT.db.achievements[activeID] or 0
    local prefix = AT.db.settings.displayPrefix or "AotC this season"
    local fontSize = AT.db.settings.fontSize or 12

    -- Update font size
    local fontPath, _, fontFlags = AT.displayFrame.text:GetFont()
    AT.displayFrame.text:SetFont(fontPath or "Fonts\\FRIZQT__.TTF", fontSize, fontFlags or "OUTLINE")

    -- Set text
    local displayText = string.format("%s: %d", prefix, count)
    AT.displayFrame.text:SetText(displayText)

    -- Auto-resize frame
    local textWidth = AT.displayFrame.text:GetStringWidth()
    local textHeight = AT.displayFrame.text:GetStringHeight()
    local frameWidth = math.max(textWidth + 20, 80)
    local frameHeight = math.max(textHeight + 12, 20)
    AT.displayFrame:SetSize(frameWidth, frameHeight)
end

-- Toggle display frame visibility
function AT:ToggleDisplayFrame()
    if not AT.displayFrame then
        AT:CreateDisplayFrame()
        return
    end

    if AT.displayFrame:IsShown() then
        AT.displayFrame:Hide()
        AT.db.settings.displayFrame.visible = false
    else
        AT.displayFrame:Show()
        AT.db.settings.displayFrame.visible = true
    end
end

-- Reset display frame position
function AT:ResetDisplayFramePosition()
    AT.db.settings.displayFrame.x = 100
    AT.db.settings.displayFrame.y = -100
    if AT.displayFrame then
        AT.displayFrame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 100, -100)
    end
end