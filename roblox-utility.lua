--[[
    Universal Client Utility — clean rebuild of the one-liner loader pattern
    ------------------------------------------------------------------------
    Executor required. Two ways to run:

      1. Paste this whole file into your executor and execute.
      2. Load from GitHub raw:
         loadstring(game:HttpGet("https://raw.githubusercontent.com/malhidayah/roblox-utility/main/roblox-utility.lua"))()

    Toggle UI: RightShift

    Design notes:
      - Every feature is isolated. If one fails on a game, the rest keep working.
      - Features re-apply automatically after respawn.
      - Nothing here is map-specific: all of it operates on the local character,
        camera, or client-side rendering.
]]

if not (getgenv and loadstring) then
    return warn("[Utility] Executor required (getgenv/loadstring missing).")
end

local Players     = game:GetService("Players")
local RunService  = game:GetService("RunService")
local UIS         = game:GetService("UserInputService")
local VirtualUser = game:GetService("VirtualUser")
local StarterGui  = game:GetService("StarterGui")

local LP   = Players.LocalPlayer
local genv = getgenv()

-- ---------------------------------------------------------------- state

local state = {
    fly     = false,
    noclip  = false,
    esp     = false,
    speed   = false,
    jump    = false,
    infJump = false,
    clickTP = false,
    uiOpen  = true,
}

-- ---------------------------------------------------------------- helpers

local function getChar()
    local c = LP.Character
    if not c then return nil end
    local hum = c:FindFirstChildOfClass("Humanoid")
    local hrp = c:FindFirstChild("HumanoidRootPart")
    if hum and hrp then return c, hum, hrp end
    return nil
end

local function notify(text)
    pcall(function()
        StarterGui:SetCore("SendNotification", {
            Title = "Utility",
            Text = text,
            Duration = 3,
        })
    end)
end

local statusLabel
local function setStatus(text)
    if statusLabel then statusLabel.Text = text end
    warn("[Utility] " .. text)
end

