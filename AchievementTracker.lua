-- Achievement Tracker Addon
-- Tracks achievement completions and displays counts

local AT = {}
AchievementTracker = AT

-- Constants
local DEFAULT_PREFIX = "AotC this season"

-- Addon event frame
local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("CHAT_MSG_ACHIEVEMENT")

-- Default database structure
local defaultDB = {
    achievements = {
        41298 = 0, -- Ahead of the Curve: Chrome King Gallywix
    }, -- [achievementID] = count (simple counter)
    settings = {
        enableDebug = false,
        activeAchievementID = 41298, -- Ahead of the Curve: Chrome King Gallywix
        displayFrame = {
            x = 100,
            y = -100,
            visible = true,
            displayPrefix = DEFAULT_PREFIX, -- Customizable prefix for display
            fontSize = 12, -- Font size for display frame
            enabled = true, -- Whether to show the display frame at all
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

    print("|cff00ff00Achievement Tracker|r loaded. Open Interface Options > AddOns > Achievement Tracker to configure.")

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
-- Create settings panel
function AT:CreateSettingsPanel()
    local panel = CreateFrame("Frame", "AchievementTrackerSettingsPanel", UIParent)
    panel.name = "Achievement Tracker"

    -- Title
    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("Achievement Tracker Settings")

    -- Display Frame Settings Section
    local displayLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    displayLabel:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -30)
    displayLabel:SetText("Display Frame Settings:")

    -- Enable Display Frame setting
    local enableCheckbox = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
    enableCheckbox:SetSize(20, 20)
    enableCheckbox:SetPoint("TOPLEFT", displayLabel, "BOTTOMLEFT", 10, -10)
    enableCheckbox:SetChecked(AT.db.settings.displayFrame.enabled)

    local enableLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    enableLabel:SetPoint("LEFT", enableCheckbox, "RIGHT", 5, 0)
    enableLabel:SetText("Show Display Frame")

    enableCheckbox:SetScript("OnClick", function()
        AT.db.settings.displayFrame.enabled = enableCheckbox:GetChecked()
        if AT.db.settings.displayFrame.enabled then
            AT:CreateDisplayFrame()
            print("|cff00ff00[AT]|r Display frame enabled")
        else
            if AT.displayFrame then
                AT.displayFrame:Hide()
            end
            print("|cff00ff00[AT]|r Display frame disabled")
        end
    end)

    -- Display Prefix setting
    local prefixLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    prefixLabel:SetPoint("TOPLEFT", enableCheckbox, "BOTTOMLEFT", 0, -20)
    prefixLabel:SetText("Display Text Prefix:")

    local prefixHelp = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    prefixHelp:SetPoint("TOPLEFT", prefixLabel, "BOTTOMLEFT", 0, -2)
    prefixHelp:SetText("(This text will be shown before the count, e.g., 'Your Text: 5')")
    prefixHelp:SetTextColor(0.7, 0.7, 0.7)

    local prefixInput = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
    prefixInput:SetSize(150, 20)
    prefixInput:SetPoint("TOPLEFT", prefixHelp, "BOTTOMLEFT", 0, -5)
    prefixInput:SetAutoFocus(false)
    prefixInput:SetText(AT.db.settings.displayFrame.displayPrefix or DEFAULT_PREFIX)

    local prefixSaveButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    prefixSaveButton:SetSize(50, 22)
    prefixSaveButton:SetPoint("LEFT", prefixInput, "RIGHT", 5, 0)
    prefixSaveButton:SetText("Save")
    prefixSaveButton:SetScript("OnClick", function()
        local newPrefix = prefixInput:GetText()
        if newPrefix and newPrefix ~= "" then
            AT.db.settings.displayFrame.displayPrefix = newPrefix
            AT:UpdateDisplayFrame()
            print("|cff00ff00[AT]|r Display prefix updated to: '" .. newPrefix .. "'")
        else
            print("|cffff0000[AT]|r Display prefix cannot be empty")
        end
    end)

    local prefixResetButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    prefixResetButton:SetSize(50, 22)
    prefixResetButton:SetPoint("LEFT", prefixSaveButton, "RIGHT", 5, 0)
    prefixResetButton:SetText("Reset")
    prefixResetButton:SetScript("OnClick", function()
        AT.db.settings.displayFrame.displayPrefix = DEFAULT_PREFIX
        prefixInput:SetText(DEFAULT_PREFIX)
        AT:UpdateDisplayFrame()
        print("|cff00ff00[AT]|r Display prefix reset to default: '" .. DEFAULT_PREFIX .. "'")
    end)

    -- Font Size setting
    local fontLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    fontLabel:SetPoint("TOPLEFT", prefixLabel, "BOTTOMLEFT", 0, -30)
    fontLabel:SetText("Font Size:")

    local fontSlider = CreateFrame("Slider", nil, panel, "OptionsSliderTemplate")
    fontSlider:SetSize(150, 20)
    fontSlider:SetPoint("LEFT", fontLabel, "RIGHT", 10, 0)
    fontSlider:SetMinMaxValues(8, 24)
    fontSlider:SetValue(AT.db.settings.displayFrame.fontSize or 12)
    fontSlider:SetValueStep(1)
    fontSlider:SetObeyStepOnDrag(true)

    -- Slider labels
    fontSlider.Low = fontSlider:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    fontSlider.Low:SetPoint("TOPLEFT", fontSlider, "BOTTOMLEFT", 0, 3)
    fontSlider.Low:SetText("8")

    fontSlider.High = fontSlider:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    fontSlider.High:SetPoint("TOPRIGHT", fontSlider, "BOTTOMRIGHT", 0, 3)
    fontSlider.High:SetText("24")

    fontSlider.Text = fontSlider:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    fontSlider.Text:SetPoint("LEFT", fontSlider, "RIGHT", 10, 0)
    fontSlider.Text:SetText("Size: " .. (AT.db.settings.displayFrame.fontSize or 12))

    fontSlider:SetScript("OnValueChanged", function(self, value)
        value = math.floor(value + 0.5)
        AT.db.settings.displayFrame.fontSize = value
        fontSlider.Text:SetText("Size: " .. value)
        AT:UpdateDisplayFrame()
    end)

    -- General Settings Section
    local generalLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    generalLabel:SetPoint("TOPLEFT", fontLabel, "BOTTOMLEFT", -10, -40)
    generalLabel:SetText("General Settings:")

    -- Debug Mode setting
    local debugCheckbox = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
    debugCheckbox:SetSize(20, 20)
    debugCheckbox:SetPoint("TOPLEFT", generalLabel, "BOTTOMLEFT", 10, -10)
    debugCheckbox:SetChecked(AT.db.settings.enableDebug)

    local debugLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    debugLabel:SetPoint("LEFT", debugCheckbox, "RIGHT", 5, 0)
    debugLabel:SetText("Enable Debug Mode")

    debugCheckbox:SetScript("OnClick", function()
        AT.db.settings.enableDebug = debugCheckbox:GetChecked()
        print(string.format("|cff00ff00[AT]|r Debug mode: %s", AT.db.settings.enableDebug and "ON" or "OFF"))
    end)

    -- Add Achievement section
    local addLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    addLabel:SetPoint("TOPLEFT", debugCheckbox, "BOTTOMLEFT", -10, -30)
    addLabel:SetText("Add Achievement to Track:")

    -- Input box for achievement ID
    local addInput = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
    addInput:SetSize(120, 20)
    addInput:SetPoint("TOPLEFT", addLabel, "BOTTOMLEFT", 0, -5)
    addInput:SetAutoFocus(false)
    addInput:SetNumeric(true)

    -- Add button
    local addButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    addButton:SetSize(80, 22)
    addButton:SetPoint("LEFT", addInput, "RIGHT", 10, 0)
    addButton:SetText("Add")

    -- Tracked achievements table header
    local tableLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    tableLabel:SetPoint("TOPLEFT", addInput, "BOTTOMLEFT", 0, -30)
    tableLabel:SetText("Tracked Achievements:")

    -- Create scroll frame for the table
    local scrollFrame = CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
    scrollFrame:SetSize(500, 300)
    scrollFrame:SetPoint("TOPLEFT", tableLabel, "BOTTOMLEFT", 0, -10)

    -- Create scroll child
    local scrollChild = CreateFrame("Frame", nil, scrollFrame)
    scrollChild:SetSize(480, 1) -- Height will be set dynamically
    scrollFrame:SetScrollChild(scrollChild)

    -- Function to update the achievements table
    local function UpdateAchievementsTable()
        -- Clear existing children more thoroughly
        local children = {scrollChild:GetChildren()}
        for i = 1, #children do
            children[i]:Hide()
            children[i]:SetParent(nil)
        end

        -- Reset scroll position to avoid rendering issues
        scrollFrame:SetVerticalScroll(0)

        local yOffset = 0
        local activeID = AT.db.settings.activeAchievementID

        -- Create header row
        local headerFrame = CreateFrame("Frame", nil, scrollChild)
        headerFrame:SetSize(480, 25)
        headerFrame:SetPoint("TOPLEFT", 0, -yOffset)

        local headerBg = headerFrame:CreateTexture(nil, "BACKGROUND")
        headerBg:SetAllPoints()
        headerBg:SetColorTexture(0.2, 0.2, 0.2, 0.8)

        local idHeader = headerFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        idHeader:SetPoint("LEFT", 5, 0)
        idHeader:SetText("ID")

        local nameHeader = headerFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        nameHeader:SetPoint("LEFT", 50, 0)
        nameHeader:SetText("Achievement Name")

        local countHeader = headerFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        countHeader:SetPoint("LEFT", 280, 0)
        countHeader:SetText("Count")

        local activeHeader = headerFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        activeHeader:SetPoint("LEFT", 330, 0)
        activeHeader:SetText("Active")

        local deleteHeader = headerFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        deleteHeader:SetPoint("LEFT", 420, 0)
        deleteHeader:SetText("Delete")

        yOffset = yOffset + 25

        -- Create rows for each tracked achievement
        for achievementID, count in pairs(AT.db.achievements) do
            local achievementName = select(2, GetAchievementInfo(achievementID)) or "Unknown Achievement"
            local isActive = (achievementID == activeID)

            -- Create row frame
            local rowFrame = CreateFrame("Frame", nil, scrollChild)
            rowFrame:SetSize(480, 25)
            rowFrame:SetPoint("TOPLEFT", 0, -yOffset)

            -- Alternating row colors
            local rowBg = rowFrame:CreateTexture(nil, "BACKGROUND")
            rowBg:SetAllPoints()
            if (yOffset / 25) % 2 == 0 then
                rowBg:SetColorTexture(0.1, 0.1, 0.1, 0.3)
            else
                rowBg:SetColorTexture(0.15, 0.15, 0.15, 0.3)
            end

            -- Achievement ID
            local idText = rowFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            idText:SetPoint("LEFT", 5, 0)
            idText:SetText(tostring(achievementID))

            -- Achievement name (truncated if too long)
            local nameText = rowFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            nameText:SetPoint("LEFT", 50, 0)
            nameText:SetSize(220, 20)
            nameText:SetJustifyH("LEFT")
            if string.len(achievementName) > 30 then
                nameText:SetText(string.sub(achievementName, 1, 27) .. "...")
            else
                nameText:SetText(achievementName)
            end

            -- Count
            local countText = rowFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            countText:SetPoint("LEFT", 280, 0)
            countText:SetText(tostring(count))

            -- Set Active button
            local activeButton = CreateFrame("Button", nil, rowFrame, "UIPanelButtonTemplate")
            activeButton:SetSize(70, 18)
            activeButton:SetPoint("LEFT", 330, 0)
            if isActive then
                activeButton:SetText("ACTIVE")
                activeButton:SetEnabled(false)
            else
                activeButton:SetText("Set Active")
                activeButton:SetEnabled(true)
                activeButton:SetScript("OnClick", function()
                    AT:SetActiveAchievement(achievementID)
                    -- Delay the table update slightly to avoid rendering conflicts
                    C_Timer.After(0.05, function()
                        UpdateAchievementsTable() -- Refresh the table
                    end)
                end)
            end

            -- Delete button
            local deleteButton = CreateFrame("Button", nil, rowFrame, "UIPanelButtonTemplate")
            deleteButton:SetSize(50, 18)
            deleteButton:SetPoint("LEFT", 420, 0)
            deleteButton:SetText("Delete")
            deleteButton:SetScript("OnClick", function()
                AT:ToggleTrackedAchievement(achievementID) -- This will remove it
                -- Delay the table update slightly to avoid rendering conflicts
                C_Timer.After(0.05, function()
                    UpdateAchievementsTable() -- Refresh the table
                end)
            end)

            yOffset = yOffset + 25
        end

        -- If no achievements, show message
        if yOffset == 25 then -- Only header row
            local noDataFrame = CreateFrame("Frame", nil, scrollChild)
            noDataFrame:SetSize(480, 25)
            noDataFrame:SetPoint("TOPLEFT", 0, -yOffset)

            local noDataText = noDataFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            noDataText:SetPoint("CENTER")
            noDataText:SetText("No achievements tracked yet. Add one above!")
            noDataText:SetTextColor(0.7, 0.7, 0.7)

            yOffset = yOffset + 25
        end

        -- Set scroll child height and force refresh
        scrollChild:SetHeight(math.max(yOffset, 1))

        -- Force scroll frame to recalculate and refresh
        scrollFrame:UpdateScrollChildRect()

        -- Small delay to ensure proper rendering
        C_Timer.After(0.01, function()
            if scrollFrame:IsVisible() then
                scrollFrame:UpdateScrollChildRect()
            end
        end)
    end

    -- Add button click handler
    addButton:SetScript("OnClick", function()
        local achievementID = tonumber(addInput:GetText())
        if achievementID then
            -- Check if achievement exists
            local achievementName = select(2, GetAchievementInfo(achievementID))
            if achievementName then
                AT:ToggleTrackedAchievement(achievementID)
                addInput:SetText("") -- Clear input
                UpdateAchievementsTable() -- Refresh table
            else
                print("|cffff0000[AT]|r Invalid achievement ID: " .. achievementID)
            end
        else
            print("|cffff0000[AT]|r Please enter a valid achievement ID")
        end
    end)

    -- Function to update all settings values
    local function UpdateSettingsValues()
        enableCheckbox:SetChecked(AT.db.settings.displayFrame.enabled)
        prefixInput:SetText(AT.db.settings.displayFrame.displayPrefix or DEFAULT_PREFIX)
        fontSlider:SetValue(AT.db.settings.displayFrame.fontSize or 12)
        fontSlider.Text:SetText("Size: " .. (AT.db.settings.displayFrame.fontSize or 12))
        debugCheckbox:SetChecked(AT.db.settings.enableDebug)
    end

    -- Panel show/hide handlers
    panel:SetScript("OnShow", function()
        UpdateSettingsValues()
        UpdateAchievementsTable()
    end)

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

    -- Don't create if disabled
    if not AT.db.settings.displayFrame.enabled then
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
    if not AT.displayFrame or not AT.db.settings.displayFrame.enabled then
        return
    end

    local activeID = AT.db.settings.activeAchievementID
    if not activeID then
        AT.displayFrame.text:SetText("No active achievement set")
        return
    end

    local count = AT.db.achievements[activeID] or 0
    local prefix = AT.db.settings.displayFrame.displayPrefix or DEFAULT_PREFIX
    local fontSize = AT.db.settings.displayFrame.fontSize or 12

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