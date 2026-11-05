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

local function noclipOff()
    state.noclip = false
    if noclipConn then noclipConn:Disconnect(); noclipConn = nil end
    local c = LP.Character
    if c then
        for _, p in ipairs(c:GetDescendants()) do
            if p:IsA("BasePart") then p.CanCollide = true end
        end
    end
end

local function noclipOn()
    if not LP.Character then return false end
    state.noclip = true
    if noclipConn then noclipConn:Disconnect() end
    noclipConn = RunService.Stepped:Connect(function()
        local c = LP.Character
        if not c then return end
        for _, p in ipairs(c:GetDescendants()) do
            if p:IsA("BasePart") and p.CanCollide then p.CanCollide = false end
        end
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
        local ok = pcall(setFeature, feat.key, not state[feat.key])
        if not ok then notify(feat.label .. " unavailable in this game") end
        refreshRows()
    end)

    rows[feat.key] = row
end

-- teleport-to-player box
local tpBox = Instance.new("TextBox")
tpBox.Size = UDim2.new(1, -4, 0, 30)
tpBox.BackgroundColor3 = Color3.fromRGB(34, 34, 40)
tpBox.PlaceholderText = "Player name -> Enter to teleport"
tpBox.Text = ""
tpBox.TextColor3 = Color3.fromRGB(220, 220, 226)
tpBox.PlaceholderColor3 = Color3.fromRGB(120, 120, 130)
tpBox.Font = Enum.Font.Gotham
tpBox.TextSize = 12
tpBox.BorderSizePixel = 0
tpBox.ClearTextOnFocus = false
tpBox.LayoutOrder = 100
tpBox.Parent = list

local tpCorner = Instance.new("UICorner")
tpCorner.CornerRadius = UDim.new(0, 6)
tpCorner.Parent = tpBox

tpBox.FocusLost:Connect(function(enterPressed)
    if not enterPressed then return end
    local name = tpBox.Text
    if name == "" then return end

    local target
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LP and plr.Name:lower():sub(1, #name) == name:lower() then
            target = plr
            break
        end
    end
    if not target then
        notify("No player matching: " .. name)
        return
    end

    local _, _, hrp = getChar()
    local tchar = target.Character
    local thrp = tchar and tchar:FindFirstChild("HumanoidRootPart")
    if hrp and thrp then
        hrp.CFrame = thrp.CFrame + Vector3.new(0, 0, 2)
        notify("Teleported to " .. target.Name)
    else
        notify("Target has no loaded character")
    end
end)

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