-- Accepts username, display name (in-game name), or numeric UserId.
local function findPlayer(query)
    query = tostring(query or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if query == "" then return nil end
    local q = query:lower()
    local asId = tonumber(query)

    -- exact username / display name
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LP and (plr.Name:lower() == q or plr.DisplayName:lower() == q) then
            return plr
        end
    end

    -- exact UserId
    if asId then
        for _, plr in ipairs(Players:GetPlayers()) do
            if plr ~= LP and plr.UserId == asId then return plr end
        end
    end

    -- partial match on username or display name
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LP and (plr.Name:lower():find(q, 1, true) or plr.DisplayName:lower():find(q, 1, true)) then
            return plr
        end
    end

    return nil
end

-- Finds a player or falls back to a raw UserId (works even if they left).
local function resolveTarget(query)
    local plr = findPlayer(query)
    if plr then return plr, plr.UserId end
    local id = tonumber((tostring(query or ""):gsub("%s+", "")))
    if id then return nil, id end
    return nil, nil
end

-- ---------------------------------------------------------------- fly

local flyConn, flyBV, flyBG

local function flyOff()
    state.fly = false
    if flyConn then flyConn:Disconnect(); flyConn = nil end
    if flyBV then flyBV:Destroy(); flyBV = nil end
    if flyBG then flyBG:Destroy(); flyBG = nil end
    local _, hum = getChar()
    if hum then hum.PlatformStand = false end
end

local function flyOn()
    local _, hum, hrp = getChar()
    if not hrp then return false end

    state.fly = true
    hum.PlatformStand = true

    flyBV = Instance.new("BodyVelocity")
    flyBV.MaxForce = Vector3.new(1e5, 1e5, 1e5)
    flyBV.Velocity = Vector3.zero
    flyBV.Parent = hrp

    flyBG = Instance.new("BodyGyro")
    flyBG.MaxTorque = Vector3.new(1e5, 1e5, 1e5)
    flyBG.P = 1e4
    flyBG.Parent = hrp

    flyConn = RunService.RenderStepped:Connect(function()
        local _, _, root = getChar()
        if not root then return end
        local cam = workspace.CurrentCamera
        if not cam then return end

        local dir = Vector3.zero
        if UIS:IsKeyDown(Enum.KeyCode.W) then dir += cam.CFrame.LookVector end
        if UIS:IsKeyDown(Enum.KeyCode.S) then dir -= cam.CFrame.LookVector end
        if UIS:IsKeyDown(Enum.KeyCode.D) then dir += cam.CFrame.RightVector end
        if UIS:IsKeyDown(Enum.KeyCode.A) then dir -= cam.CFrame.RightVector end
        if UIS:IsKeyDown(Enum.KeyCode.Space) then dir += Vector3.yAxis end
        if UIS:IsKeyDown(Enum.KeyCode.LeftControl) then dir -= Vector3.yAxis end
        if dir.Magnitude > 0 then dir = dir.Unit end

        flyBV.Velocity = dir * 55
        flyBG.CFrame = cam.CFrame
    end)

    return true
end

-- ---------------------------------------------------------------- noclip

local noclipConn
local noclipSaved = {}
local noclipHook

local function noclipSweep()
    local c = LP.Character
    if not c then return end
    for _, p in ipairs(c:GetDescendants()) do
        if p:IsA("BasePart") and p.CanCollide then
            p.CanCollide = false
        end
    end
end

-- Tells us *why* noclip might still fail: who simulates the character,
-- whether it is anchored, and whether constraints are holding it.
local function noclipReport()
    local c, _, hrp = getChar()
    if not hrp then return "noclip: no character" end

    local total, colliding = 0, 0
    local constraints = 0
    for _, p in ipairs(c:GetDescendants()) do
        if p:IsA("BasePart") then
            total += 1
            if p.CanCollide then colliding += 1 end
        end
        if p:IsA("AlignPosition") or p:IsA("AlignOrientation")
        or p:IsA("BodyPosition") or p:IsA("BodyVelocity")
        or p:IsA("LinearVelocity") or p:IsA("BodyGyro") then
            constraints += 1
        end
    end

    local owner = "?"
    pcall(function()
        local o = hrp:GetNetworkOwner()
        owner = o and o.Name or "server"
    end)

    return ("noclip: %d parts, collide=%d, owner=%s, anchored=%s, constraints=%d")
        :format(total, colliding, owner, tostring(hrp.Anchored), constraints)
end

-- last resort for games that re-enable CanCollide every frame
local function installCanCollideHook()
    if noclipHook then return end
    local ok, mt = pcall(getrawmetatable, game)
    if not ok or type(mt) ~= "table" then
        setStatus("noclip: game resets collision and hook is unavailable")
        return
    end
    local prev = mt.__newindex
    pcall(setreadonly, mt, false)
    mt.__newindex = function(t, k, v)
        if state.noclip and k == "CanCollide" and typeof(t) == "Instance" and t:IsA("BasePart") then
            local c = LP.Character
            if c and t:IsDescendantOf(c) then v = false end
        end
        if prev then
            return prev(t, k, v)
        end
    end
    pcall(setreadonly, mt, true)
    noclipHook = { mt = mt, prev = prev }
    setStatus("noclip: forced via CanCollide hook")
end

local function removeCanCollideHook()
    if not noclipHook then return end
    pcall(setreadonly, noclipHook.mt, false)
    noclipHook.mt.__newindex = noclipHook.prev
    pcall(setreadonly, noclipHook.mt, true)
    noclipHook = nil
end

local function noclipOff()
    state.noclip = false
    if noclipConn then noclipConn:Disconnect(); noclipConn = nil end
    removeCanCollideHook()
    for part, wasColliding in pairs(noclipSaved) do
        if part and part.Parent then
            pcall(function() part.CanCollide = wasColliding end)
        end
    end
    noclipSaved = {}
end

local function noclipOn()
    local c = LP.Character
    if not c then return false end

    state.noclip = true
    noclipSaved = {}
    for _, p in ipairs(c:GetDescendants()) do
        if p:IsA("BasePart") then
            noclipSaved[p] = p.CanCollide
            p.CanCollide = false
        end
    end

    if noclipConn then noclipConn:Disconnect() end
    noclipConn = RunService.Stepped:Connect(noclipSweep)

    -- Hook immediately rather than waiting to lose a frame race.
    installCanCollideHook()

    task.delay(1, function()
        if state.noclip then setStatus(noclipReport()) end
    end)

    return true
end

-- ---------------------------------------------------------------- esp

local espCache = {}

local function espRemove(plr)
    local hl = espCache[plr]
    if hl then hl:Destroy(); espCache[plr] = nil end
end

local function espApply(plr)
    if plr == LP then return end
    espRemove(plr)
    local c = plr.Character
    if not c then return end

    local hl = Instance.new("Highlight")
    hl.Name = "UtilESP"
    hl.Adornee = c
    hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
    hl.FillColor = Color3.fromRGB(255, 60, 60)
    hl.FillTransparency = 0.65
    hl.OutlineColor = Color3.fromRGB(255, 255, 255)
    hl.OutlineTransparency = 0
    hl.Parent = c

    espCache[plr] = hl
end

local function espOff()
    state.esp = false
    for plr in pairs(espCache) do espRemove(plr) end
end

local function espOn()
    state.esp = true
    for _, plr in ipairs(Players:GetPlayers()) do espApply(plr) end
    return true
end

local function watchPlayer(plr)
    plr.CharacterAdded:Connect(function()
        if state.esp then
            task.wait(0.35)
            espApply(plr)
        end
    end)
end

Players.PlayerAdded:Connect(watchPlayer)
Players.PlayerRemoving:Connect(espRemove)
for _, plr in ipairs(Players:GetPlayers()) do watchPlayer(plr) end

-- ---------------------------------------------------------------- misc

-- infinite jump
UIS.JumpRequest:Connect(function()
    if not state.infJump then return end
    local _, hum = getChar()
    if hum then hum:ChangeState(Enum.HumanoidStateType.Jumping) end
end)

-- click teleport
UIS.InputBegan:Connect(function(input, gp)
    if gp or not state.clickTP then return end
    if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
    local _, _, hrp = getChar()
    if not hrp then return end
    local mouse = LP:GetMouse()
    if mouse and mouse.Hit then
        hrp.CFrame = CFrame.new(mouse.Hit.Position + Vector3.new(0, 3, 0))
    end
end)

-- anti-afk (always on)
LP.Idled:Connect(function()
    pcall(function()
        VirtualUser:CaptureController()
        VirtualUser:ClickButton2(Vector2.new())
    end)
end)

-- ---------------------------------------------------------------- feature dispatch

local function setFeature(key, on)
    if key == "fly" then
        if on then return flyOn() end
        flyOff()
        return true
    elseif key == "noclip" then
        if on then return noclipOn() end
        noclipOff()
        return true
    elseif key == "esp" then
        if on then return espOn() end
        espOff()
        return true
    elseif key == "speed" then
        local _, hum = getChar()
        if not hum then return false end
        state.speed = on
        hum.WalkSpeed = on and 96 or 16
        return true
    elseif key == "jump" then
        local _, hum = getChar()
        if not hum then return false end
        state.jump = on
        hum.UseJumpPower = true
        hum.JumpPower = on and 100 or 50
        return true
    elseif key == "infJump" then
        state.infJump = on
        return true
    elseif key == "clickTP" then
        state.clickTP = on
        return true
    end
    return false
end

-- re-apply after respawn
LP.CharacterAdded:Connect(function()
    task.wait(0.6)
    if state.fly then flyOff(); flyOn() end
    local _, hum = getChar()
    if hum then
        if state.speed then hum.WalkSpeed = 96 end
        if state.jump then
            hum.UseJumpPower = true
            hum.JumpPower = 100
        end
    end
    if state.noclip then noclipOn() end
end)

-- ---------------------------------------------------------------- avatar tools

local SCALES = { 0.4, 0.6, 0.8, 1, 1.4, 2, 3, 5 }
local scaleIndex = 4

local function applyScale()
    local c, hum = getChar()
    if not c then return false, "no character" end
    local n = SCALES[scaleIndex]
    local ok = pcall(function() c:ScaleTo(n) end)
    if not ok and hum then
        pcall(function()
            if hum.BodyHeightScale then hum.BodyHeightScale.Value = n end
            if hum.BodyWidthScale then hum.BodyWidthScale.Value = n end
            if hum.BodyDepthScale then hum.BodyDepthScale.Value = n end
            if hum.HeadScale then hum.HeadScale.Value = n end
        end)
    end
    setStatus(("scale: %.2fx"):format(n))
    return true
end

local EMOTES = {
    { name = "Dance",  id = 507771019 },
    { name = "Dance2", id = 507776043 },
    { name = "Wave",   id = 507770239 },
    { name = "Point",  id = 507770453 },
    { name = "Laugh",  id = 507770818 },
    { name = "Cheer",  id = 507770677 },
}

local emoteTrack
local function playEmote(id)
    local _, hum = getChar()
    if not hum then return false, "no character" end
    local animator = hum:FindFirstChildOfClass("Animator")
    if not animator then return false, "no animator" end

    if emoteTrack then pcall(function() emoteTrack:Stop() end) end

    local anim = Instance.new("Animation")
    anim.AnimationId = "rbxassetid://" .. tostring(id)
    local ok, track = pcall(function() return animator:LoadAnimation(anim) end)
    if not ok or not track then return false, "load blocked" end
    track.Looped = true
    track:Play()
    emoteTrack = track
    return true
end

-- Copies appearance. Works by UserId too, even if the player already left.
local function copyOutfit(query)
    local _, hum = getChar()
    if not hum then return false, "no character" end

    local target, userId = resolveTarget(query)
    local desc

    if target and target.Character then
        local th = target.Character:FindFirstChildOfClass("Humanoid")
        if th then
            local ok, d = pcall(function() return th:GetAppliedDescription() end)
            if ok then desc = d end
        end
    end

    if not desc and userId then
        local ok, d = pcall(function()
            return Players:GetHumanoidDescriptionFromUserId(userId)
        end)
        if ok then desc = d end
    end

    if not desc then return false, "could not read description" end

    local ok = pcall(function() hum:ApplyDescription(desc) end)
    if not ok then return false, "ApplyDescription blocked by game" end
    return true
end

-- ---------------------------------------------------------------- ui

local parent = (gethui and gethui()) or LP:WaitForChild("PlayerGui")

local screen = Instance.new("ScreenGui")
screen.Name = "UtilUI"
screen.ResetOnSpawn = false
screen.IgnoreGuiInset = true
screen.DisplayOrder = 999
screen.Parent = parent

local main = Instance.new("Frame")
main.Name = "Main"
main.Size = UDim2.fromOffset(252, 384)
main.Position = UDim2.new(0, 24, 0.5, -192)
main.BackgroundColor3 = Color3.fromRGB(20, 20, 24)
main.BorderSizePixel = 0
main.Active = true
main.Parent = screen

local mainCorner = Instance.new("UICorner")
mainCorner.CornerRadius = UDim.new(0, 8)
mainCorner.Parent = main

local mainStroke = Instance.new("UIStroke")
mainStroke.Color = Color3.fromRGB(60, 60, 70)
mainStroke.Thickness = 1
mainStroke.Parent = main

local header = Instance.new("Frame")
header.Size = UDim2.new(1, 0, 0, 36)
header.BackgroundColor3 = Color3.fromRGB(30, 30, 36)
header.BorderSizePixel = 0
header.Parent = main

local headerCorner = Instance.new("UICorner")
headerCorner.CornerRadius = UDim.new(0, 8)
headerCorner.Parent = header

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -80, 1, 0)
title.Position = UDim2.fromOffset(12, 0)
title.BackgroundTransparency = 1
title.Text = "Universal Utility"
title.TextColor3 = Color3.fromRGB(235, 235, 240)
title.Font = Enum.Font.GothamMedium
title.TextSize = 14
title.TextXAlignment = Enum.TextXAlignment.Left
title.Parent = header

local hide = Instance.new("TextButton")
hide.Size = UDim2.fromOffset(24, 24)
hide.Position = UDim2.new(1, -32, 0, 6)
hide.BackgroundColor3 = Color3.fromRGB(45, 45, 52)
hide.Text = "-"
hide.TextColor3 = Color3.fromRGB(220, 220, 225)
hide.Font = Enum.Font.GothamBold
hide.TextSize = 16
hide.BorderSizePixel = 0
hide.Parent = header

local hideCorner = Instance.new("UICorner")
hideCorner.CornerRadius = UDim.new(0, 6)
hideCorner.Parent = hide

local list = Instance.new("ScrollingFrame")
list.Size = UDim2.new(1, -16, 1, -80)
list.Position = UDim2.fromOffset(8, 44)
list.BackgroundTransparency = 1
list.BorderSizePixel = 0
list.ScrollBarThickness = 3
list.ScrollBarImageColor3 = Color3.fromRGB(80, 80, 90)
list.CanvasSize = UDim2.new(0, 0, 0, 0)
list.AutomaticCanvasSize = Enum.AutomaticSize.Y
list.Parent = main

local layout = Instance.new("UIListLayout")
layout.Padding = UDim.new(0, 6)
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Parent = list

statusLabel = Instance.new("TextLabel")
statusLabel.Size = UDim2.new(1, -16, 0, 22)
statusLabel.Position = UDim2.new(0, 8, 1, -26)
statusLabel.BackgroundTransparency = 1
statusLabel.Text = "ready"
statusLabel.TextColor3 = Color3.fromRGB(130, 130, 140)
statusLabel.Font = Enum.Font.Gotham
statusLabel.TextSize = 11
statusLabel.TextXAlignment = Enum.TextXAlignment.Left
statusLabel.TextTruncate = Enum.TextTruncate.AtEnd
statusLabel.Parent = main

local rows = {}

local function refreshRows()
    for key, row in pairs(rows) do
        local on = state[key]
        row.BackgroundColor3 = on and Color3.fromRGB(48, 110, 70) or Color3.fromRGB(34, 34, 40)
        row.TextColor3 = on and Color3.fromRGB(200, 255, 210) or Color3.fromRGB(200, 200, 208)
    end
end

local featureList = {
    { key = "fly",     label = "Fly  (WASD / Space / Ctrl)" },
    { key = "noclip",  label = "Noclip" },
    { key = "esp",     label = "Player ESP" },
    { key = "speed",   label = "Speed x6" },
    { key = "jump",    label = "Jump x2" },
    { key = "infJump", label = "Infinite Jump" },
    { key = "clickTP", label = "Click Teleport" },
}

for i, feat in ipairs(featureList) do
    local row = Instance.new("TextButton")
    row.Size = UDim2.new(1, -4, 0, 32)
    row.BackgroundColor3 = Color3.fromRGB(34, 34, 40)
    row.BorderSizePixel = 0
    row.Text = "  " .. feat.label
    row.TextColor3 = Color3.fromRGB(200, 200, 208)
    row.Font = Enum.Font.Gotham
    row.TextSize = 13
    row.TextXAlignment = Enum.TextXAlignment.Left
    row.AutoButtonColor = false
    row.LayoutOrder = i
    row.Parent = list

    local rc = Instance.new("UICorner")
    rc.CornerRadius = UDim.new(0, 6)
    rc.Parent = row

    row.MouseButton1Click:Connect(function()
        local ok, res = pcall(setFeature, feat.key, not state[feat.key])
        if not ok or res == false then
            notify(feat.label .. " unavailable in this game")
            setStatus(feat.label .. ": failed - no character or blocked by game")
        end
        refreshRows()
    end)

    rows[feat.key] = row
end

-- teleport / bring section
local tpRow = Instance.new("Frame")
tpRow.Size = UDim2.new(1, -4, 0, 64)
tpRow.BackgroundTransparency = 1
tpRow.BorderSizePixel = 0
tpRow.LayoutOrder = 100
tpRow.Parent = list

local tpBox = Instance.new("TextBox")
tpBox.Size = UDim2.new(1, 0, 0, 28)
tpBox.BackgroundColor3 = Color3.fromRGB(34, 34, 40)
tpBox.PlaceholderText = "player name"
tpBox.Text = ""
tpBox.TextColor3 = Color3.fromRGB(220, 220, 226)
tpBox.PlaceholderColor3 = Color3.fromRGB(120, 120, 130)
tpBox.Font = Enum.Font.Gotham
tpBox.TextSize = 12
tpBox.BorderSizePixel = 0
tpBox.ClearTextOnFocus = false
tpBox.Parent = tpRow

local tpCorner = Instance.new("UICorner")
tpCorner.CornerRadius = UDim.new(0, 6)
tpCorner.Parent = tpBox

local function actionButton(text, position, color)
    local b = Instance.new("TextButton")
    b.Size = UDim2.new(0.5, -3, 0, 28)
    b.Position = position
    b.BackgroundColor3 = color
    b.Text = text
    b.TextColor3 = Color3.fromRGB(225, 225, 230)
    b.Font = Enum.Font.GothamMedium
    b.TextSize = 12
    b.BorderSizePixel = 0
    b.AutoButtonColor = false
    b.Parent = tpRow
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, 6)
    c.Parent = b
    return b
end

local goBtn    = actionButton("TP to",     UDim2.new(0, 0, 0, 32),   Color3.fromRGB(38, 70, 55))
local bringBtn = actionButton("Bring here", UDim2.new(0.5, 3, 0, 32), Color3.fromRGB(74, 44, 44))

local function tpToPlayer()
    local target = findPlayer(tpBox.Text)
    if not target then
        notify("No player matching: " .. tpBox.Text)
        return
    end
    local _, _, hrp = getChar()
    local thrp = target.Character and target.Character:FindFirstChild("HumanoidRootPart")
    if hrp and thrp then
        hrp.CFrame = thrp.CFrame + Vector3.new(0, 0, 2)
        setStatus("teleported to " .. target.Name)
    else
        notify("Target has no loaded character")
    end
end

goBtn.MouseButton1Click:Connect(tpToPlayer)

tpBox.FocusLost:Connect(function(enterPressed)
    if enterPressed then tpToPlayer() end
end)

bringBtn.MouseButton1Click:Connect(function()
    local target = findPlayer(tpBox.Text)
    if not target then
        notify("No player matching: " .. tpBox.Text)
        return
    end
    local _, _, hrp = getChar()
    local tchar = target.Character
    local troot = tchar and tchar:FindFirstChild("HumanoidRootPart")
    if not (hrp and troot) then
        notify("Target has no loaded character")
        return
    end
    troot.CFrame = hrp.CFrame + Vector3.new(0, 0, 3)
    setStatus("bring attempt on " .. target.Name .. " - server may snap back")
end)

-- avatar section
local function sectionLabel(text, order)
    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.new(1, -4, 0, 18)
    lbl.BackgroundTransparency = 1
    lbl.Text = text
    lbl.TextColor3 = Color3.fromRGB(120, 120, 132)
    lbl.Font = Enum.Font.GothamBold
    lbl.TextSize = 10
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.LayoutOrder = order
    lbl.Parent = list
    return lbl
end

local function flatButton(text, order, height)
    local b = Instance.new("TextButton")
    b.Size = UDim2.new(1, -4, 0, height or 30)
    b.BackgroundColor3 = Color3.fromRGB(34, 34, 40)
    b.Text = "  " .. text
    b.TextColor3 = Color3.fromRGB(200, 200, 208)
    b.Font = Enum.Font.Gotham
    b.TextSize = 12
    b.TextXAlignment = Enum.TextXAlignment.Left
    b.AutoButtonColor = false
    b.BorderSizePixel = 0
    b.LayoutOrder = order
    b.Parent = list
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, 6)
    c.Parent = b
    return b
end

sectionLabel("AVATAR", 101)

local copyBtn = flatButton("Copy outfit (name / UserId above)", 102)
copyBtn.MouseButton1Click:Connect(function()
    local ok, err = copyOutfit(tpBox.Text)
    if ok then
        setStatus("outfit copied from " .. tpBox.Text)
    else
        notify("Copy outfit: " .. tostring(err))
    end
end)

local sizeRow = Instance.new("Frame")
sizeRow.Size = UDim2.new(1, -4, 0, 28)
sizeRow.BackgroundTransparency = 1
sizeRow.BorderSizePixel = 0
sizeRow.LayoutOrder = 103
sizeRow.Parent = list

local function smallBtn(text, xScale, xOffset, widthScale, widthOffset, parent)
    local b = Instance.new("TextButton")
    b.Size = UDim2.new(widthScale, widthOffset, 1, 0)
    b.Position = UDim2.new(xScale, xOffset, 0, 0)
    b.BackgroundColor3 = Color3.fromRGB(34, 34, 40)
    b.Text = text
    b.TextColor3 = Color3.fromRGB(210, 210, 218)
    b.Font = Enum.Font.Gotham
    b.TextSize = 12
    b.BorderSizePixel = 0
    b.AutoButtonColor = false
    b.Parent = parent
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, 6)
    c.Parent = b
    return b
end

local minusBtn = smallBtn("Size -", 0, 0, 0.33, -2, sizeRow)
local resetBtn = smallBtn("1x",     0.33, 1, 0.34, -2, sizeRow)
local plusBtn  = smallBtn("Size +", 0.67, 2, 0.33, 0, sizeRow)

minusBtn.MouseButton1Click:Connect(function()
    scaleIndex = math.max(1, scaleIndex - 1)
    local ok, err = applyScale()
    if not ok then notify(tostring(err)) end
    resetBtn.Text = ("%.2fx"):format(SCALES[scaleIndex])
end)

plusBtn.MouseButton1Click:Connect(function()
    scaleIndex = math.min(#SCALES, scaleIndex + 1)
    local ok, err = applyScale()
    if not ok then notify(tostring(err)) end
    resetBtn.Text = ("%.2fx"):format(SCALES[scaleIndex])
end)

resetBtn.MouseButton1Click:Connect(function()
    scaleIndex = 4
    applyScale()
    resetBtn.Text = "1x"
end)

sectionLabel("EMOTES", 104)

local emoteFrame = Instance.new("Frame")
emoteFrame.Size = UDim2.new(1, -4, 0, 60)
emoteFrame.BackgroundTransparency = 1
emoteFrame.BorderSizePixel = 0
emoteFrame.LayoutOrder = 105
emoteFrame.Parent = list

local grid = Instance.new("UIGridLayout")
grid.CellSize = UDim2.new(1 / 3, -4, 0, 28)
grid.CellPadding = UDim2.new(0, 4, 0, 4)
grid.SortOrder = Enum.SortOrder.LayoutOrder
grid.Parent = emoteFrame

for i, e in ipairs(EMOTES) do
    local b = Instance.new("TextButton")
    b.BackgroundColor3 = Color3.fromRGB(34, 34, 40)
    b.Text = e.name
    b.TextColor3 = Color3.fromRGB(210, 210, 218)
    b.Font = Enum.Font.Gotham
    b.TextSize = 11
    b.BorderSizePixel = 0
    b.AutoButtonColor = false
    b.LayoutOrder = i
    b.Parent = emoteFrame

    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, 6)
    c.Parent = b

    b.MouseButton1Click:Connect(function()
        local ok, err = playEmote(e.id)
        if ok then
            setStatus("emote: " .. e.name)
        else
            notify("Emote: " .. tostring(err))
        end
    end)
end

-- drag
local dragging, dragStart, startPos
header.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1
    or input.UserInputType == Enum.UserInputType.Touch then
        dragging = true
        dragStart = input.Position
        startPos = main.Position
    end
end)

UIS.InputChanged:Connect(function(input)
    if not dragging then return end
    if input.UserInputType == Enum.UserInputType.MouseMovement
    or input.UserInputType == Enum.UserInputType.Touch then
        local delta = input.Position - dragStart
        main.Position = UDim2.new(
            startPos.X.Scale, startPos.X.Offset + delta.X,
            startPos.Y.Scale, startPos.Y.Offset + delta.Y
        )
    end
end)

UIS.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1
    or input.UserInputType == Enum.UserInputType.Touch then
        dragging = false
    end
end)

-- reopen button
local reopen = Instance.new("TextButton")
reopen.Size = UDim2.fromOffset(40, 40)
reopen.Position = UDim2.new(0, 24, 0.5, 200)
reopen.BackgroundColor3 = Color3.fromRGB(30, 30, 36)
reopen.Text = "="
reopen.TextColor3 = Color3.fromRGB(230, 230, 235)
reopen.TextSize = 20
reopen.Font = Enum.Font.GothamBold
reopen.BorderSizePixel = 0
reopen.Visible = false
reopen.Parent = screen

local reopenCorner = Instance.new("UICorner")
reopenCorner.CornerRadius = UDim.new(1, 0)
reopenCorner.Parent = reopen

local function setVisible(v)
    state.uiOpen = v
    main.Visible = v
    reopen.Visible = not v
end

hide.MouseButton1Click:Connect(function() setVisible(false) end)
reopen.MouseButton1Click:Connect(function() setVisible(true) end)

UIS.InputBegan:Connect(function(input, gp)
    if gp then return end
    if input.KeyCode == Enum.KeyCode.RightShift then
        setVisible(not state.uiOpen)
    end
end)

refreshRows()
notify("Loaded - RightShift to toggle")

genv.Util = {
    state = state,
    setFeature = setFeature,
}
