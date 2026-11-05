--[[
    Universal Client Utility - clean rebuild of the one-liner loader pattern
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

-- Executors differ: some lack getgenv, a few lack loadstring. Neither is
-- required for the UI, so degrade instead of aborting the whole script.
local function trace(msg)
    pcall(function() print("[Utility] " .. msg) end)
end

trace("start")

local function sharedEnv()
    if type(getgenv) == "function" then
        local ok, g = pcall(getgenv)
        if ok and type(g) == "table" then return g end
    end
    if type(getrenv) == "function" then
        local ok, g = pcall(getrenv)
        if ok and type(g) == "table" then return g end
    end
    return _G
end

local Players     = game:GetService("Players")
local RunService  = game:GetService("RunService")
local UIS         = game:GetService("UserInputService")
local VirtualUser = game:GetService("VirtualUser")
local StarterGui  = game:GetService("StarterGui")

-- PromptShown fires client-side only for prompts the player is actually near,
-- which is what the auto-pickup toggle listens to.
local PromptService = game:GetService("ProximityPromptService")

local LP   = Players.LocalPlayer
local genv = sharedEnv()

local flySpeed = 55
local walkSpeedValue = 16
local walkSpeedTouched = false

-- ---------------------------------------------------------------- state

local state = {
    fly        = false,
    noclip     = false,
    esp        = false,
    invisible  = false,
    infJump    = false,
    clickTP    = false,
    freecam    = false,
    fullbright = false,
    speedLock  = false,
    uiOpen     = true,
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

-- Some games parent the visible character somewhere other than Player.Character.
local function findWorkspaceModel(plr)
    for _, obj in ipairs(workspace:GetChildren()) do
        if obj:IsA("Model") and (obj.Name == plr.Name or obj.Name == plr.DisplayName) then
            return obj
        end
    end
    return nil
end

-- Root part lookup that survives custom rigs and late character loads.
local function getTargetRoot(plr)
    if not plr then return nil end
    local c = plr.Character or findWorkspaceModel(plr)
    if not c then return nil end
    local hrp = c:FindFirstChild("HumanoidRootPart")
    if hrp then return hrp end
    local hum = c:FindFirstChildOfClass("Humanoid")
    if hum and hum.RootPart then return hum.RootPart end
    return c.PrimaryPart
end

local function resolveRoot(plr, timeout)
    local root = getTargetRoot(plr)
    if root then return root end
    local deadline = os.clock() + (timeout or 2)
    while os.clock() < deadline do
        task.wait(0.1)
        root = getTargetRoot(plr)
        if root then return root end
    end
    return nil
end

local function describeTarget(plr)
    if not plr then return "no player matched" end
    local c = plr.Character
    local model = c or findWorkspaceModel(plr)
    return ("%s (@%s, id=%d) char=%s model=%s root=%s"):format(
        plr.Name, plr.DisplayName, plr.UserId,
        tostring(c ~= nil),
        tostring(model ~= nil),
        tostring(getTargetRoot(plr) ~= nil)
    )
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
        local _, hum2, root = getChar()
        if not root then return end
        local cam = workspace.CurrentCamera
        if not cam then return end

        -- Some games delete foreign constraints every frame; put them back.
        if not flyBV or flyBV.Parent ~= root then
            flyBV = Instance.new("BodyVelocity")
            flyBV.MaxForce = Vector3.new(1e5, 1e5, 1e5)
            flyBV.Parent = root
        end
        if not flyBG or flyBG.Parent ~= root then
            flyBG = Instance.new("BodyGyro")
            flyBG.MaxTorque = Vector3.new(1e5, 1e5, 1e5)
            flyBG.P = 1e4
            flyBG.Parent = root
        end
        if hum2 and not hum2.PlatformStand then
            hum2.PlatformStand = true
        end

        local dir = Vector3.zero
        if UIS:IsKeyDown(Enum.KeyCode.W) then dir += cam.CFrame.LookVector end
        if UIS:IsKeyDown(Enum.KeyCode.S) then dir -= cam.CFrame.LookVector end
        if UIS:IsKeyDown(Enum.KeyCode.D) then dir += cam.CFrame.RightVector end
        if UIS:IsKeyDown(Enum.KeyCode.A) then dir -= cam.CFrame.RightVector end
        if UIS:IsKeyDown(Enum.KeyCode.Space) then dir += Vector3.yAxis end
        if UIS:IsKeyDown(Enum.KeyCode.LeftControl) then dir -= Vector3.yAxis end
        if dir.Magnitude > 0 then dir = dir.Unit end

        flyBV.Velocity = dir * flySpeed
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

-- Who simulates your character, and whether the game opted into Server Authority.
-- Movement only reaches other players when you own the character and the game
-- still accepts client physics.
local function netReport()
    local _, _, hrp = getChar()
    if not hrp then return "no character" end

    local owner = "unknown"
    pcall(function()
        local o = hrp:GetNetworkOwner()
        owner = o and o.Name or "server"
    end)

    local authority = "n/a"
    local okA, mode = pcall(function() return workspace.AuthorityMode end)
    if okA and mode ~= nil then
        local name = "?"
        pcall(function() name = mode.Name end)
        if tostring(name):lower():find("enabled") then
            authority = "ON"
        else
            authority = "off"
        end
    end

    return ("owner=%s  authority=%s"):format(owner, authority)
end

-- Nudges the character up and checks whether the server kept it. If the move
-- sticks, other players see your movement too; if it snaps back, the server
-- owns the character and no client movement feature can work.
local function testMovementReplication()
    local _, _, hrp = getChar()
    if not hrp then return "test: no character" end

    local startY = hrp.Position.Y
    hrp.CFrame = hrp.CFrame + Vector3.new(0, 6, 0)
    task.wait(0.3)

    local _, _, after = getChar()
    if not after then return "test: character lost" end

    local lift = after.Position.Y - startY
    if lift > 2 then
        return ("test: server accepted movement (+%.1f studs) - others see it"):format(lift)
    end
    return ("test: server rejected movement (%.1f studs) - client physics blocked"):format(lift)
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

-- ---------------------------------------------------------------- invisible
-- Roblox only replicates physics state (CFrame/velocity) and animations from a
-- client. Property writes such as Transparency never leave your machine, so
-- there is no client-side way to hide from other players. This hides you on
-- your own screen only.

local invisConn

local function invisibleSweep()
    local c = LP.Character
    if not c then return end
    for _, p in ipairs(c:GetDescendants()) do
        if p:IsA("BasePart") then
            p.LocalTransparencyModifier = 1
        end
    end
end

local function invisibleOff()
    state.invisible = false
    if invisConn then invisConn:Disconnect(); invisConn = nil end
    local c = LP.Character
    if c then
        for _, p in ipairs(c:GetDescendants()) do
            if p:IsA("BasePart") then
                pcall(function() p.LocalTransparencyModifier = 0 end)
            end
        end
    end
end

local function invisibleOn()
    local c = LP.Character
    if not c then return false end
    state.invisible = true
    if invisConn then invisConn:Disconnect() end
    invisConn = RunService.Stepped:Connect(invisibleSweep)
    invisibleSweep()
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

-- ---------------------------------------------------------------- freecam / lighting / auto click

local freecamConn, freecamCF
local freecamSpeed = 40
local freecamFrozen

-- Freecam is only useful if the character stops walking while you look around.
-- Pin the humanoid instead of anchoring the root part: anchoring a part the
-- server still simulates causes rubber-banding.
local function freezeCharacter(on)
    local _, hum = getChar()
    if not hum then return end

    if on then
        if freecamFrozen then return end
        freecamFrozen = {
            WalkSpeed = hum.WalkSpeed,
            JumpPower = hum.JumpPower,
            AutoRotate = hum.AutoRotate,
        }
        hum.WalkSpeed = 0
        hum.JumpPower = 0
        hum.AutoRotate = false
        pcall(function() hum:Move(Vector3.zero, false) end)
    else
        local saved = freecamFrozen
        freecamFrozen = nil
        if not saved then return end
        pcall(function()
            hum.WalkSpeed = saved.WalkSpeed
            hum.JumpPower = saved.JumpPower
            hum.AutoRotate = saved.AutoRotate
        end)
        -- The walk speed slider may have moved while freecam was on.
        if walkSpeedTouched then hum.WalkSpeed = walkSpeedValue end
    end
end

local function freecamOn()
    local cam = workspace.CurrentCamera
    if not cam then return false end
    if state.freecam then return true end

    state.freecam = true
    freecamCF = cam.CFrame
    cam.CameraType = Enum.CameraType.Scriptable
    freezeCharacter(true)

    -- Bind at camera priority instead of RenderStepped: the camera update then
    -- runs in the same phase as the default camera, which removes the one-frame
    -- lag between input and view. Same approach as Infinite Yield's freecam.
    RunService:BindToRenderStep("UtilFreecam", Enum.RenderPriority.Camera.Value + 1, function(dt)
        -- Joystick and keyboard input keep pushing the humanoid; cancel it.
        local _, hum = getChar()
        if hum then
            hum.WalkSpeed = 0
            pcall(function() hum:Move(Vector3.zero, false) end)
        end

        local move = Vector3.new(0, 0, 0)
        if UIS:IsKeyDown(Enum.KeyCode.W) then move += freecamCF.LookVector end
        if UIS:IsKeyDown(Enum.KeyCode.S) then move -= freecamCF.LookVector end
        if UIS:IsKeyDown(Enum.KeyCode.D) then move += freecamCF.RightVector end
        if UIS:IsKeyDown(Enum.KeyCode.A) then move -= freecamCF.RightVector end
        if UIS:IsKeyDown(Enum.KeyCode.Space) then move += Vector3.new(0, 1, 0) end
        if UIS:IsKeyDown(Enum.KeyCode.LeftControl) then move -= Vector3.new(0, 1, 0) end

        if UIS:IsKeyDown(Enum.KeyCode.Q) then
            freecamCF = freecamCF * CFrame.Angles(0, math.rad(70 * dt), 0)
        end
        if UIS:IsKeyDown(Enum.KeyCode.E) then
            freecamCF = freecamCF * CFrame.Angles(0, math.rad(-70 * dt), 0)
        end

        if move.Magnitude > 0 then
            freecamCF = freecamCF + move.Unit * freecamSpeed * dt
        end
        cam.CFrame = freecamCF
    end)

    return true
end

local function freecamOff()
    state.freecam = false
    if freecamConn then freecamConn:Disconnect(); freecamConn = nil end
    pcall(function() RunService:UnbindFromRenderStep("UtilFreecam") end)
    freezeCharacter(false)
    local cam = workspace.CurrentCamera
    if cam then
        cam.CameraType = Enum.CameraType.Custom
        local _, hum = getChar()
        if hum then cam.CameraSubject = hum end
    end
end

-- Touch drag rotates the freecam, so it is usable on phones too.
local freecamTouch, freecamTouchPos

UIS.InputBegan:Connect(function(input, gp)
    if not state.freecam or gp then return end
    if input.UserInputType == Enum.UserInputType.Touch then
        freecamTouch = input
        freecamTouchPos = input.Position
    end
end)

UIS.InputChanged:Connect(function(input)
    if not state.freecam or not freecamTouch or input ~= freecamTouch then return end
    local delta = input.Position - freecamTouchPos
    freecamTouchPos = input.Position
    freecamCF = freecamCF * CFrame.fromEulerAnglesYXZ(
        math.rad(-delta.Y * 0.35),
        math.rad(-delta.X * 0.35),
        0
    )
end)

UIS.InputEnded:Connect(function(input)
    if freecamTouch and input == freecamTouch then
        freecamTouch = nil
    end
end)

local lightingSaved

local function fullbrightOn()
    local L = game:GetService("Lighting")
    if not lightingSaved then
        lightingSaved = {
            Brightness = L.Brightness,
            Ambient = L.Ambient,
            OutdoorAmbient = L.OutdoorAmbient,
            FogEnd = L.FogEnd,
            FogStart = L.FogStart,
            ClockTime = L.ClockTime,
            GlobalShadows = L.GlobalShadows,
        }
    end
    L.Brightness = 3
    L.Ambient = Color3.fromRGB(255, 255, 255)
    L.OutdoorAmbient = Color3.fromRGB(255, 255, 255)
    L.FogStart = 1e6
    L.FogEnd = 1e6
    L.GlobalShadows = false
    L.ClockTime = 12
    state.fullbright = true
    return true
end

local function fullbrightOff()
    state.fullbright = false
    if not lightingSaved then return end
    local L = game:GetService("Lighting")
    local saved = lightingSaved
    lightingSaved = nil
    pcall(function()
        L.Brightness = saved.Brightness
        L.Ambient = saved.Ambient
        L.OutdoorAmbient = saved.OutdoorAmbient
        L.FogStart = saved.FogStart
        L.FogEnd = saved.FogEnd
        L.ClockTime = saved.ClockTime
        L.GlobalShadows = saved.GlobalShadows
    end)
end

-- Many games rewrite Humanoid.WalkSpeed every frame. This keeps your value.
local speedLockThread

local function speedLockOn()
    state.speedLock = true
    if speedLockThread then return true end
    speedLockThread = task.spawn(function()
        while state.speedLock do
            -- Freecam pins WalkSpeed to 0 on purpose; do not fight it.
            local _, hum = getChar()
            if hum and not state.freecam and hum.WalkSpeed ~= walkSpeedValue then
                hum.WalkSpeed = walkSpeedValue
            end
            task.wait(0.25)
        end
        speedLockThread = nil
    end)
    return true
end

local function speedLockOff()
    state.speedLock = false
end

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
    elseif key == "invisible" then
        if on then
            local ok = invisibleOn()
            if ok then
                setStatus("invisible: your screen only - others still see you")
            end
            return ok
        end
        invisibleOff()
        return true
    elseif key == "freecam" then
        if on then return freecamOn() end
        freecamOff()
        return true
    elseif key == "fullbright" then
        if on then return fullbrightOn() end
        fullbrightOff()
        return true
    elseif key == "speedLock" then
        if on then return speedLockOn() end
        speedLockOff()
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
    if hum and walkSpeedTouched then hum.WalkSpeed = walkSpeedValue end
    if state.noclip then noclipOn() end
    if state.invisible then invisibleOn() end
    if state.freecam then freecamOff(); freecamOn() end
end)

-- ---------------------------------------------------------------- avatar tools

local SCALES = { 0.1, 0.2, 0.3, 0.4, 0.6, 0.8, 1, 1.4, 2, 3, 5, 8, 12, 20 }
local SCALE_RESET_INDEX = 7
local scaleIndex = SCALE_RESET_INDEX

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

-- Curated from community emote tables (Eazvy hub, DevForum lists).
-- cat: "dance" | "kpop" | "viral". Some are UGC assets: if one is private
-- in your region the button reports "load blocked" instead of playing.
local EMOTE_DB = {
    -- classic / dance
    { name = "Dance",           id = 507771019,        cat = "dance" },
    { name = "Dance2",          id = 507776043,        cat = "dance" },
    { name = "Wave",            id = 507770239,        cat = "dance" },
    { name = "Point",           id = 507770453,        cat = "dance" },
    { name = "Laugh",           id = 507770818,        cat = "dance" },
    { name = "Cheer",           id = 507770677,        cat = "dance" },
    { name = "Floss",           id = 5917459365,       cat = "dance" },
    { name = "Hype",            id = 3695333486,       cat = "dance" },
    { name = "Shuffle",         id = 4349242221,       cat = "dance" },
    { name = "Break Dance",     id = 5915648917,       cat = "dance" },
    { name = "Robot",           id = 3338025566,       cat = "dance" },
    { name = "Zombie",          id = 4210116953,       cat = "dance" },
    { name = "Dolphin",         id = 5918726674,       cat = "dance" },
    { name = "Samba",           id = 6869766175,       cat = "dance" },
    { name = "Cha-Cha",         id = 6862001787,       cat = "dance" },
    { name = "Monkey",          id = 3333499508,       cat = "dance" },
    { name = "Old Town Road",   id = 5937560570,       cat = "dance" },
    { name = "Holiday",         id = 5937558680,       cat = "dance" },
    { name = "Rodeo",           id = 5918728267,       cat = "dance" },
    { name = "Panini",          id = 5915713518,       cat = "dance" },
    { name = "Country Line",    id = 5915712534,       cat = "dance" },
    { name = "Swag Walk",       id = 10478341260,      cat = "dance" },
    { name = "Chicken Dance",   id = 4841399916,       cat = "dance" },
    { name = "Cartwheel",       id = 10370351535,      cat = "dance" },
    { name = "Boom Boom Clap",  id = 10370346995,      cat = "dance" },
    { name = "Super Charge",    id = 10478338114,      cat = "dance" },
    { name = "Mini Kong",       id = 17000021306,      cat = "dance" },
    { name = "Fashion Spin",    id = 131669256082047,  cat = "dance" },
    { name = "Secret Handshake",id = 71243990877913,   cat = "dance" },
    { name = "Bone Chillin",    id = 15122972413,      cat = "dance" },
    { name = "Festive Dance",   id = 15679621440,      cat = "dance" },
    { name = "Wanna play",      id = 16646423316,      cat = "dance" },
    { name = "Skadoosh",        id = 16371217304,      cat = "dance" },
    { name = "TMNT Dance",      id = 18665811005,      cat = "dance" },
    { name = "NBA Dunk",        id = 132748833449150,  cat = "dance" },
    { name = "Man City Backflip",id = 13694100677,     cat = "dance" },

    -- viral
    { name = "Sturdy",          id = 17746180844,      cat = "viral" },
    { name = "Apple",           id = 18946844622,      cat = "viral" },
    { name = "HOT TO GO",       id = 85267023718407,   cat = "viral" },
    { name = "Rasputin",        id = 114872820353992,  cat = "viral" },
    { name = "Squid Thanos",    id = 97611664803614,   cat = "viral" },
    { name = "Young-hee",       id = 112011282168475,  cat = "viral" },
    { name = "M3GAN",           id = 99649534578309,   cat = "viral" },
    { name = "SpongeBob",       id = 18443245017,      cat = "viral" },
    { name = "Skibidi",         id = 134283166482394,  cat = "viral" },
    { name = "Shrek Roar",      id = 18524313628,      cat = "viral" },
    { name = "Vroom Vroom",     id = 18526397037,      cat = "viral" },
    { name = "Zabb",            id = 129470135909814,  cat = "viral" },
    { name = "KSI Show Dem",    id = 7198989668,       cat = "viral" },
    { name = "Nicki Anaconda",  id = 15571450952,      cat = "viral" },
    { name = "Olivia good 4 u", id = 15517862739,      cat = "viral" },
    { name = "Bones",           id = 15689279687,      cat = "viral" },
    { name = "GloRilla",        id = 15689278184,      cat = "viral" },
    { name = "HIPMOTION",       id = 16572740012,      cat = "viral" },
    { name = "Starboy",         id = 71105746210464,   cat = "viral" },
    { name = "Fashion Roadkill",id = 136831243854748,  cat = "viral" },
    { name = "ALTEGO",          id = 107875941017127,  cat = "viral" },
    { name = "Klossette",       id = 80995190624232,   cat = "viral" },
    { name = "Baby Queen",      id = 14352362059,      cat = "viral" },
    { name = "Paris Hilton",    id = 15392759696,      cat = "viral" },

    -- kpop
    { name = "Pink Venom",      id = 14548619594,      cat = "kpop" },
    { name = "Pink Venom 2",    id = 14548620495,      cat = "kpop" },
    { name = "Shut Down",       id = 14901306096,      cat = "kpop" },
    { name = "Jisoo Flower",    id = 15439354020,      cat = "kpop" },
    { name = "Jennie You & Me", id = 15439356296,      cat = "kpop" },
    { name = "Ice Cream",       id = 16181797368,      cat = "kpop" },
    { name = "Kill This Love",  id = 16181798319,      cat = "kpop" },
    { name = "Boombayah",       id = 16553164850,      cat = "kpop" },
    { name = "DDU-DU",          id = 16553170471,      cat = "kpop" },
    { name = "How You Like That",id = 16874470507,     cat = "kpop" },
    { name = "Lovesick Girls",  id = 16874472321,      cat = "kpop" },
    { name = "As If Your Last", id = 18855536648,      cat = "kpop" },
    { name = "Lisa Money",      id = 15679623052,      cat = "kpop" },
    { name = "Rose On Ground",  id = 15679624464,      cat = "kpop" },
    { name = "TWICE The Feels", id = 12874447851,      cat = "kpop" },
    { name = "TWICE What Is Love",id = 13327655243,    cat = "kpop" },
    { name = "TWICE Fancy",     id = 13520524517,      cat = "kpop" },
    { name = "TWICE Pop",       id = 13768941455,      cat = "kpop" },
    { name = "TWICE LIKEY",     id = 14899979575,      cat = "kpop" },
    { name = "TWICE Feel Special",id = 14899980745,    cat = "kpop" },
    { name = "TWICE I Got You", id = 16215030041,      cat = "kpop" },
    { name = "TWICE ABCD",      id = 18933706381,      cat = "kpop" },
    { name = "TWICE Strategy",  id = 97311229290836,   cat = "kpop" },
    { name = "TWICE Takedown",  id = 140182843839424,  cat = "kpop" },
    { name = "NCT 2 Baddies",   id = 12259828678,      cat = "kpop" },
    { name = "NCT Kick It",     id = 12259826609,      cat = "kpop" },
    { name = "NCT Sticker",     id = 12259825026,      cat = "kpop" },
    { name = "Stray Kids",      id = 125064469983655,  cat = "kpop" },
    { name = "KATSEYE Touch",   id = 135876612109535,  cat = "kpop" },
    { name = "Sunmi Gashina",   id = 9527886709,       cat = "kpop" },
    { name = "Idol",            id = 4101966434,       cat = "kpop" },
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

local function stopEmote()
    if emoteTrack then
        pcall(function() emoteTrack:Stop(0.15) end)
        emoteTrack = nil
    end
    -- Re-trigger the default Animate script so the idle pose comes back.
    local c = LP.Character
    if c then
        local animate = c:FindFirstChild("Animate")
        if animate then
            animate.Disabled = true
            task.wait()
            animate.Disabled = false
        end
    end
    setStatus("emote stopped")
end

-- Fallback when ApplyDescription is blocked: copy the visible pieces directly.
local function copyClothingPiecewise(targetChar, myChar)
    local copied = 0

    local function copyClass(cls, prop)
        local src = targetChar:FindFirstChildOfClass(cls)
        if not src then return end
        local dst = myChar:FindFirstChildOfClass(cls)
        if not dst then
            local ok, created = pcall(function()
                local n = Instance.new(cls)
                n.Parent = myChar
                return n
            end)
            if not ok or not created then return end
            dst = created
        end
        pcall(function() dst[prop] = src[prop] end)
        copied += 1
    end

    copyClass("Shirt", "ShirtTemplate")
    copyClass("Pants", "PantsTemplate")

    local srcColors = targetChar:FindFirstChildOfClass("BodyColors")
    local dstColors = myChar:FindFirstChildOfClass("BodyColors")
    if srcColors and dstColors then
        for _, prop in ipairs({
            "HeadColor3", "LeftArmColor3", "RightArmColor3",
            "LeftLegColor3", "RightLegColor3", "TorsoColor3",
        }) do
            pcall(function() dstColors[prop] = srcColors[prop] end)
        end
        copied += 1
    end

    local myHum = myChar:FindFirstChildOfClass("Humanoid")
    for _, acc in ipairs(targetChar:GetChildren()) do
        if acc:IsA("Accessory") then
            local existing = myChar:FindFirstChild(acc.Name)
            if existing then existing:Destroy() end
            local clone = acc:Clone()
            local placed = false
            if myHum and myHum.AddAccessory then
                placed = pcall(function() myHum:AddAccessory(clone) end)
            end
            if not placed then
                clone.Parent = myChar
            end
            copied += 1
        end
    end

    return copied > 0
end

-- Copies appearance. Tries HumanoidDescription first, then piecewise clothing.
local function copyOutfit(query)
    local myChar, hum = getChar()
    if not hum then return false, "your character is not loaded" end

    local target, userId = resolveTarget(query)
    local targetChar = target and (target.Character or findWorkspaceModel(target)) or nil

    local desc
    if targetChar then
        local th = targetChar:FindFirstChildOfClass("Humanoid")
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

    if desc then
        local ok = pcall(function() hum:ApplyDescription(desc) end)
        if ok then return true, "description" end
    end

    if targetChar then
        if copyClothingPiecewise(targetChar, myChar) then
            return true, "clothing"
        end
        return false, "nothing copyable on target"
    end

    return false, "player not found and no description available"
end

-- Luau caps a function at 200 local variables. Everything below lives in
-- its own function so the UI handles do not exhaust the main chunk's slots.
local function buildUI()
    -- ---------------------------------------------------------------- ui

    local C = {
        bg     = Color3.fromRGB(16, 16, 20),
        panel  = Color3.fromRGB(23, 23, 28),
        row    = Color3.fromRGB(31, 31, 37),
        rowOn  = Color3.fromRGB(24, 58, 41),
        line   = Color3.fromRGB(44, 44, 52),
        text   = Color3.fromRGB(226, 226, 232),
        muted  = Color3.fromRGB(134, 134, 146),
        dim    = Color3.fromRGB(92, 92, 104),
        accent = Color3.fromRGB(92, 214, 143),
    }

    local parent = (gethui and gethui()) or LP:WaitForChild("PlayerGui")

    -- Re-running the loader replaces the old window instead of stacking a second one.
    for _, obj in ipairs(parent:GetChildren()) do
        if obj.Name == "UtilUI" then
            pcall(function() obj:Destroy() end)
        end
    end

    local screen = Instance.new("ScreenGui")
    screen.Name = "UtilUI"
    screen.ResetOnSpawn = false
    screen.IgnoreGuiInset = true
    screen.DisplayOrder = 999
    screen.Parent = parent

    local main = Instance.new("Frame")
    main.Name = "Main"
    main.Size = UDim2.fromOffset(300, 500)
    main.Position = UDim2.new(0, 24, 0.5, -250)
    main.BackgroundColor3 = C.bg
    main.BorderSizePixel = 0
    main.Active = true
    main.Parent = screen

    local mainCorner = Instance.new("UICorner")
    mainCorner.CornerRadius = UDim.new(0, 10)
    mainCorner.Parent = main

    local mainStroke = Instance.new("UIStroke")
    mainStroke.Color = C.line
    mainStroke.Thickness = 1
    mainStroke.Parent = main

    -- Phones report a small viewport, so a fixed 300x500 box can start with its
    -- header off-screen. Size the window from the viewport instead.
    local function fitMain()
        local cam = workspace.CurrentCamera
        if not cam then return end
        local vp = cam.ViewportSize
        if vp.X < 1 or vp.Y < 1 then return end

        local w = math.clamp(math.floor(vp.X * 0.48), 252, 360)
        local h = math.clamp(math.floor(vp.Y * 0.80), 300, 560)

        -- Never wider or taller than the screen it has to live in.
        w = math.min(w, vp.X - 16)
        h = math.min(h, vp.Y - 16)

        main.Size = UDim2.fromOffset(w, h)
        main.Position = UDim2.fromOffset(
            math.clamp(16, 0, math.max(0, vp.X - w)),
            math.max(0, math.floor((vp.Y - h) / 2))
        )
    end

    local header = Instance.new("Frame")
    header.Size = UDim2.new(1, 0, 0, 34)
    header.BackgroundColor3 = C.panel
    header.BorderSizePixel = 0
    header.Parent = main

    local headerCorner = Instance.new("UICorner")
    headerCorner.CornerRadius = UDim.new(0, 10)
    headerCorner.Parent = header

    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, -80, 1, 0)
    title.Position = UDim2.fromOffset(12, 0)
    title.BackgroundTransparency = 1
    title.Text = "Universal Utility"
    title.TextColor3 = C.text
    title.Font = Enum.Font.GothamMedium
    title.TextSize = 13
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Parent = header

    local hide = Instance.new("TextButton")
    hide.Size = UDim2.fromOffset(22, 22)
    hide.Position = UDim2.new(1, -30, 0, 6)
    hide.BackgroundColor3 = C.row
    hide.Text = "-"
    hide.TextColor3 = C.text
    hide.Font = Enum.Font.GothamBold
    hide.TextSize = 15
    hide.BorderSizePixel = 0
    hide.Parent = header

    local hideCorner = Instance.new("UICorner")
    hideCorner.CornerRadius = UDim.new(0, 6)
    hideCorner.Parent = hide

    -- ---------------------------------------------------------------- ui helpers

    local function sectionLabel(parentFrame, text, order)
        local lbl = Instance.new("TextLabel")
        lbl.Size = UDim2.new(1, -4, 0, 24)
        lbl.BackgroundTransparency = 1
        lbl.Text = text
        lbl.TextColor3 = C.dim
        lbl.Font = Enum.Font.GothamBold
        lbl.TextSize = 9
        lbl.TextXAlignment = Enum.TextXAlignment.Left
        lbl.TextYAlignment = Enum.TextYAlignment.Bottom
        lbl.LayoutOrder = order
        lbl.Parent = parentFrame
        return lbl
    end

    local function flatButton(parentFrame, text, order, height)
        local b = Instance.new("TextButton")
        b.Size = UDim2.new(1, -4, 0, height or 30)
        b.BackgroundColor3 = C.row
        b.Text = "  " .. text
        b.TextColor3 = C.text
        b.Font = Enum.Font.Gotham
        b.TextSize = 12
        b.TextXAlignment = Enum.TextXAlignment.Left
        b.AutoButtonColor = false
        b.BorderSizePixel = 0
        b.LayoutOrder = order
        b.Parent = parentFrame
        local c = Instance.new("UICorner")
        c.CornerRadius = UDim.new(0, 7)
        c.Parent = b
        return b
    end

    local function smallBtn(parentFrame, text, xScale, xOffset, widthScale, widthOffset)
        local b = Instance.new("TextButton")
        b.Size = UDim2.new(widthScale, widthOffset, 1, 0)
        b.Position = UDim2.new(xScale, xOffset, 0, 0)
        b.BackgroundColor3 = C.row
        b.Text = text
        b.TextColor3 = C.text
        b.Font = Enum.Font.Gotham
        b.TextSize = 11
        b.BorderSizePixel = 0
        b.AutoButtonColor = false
        b.Parent = parentFrame
        local c = Instance.new("UICorner")
        c.CornerRadius = UDim.new(0, 6)
        c.Parent = b
        return b
    end

    local function makeSlider(parentFrame, order, label, min, max, default, step, onChanged)
        local row = Instance.new("Frame")
        row.Size = UDim2.new(1, -4, 0, 42)
        row.BackgroundColor3 = C.row
        row.BorderSizePixel = 0
        row.LayoutOrder = order
        row.Parent = parentFrame

        local rc = Instance.new("UICorner")
        rc.CornerRadius = UDim.new(0, 7)
        rc.Parent = row

        local lbl = Instance.new("TextLabel")
        lbl.Size = UDim2.new(1, -16, 0, 16)
        lbl.Position = UDim2.fromOffset(10, 5)
        lbl.BackgroundTransparency = 1
        lbl.Text = label .. ": " .. tostring(default)
        lbl.TextColor3 = C.text
        lbl.Font = Enum.Font.Gotham
        lbl.TextSize = 11
        lbl.TextXAlignment = Enum.TextXAlignment.Left
        lbl.Parent = row

        local track = Instance.new("Frame")
        track.Size = UDim2.new(1, -20, 0, 6)
        track.Position = UDim2.new(0, 10, 1, -13)
        track.BackgroundColor3 = Color3.fromRGB(52, 52, 62)
        track.BorderSizePixel = 0
        track.Active = true
        track.Parent = row

        local tc = Instance.new("UICorner")
        tc.CornerRadius = UDim.new(1, 0)
        tc.Parent = track

        local fill = Instance.new("Frame")
        fill.Size = UDim2.new(0, 0, 1, 0)
        fill.BackgroundColor3 = Color3.fromRGB(70, 160, 100)
        fill.BorderSizePixel = 0
        fill.Parent = track

        local fc = Instance.new("UICorner")
        fc.CornerRadius = UDim.new(1, 0)
        fc.Parent = fill

        local knob = Instance.new("Frame")
        knob.Size = UDim2.fromOffset(12, 12)
        knob.AnchorPoint = Vector2.new(0.5, 0.5)
        knob.Position = UDim2.new(0, 0, 0.5, 0)
        knob.BackgroundColor3 = C.text
        knob.BorderSizePixel = 0
        knob.ZIndex = 2
        knob.Parent = track

        local kc = Instance.new("UICorner")
        kc.CornerRadius = UDim.new(1, 0)
        kc.Parent = knob

        local dragging = false

        local function apply(alpha, silent)
            alpha = math.clamp(alpha, 0, 1)
            local raw = min + (max - min) * alpha
            local value = math.floor(raw / step + 0.5) * step
            if value < min then value = min end
            if value > max then value = max end
            local a = (value - min) / (max - min)
            fill.Size = UDim2.new(a, 0, 1, 0)
            knob.Position = UDim2.new(a, 0, 0.5, 0)
            lbl.Text = label .. ": " .. tostring(value)
            if not silent then onChanged(value) end
            return value
        end

        local function fromX(px)
            local abs = track.AbsolutePosition.X
            local size = track.AbsoluteSize.X
            if size <= 0 then return end
            apply((px - abs) / size)
        end

        track.InputBegan:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
                dragging = true
                fromX(input.Position.X)
            end
        end)

        UIS.InputChanged:Connect(function(input)
            if not dragging then return end
            if input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch then
                fromX(input.Position.X)
            end
        end)

        UIS.InputEnded:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
                dragging = false
            end
        end)

        apply((default - min) / (max - min), true)

        return {
            set = function(v) apply((v - min) / (max - min)) end,
        }
    end

    -- ---------------------------------------------------------------- tabs

    local pages = {}
    local tabButtons = {}
    local activeTab = "main"
    local refreshPlayerList
    local renderRemotes

    local function selectTab(key)
        activeTab = key
        for k, page in pairs(pages) do
            page.Visible = (k == key)
        end
        for k, b in pairs(tabButtons) do
            local on = (k == key)
            b.BackgroundColor3 = on and C.rowOn or C.row
            b.TextColor3 = on and C.accent or C.muted
        end
        if key == "player" and refreshPlayerList then
            refreshPlayerList()
        end
        if key == "remotes" and renderRemotes then
            renderRemotes()
        end
    end

    local tabBar = Instance.new("Frame")
    tabBar.Size = UDim2.new(1, -14, 0, 26)
    tabBar.Position = UDim2.fromOffset(7, 40)
    tabBar.BackgroundTransparency = 1
    tabBar.BorderSizePixel = 0
    tabBar.Parent = main

    local tabDefs = {
        { key = "main",    label = "Main" },
        { key = "player",  label = "Player" },
        { key = "world",   label = "World" },
        { key = "avatar",  label = "Avatar" },
        { key = "emote",   label = "Emote" },
        { key = "remotes", label = "Remote" },
    }

    local tabWidth = 1 / #tabDefs

    for i, t in ipairs(tabDefs) do
        -- Equal widths, 3px gutters, no accumulated offset.
        local b = smallBtn(tabBar, t.label, (i - 1) * tabWidth, 2, tabWidth, -5)
        b.TextSize = 10
        b.BackgroundColor3 = C.row
        b.TextColor3 = C.muted
        tabButtons[t.key] = b
        b.MouseButton1Click:Connect(function() selectTab(t.key) end)

        local page = Instance.new("ScrollingFrame")
        page.Size = UDim2.new(1, -14, 1, -102)
        page.Position = UDim2.fromOffset(7, 72)
        page.BackgroundTransparency = 1
        page.BorderSizePixel = 0
        page.ScrollBarThickness = 2
        page.ScrollBarImageColor3 = C.line
        page.CanvasSize = UDim2.new(0, 0, 0, 0)
        page.AutomaticCanvasSize = Enum.AutomaticSize.Y
        page.Visible = false
        page.Parent = main

        local l = Instance.new("UIListLayout")
        l.Padding = UDim.new(0, 5)
        l.SortOrder = Enum.SortOrder.LayoutOrder
        l.Parent = page

        pages[t.key] = page
    end

    statusLabel = Instance.new("TextLabel")
    statusLabel.Size = UDim2.new(1, -14, 0, 20)
    statusLabel.Position = UDim2.new(0, 7, 1, -24)
    statusLabel.BackgroundTransparency = 1
    statusLabel.Text = "ready"
    statusLabel.TextColor3 = C.dim
    statusLabel.Font = Enum.Font.Gotham
    statusLabel.TextSize = 10
    statusLabel.TextXAlignment = Enum.TextXAlignment.Left
    statusLabel.TextTruncate = Enum.TextTruncate.AtEnd
    statusLabel.Parent = main

    local pageMain = pages["main"]
    local pagePlayer = pages["player"]
    local pageWorld = pages["world"]
    local pageAvatar = pages["avatar"]
    local pageEmote = pages["emote"]
    local pageRemotes = pages["remotes"]

    -- ---------------------------------------------------------------- main tab

    local rows = {}

    local function refreshRows()
        for key, row in pairs(rows) do
            local on = state[key]
            row.BackgroundColor3 = on and C.rowOn or C.row
            local lbl = row:FindFirstChild("Label")
            local st = row:FindFirstChild("State")
            if lbl then lbl.TextColor3 = on and C.accent or C.text end
            if st then
                st.Text = on and "ON" or "OFF"
                st.TextColor3 = on and C.accent or C.dim
            end
        end
    end

    local featureList = {
        { key = "fly",        label = "Fly",             note = "WASD, Space/Ctrl" },
        { key = "noclip",     label = "Noclip" },
        { key = "esp",        label = "Player ESP" },
        { key = "freecam",    label = "Freecam",         note = "WASD, Q/E" },
        { key = "invisible",  label = "Invisible",       note = "your screen only" },
        { key = "fullbright", label = "Fullbright" },
        { key = "speedLock",  label = "Lock walk speed" },
        { key = "infJump",    label = "Infinite jump" },
        { key = "clickTP",    label = "Click teleport" },
    }

    for i, feat in ipairs(featureList) do
        local row = Instance.new("TextButton")
        row.Size = UDim2.new(1, -4, 0, 34)
        row.BackgroundColor3 = C.row
        row.Text = ""
        row.AutoButtonColor = false
        row.BorderSizePixel = 0
        row.LayoutOrder = i
        row.Parent = pageMain

        local rc = Instance.new("UICorner")
        rc.CornerRadius = UDim.new(0, 7)
        rc.Parent = row

        local lbl = Instance.new("TextLabel")
        lbl.Name = "Label"
        lbl.Size = UDim2.new(1, -74, 1, 0)
        lbl.Position = UDim2.fromOffset(12, 0)
        lbl.BackgroundTransparency = 1
        lbl.RichText = true
        lbl.Text = feat.note
            and (feat.label .. "  <font color='#5c5c68'>" .. feat.note .. "</font>")
            or feat.label
        lbl.TextColor3 = C.text
        lbl.Font = Enum.Font.Gotham
        lbl.TextSize = 12
        lbl.TextXAlignment = Enum.TextXAlignment.Left
        lbl.TextTruncate = Enum.TextTruncate.AtEnd
        lbl.Parent = row

        local st = Instance.new("TextLabel")
        st.Name = "State"
        st.Size = UDim2.fromOffset(46, 1)
        st.Position = UDim2.new(1, -56, 0, 0)
        st.BackgroundTransparency = 1
        st.Text = "OFF"
        st.TextColor3 = C.dim
        st.Font = Enum.Font.GothamBold
        st.TextSize = 9
        st.TextXAlignment = Enum.TextXAlignment.Right
        st.Parent = row

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

    sectionLabel(pageMain, "SPEED", 50)

    makeSlider(pageMain, 51, "Walk speed", 16, 500, 16, 1, function(v)
        walkSpeedValue = v
        walkSpeedTouched = true
        local _, hum = getChar()
        if hum and not state.freecam then hum.WalkSpeed = v end
    end)

    makeSlider(pageMain, 52, "Fly speed", 10, 300, 55, 1, function(v)
        flySpeed = v
    end)

    sectionLabel(pageMain, "NETWORK", 60)

    local netLabel = Instance.new("TextLabel")
    netLabel.Size = UDim2.new(1, -4, 0, 16)
    netLabel.BackgroundTransparency = 1
    netLabel.Text = "checking..."
    netLabel.TextColor3 = C.muted
    netLabel.Font = Enum.Font.Code
    netLabel.TextSize = 9
    netLabel.TextXAlignment = Enum.TextXAlignment.Left
    netLabel.TextTruncate = Enum.TextTruncate.AtEnd
    netLabel.LayoutOrder = 61
    netLabel.Parent = pageMain

    local netHint = Instance.new("TextLabel")
    netHint.Size = UDim2.new(1, -4, 0, 0)
    netHint.AutomaticSize = Enum.AutomaticSize.Y
    netHint.BackgroundColor3 = C.panel
    netHint.BorderSizePixel = 0
    netHint.Text = "Movement and animations reach other players. Appearance (invisible, size, outfit) stays on your screen."
    netHint.TextColor3 = C.muted
    netHint.Font = Enum.Font.Gotham
    netHint.TextSize = 10
    netHint.TextXAlignment = Enum.TextXAlignment.Left
    netHint.TextYAlignment = Enum.TextYAlignment.Top
    netHint.TextWrapped = true
    netHint.LayoutOrder = 62
    netHint.Parent = pageMain

    local nhCorner = Instance.new("UICorner")
    nhCorner.CornerRadius = UDim.new(0, 7)
    nhCorner.Parent = netHint

    local nhPad = Instance.new("UIPadding")
    nhPad.PaddingTop = UDim.new(0, 8)
    nhPad.PaddingBottom = UDim.new(0, 8)
    nhPad.PaddingLeft = UDim.new(0, 10)
    nhPad.PaddingRight = UDim.new(0, 10)
    nhPad.Parent = netHint

    local testNetBtn = flatButton(pageMain, "Test what others can see", 63, 28)
    testNetBtn.TextXAlignment = Enum.TextXAlignment.Center

    testNetBtn.MouseButton1Click:Connect(function()
        setStatus("testing movement...")
        task.spawn(function()
            local result = testMovementReplication()
            netLabel.Text = result
            setStatus(result)
        end)
    end)

    -- Executor helpers are not standard Luau, so report what this build
    -- actually has. A missing helper then reads as a known limit, not a bug.
    sectionLabel(pageMain, "EXECUTOR", 70)

    local capLabel = Instance.new("TextLabel")
    capLabel.Size = UDim2.new(1, -4, 0, 0)
    capLabel.AutomaticSize = Enum.AutomaticSize.Y
    capLabel.BackgroundColor3 = C.panel
    capLabel.BorderSizePixel = 0
    capLabel.Text = ""
    capLabel.TextColor3 = C.muted
    capLabel.Font = Enum.Font.Code
    capLabel.TextSize = 9
    capLabel.TextXAlignment = Enum.TextXAlignment.Left
    capLabel.TextWrapped = true
    capLabel.LayoutOrder = 71
    capLabel.Parent = pageMain

    local capCorner = Instance.new("UICorner")
    capCorner.CornerRadius = UDim.new(0, 7)
    capCorner.Parent = capLabel

    local capPad = Instance.new("UIPadding")
    capPad.PaddingTop = UDim.new(0, 8)
    capPad.PaddingBottom = UDim.new(0, 8)
    capPad.PaddingLeft = UDim.new(0, 10)
    capPad.PaddingRight = UDim.new(0, 10)
    capPad.Parent = capLabel

    do
        local function has(name, value)
            return (value ~= nil) and "yes" or "no"
        end

        local lines = {
            ("prompt %s   click %s   touch %s"):format(
                has("fireproximityprompt", fireproximityprompt),
                has("fireclickdetector", fireclickdetector),
                has("firetouchinterest", firetouchinterest)
            ),
            ("hook %s   clipboard %s"):format(
                has("hookfunction", hookfunction),
                has("setclipboard", setclipboard)
            ),
        }
        capLabel.Text = table.concat(lines, "\n")
    end

    local function refreshNetLabel()
        netLabel.Text = netReport()
    end

    refreshNetLabel()

    task.spawn(function()
        while true do
            task.wait(2)
            if main.Visible and activeTab == "main" then
                refreshNetLabel()
            end
        end
    end)

    -- ---------------------------------------------------------------- player tab

    sectionLabel(pagePlayer, "TARGET", 1)

    local tpRow = Instance.new("Frame")
    tpRow.Size = UDim2.new(1, -4, 0, 64)
    tpRow.BackgroundTransparency = 1
    tpRow.BorderSizePixel = 0
    tpRow.LayoutOrder = 2
    tpRow.Parent = pagePlayer

    local tpBox = Instance.new("TextBox")
    tpBox.Size = UDim2.new(1, 0, 0, 28)
    tpBox.BackgroundColor3 = C.row
    tpBox.PlaceholderText = "username / display name / UserId"
    tpBox.Text = ""
    tpBox.TextColor3 = C.text
    tpBox.PlaceholderColor3 = C.dim
    tpBox.Font = Enum.Font.Gotham
    tpBox.TextSize = 12
    tpBox.BorderSizePixel = 0
    tpBox.ClearTextOnFocus = false
    tpBox.Parent = tpRow

    local tpCorner = Instance.new("UICorner")
    tpCorner.CornerRadius = UDim.new(0, 6)
    tpCorner.Parent = tpBox

    local function actionButton(parentFrame, text, position, color)
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
        b.Parent = parentFrame
        local c = Instance.new("UICorner")
        c.CornerRadius = UDim.new(0, 6)
        c.Parent = b
        return b
    end

    local goBtn    = actionButton(tpRow, "TP to",     UDim2.new(0, 0, 0, 32),   Color3.fromRGB(38, 70, 55))
    local bringBtn = actionButton(tpRow, "Bring here", UDim2.new(0.5, 3, 0, 32), Color3.fromRGB(74, 44, 44))

    local function tpToPlayer()
        local target = findPlayer(tpBox.Text)
        if not target then
            notify("No player matching: " .. tpBox.Text)
            return
        end
        local _, _, hrp = getChar()
        if not hrp then
            notify("Your character is not loaded")
            return
        end
        local troot = resolveRoot(target, 2)
        if not troot then
            notify("No root for " .. target.Name)
            setStatus(describeTarget(target))
            return
        end
        hrp.CFrame = troot.CFrame + Vector3.new(0, 0, 2)
        setStatus("teleported to " .. target.Name .. " (@" .. target.DisplayName .. ")")
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
        if not hrp then
            notify("Your character is not loaded")
            return
        end
        local troot = resolveRoot(target, 2)
        if not troot then
            notify("No root for " .. target.Name)
            setStatus(describeTarget(target))
            return
        end
        troot.CFrame = hrp.CFrame + Vector3.new(0, 0, 3)
        setStatus("bring attempt on " .. target.Name .. " - server may snap back")
    end)

    sectionLabel(pagePlayer, "PLAYERS (auto-refresh 6s)", 10)

    local playerSearch = Instance.new("TextBox")
    playerSearch.Size = UDim2.new(1, -4, 0, 28)
    playerSearch.BackgroundColor3 = C.row
    playerSearch.PlaceholderText = "search player..."
    playerSearch.Text = ""
    playerSearch.TextColor3 = C.text
    playerSearch.PlaceholderColor3 = C.dim
    playerSearch.Font = Enum.Font.Gotham
    playerSearch.TextSize = 12
    playerSearch.BorderSizePixel = 0
    playerSearch.ClearTextOnFocus = false
    playerSearch.LayoutOrder = 11
    playerSearch.Parent = pagePlayer

    local psCorner = Instance.new("UICorner")
    psCorner.CornerRadius = UDim.new(0, 6)
    psCorner.Parent = playerSearch

    local playerList = Instance.new("ScrollingFrame")
    playerList.Size = UDim2.new(1, -4, 0, 240)
    playerList.BackgroundColor3 = C.panel
    playerList.BorderSizePixel = 0
    playerList.ScrollBarThickness = 3
    playerList.CanvasSize = UDim2.new(0, 0, 0, 0)
    playerList.AutomaticCanvasSize = Enum.AutomaticSize.Y
    playerList.LayoutOrder = 12
    playerList.Parent = pagePlayer

    local plistCorner = Instance.new("UICorner")
    plistCorner.CornerRadius = UDim.new(0, 6)
    plistCorner.Parent = playerList

    local plistLayout = Instance.new("UIListLayout")
    plistLayout.Padding = UDim.new(0, 2)
    plistLayout.Parent = playerList

    refreshPlayerList = function()
        for _, ch in ipairs(playerList:GetChildren()) do
            if ch:IsA("TextButton") then ch:Destroy() end
        end

        local q = playerSearch.Text:lower()
        local count = 0
        for _, plr in ipairs(Players:GetPlayers()) do
            if plr ~= LP then
                local matches = (q == "")
                    or plr.Name:lower():find(q, 1, true)
                    or plr.DisplayName:lower():find(q, 1, true)
                if matches then
                    count += 1
                    local hasRoot = getTargetRoot(plr) ~= nil
                    local b = Instance.new("TextButton")
                    b.Size = UDim2.new(1, -6, 0, 26)
                    b.BackgroundColor3 = C.row
                    b.Text = ("  %s  (@%s)%s"):format(plr.Name, plr.DisplayName, hasRoot and "" or "  [no char]")
                    b.TextColor3 = hasRoot and Color3.fromRGB(200, 220, 210) or Color3.fromRGB(150, 130, 130)
                    b.Font = Enum.Font.Gotham
                    b.TextSize = 11
                    b.TextXAlignment = Enum.TextXAlignment.Left
                    b.TextTruncate = Enum.TextTruncate.AtEnd
                    b.AutoButtonColor = false
                    b.BorderSizePixel = 0
                    b.Parent = playerList

                    local c = Instance.new("UICorner")
                    c.CornerRadius = UDim.new(0, 4)
                    c.Parent = b

                    b.MouseButton1Click:Connect(function()
                        tpBox.Text = plr.Name
                        setStatus("selected " .. plr.Name .. " (@" .. plr.DisplayName .. ")")
                    end)
                end
            end
        end

        if count == 0 then
            local b = Instance.new("TextLabel")
            b.Size = UDim2.new(1, -6, 0, 26)
            b.BackgroundTransparency = 1
            b.Text = "  no players match"
            b.TextColor3 = C.dim
            b.Font = Enum.Font.Gotham
            b.TextSize = 11
            b.TextXAlignment = Enum.TextXAlignment.Left
            b.Parent = playerList
        end
    end

    playerSearch:GetPropertyChangedSignal("Text"):Connect(function()
        refreshPlayerList()
    end)

    refreshPlayerList()
    Players.PlayerAdded:Connect(function() task.delay(0.5, refreshPlayerList) end)
    Players.PlayerRemoving:Connect(function() task.delay(0.2, refreshPlayerList) end)

    task.spawn(function()
        while true do
            task.wait(6)
            if main.Visible and activeTab == "player" then
                refreshPlayerList()
            end
        end
    end)

    -- ---------------------------------------------------------------- world tab

    -- GetDescendants() walks the whole tree; on a big map that is the most
    -- expensive call here. Share one cached copy across ESP, scan, prompts and
    -- tools instead of walking the tree several times a second.
    local descCache, descAt = nil, 0

    local function workspaceDescendants()
        local now = os.clock()
        if descCache and (now - descAt) < 1.5 then return descCache end
        descCache = workspace:GetDescendants()
        descAt = now
        return descCache
    end

    local itemEsp = false
    local clickGrab = false
    local itemBoxes = {}

    sectionLabel(pageWorld, "ITEM FINDER", 1)

    local worldFilter = Instance.new("TextBox")
    worldFilter.Size = UDim2.new(1, -4, 0, 28)
    worldFilter.BackgroundColor3 = C.row
    worldFilter.PlaceholderText = "part name contains... e.g. Coin"
    worldFilter.Text = ""
    worldFilter.TextColor3 = C.text
    worldFilter.PlaceholderColor3 = C.dim
    worldFilter.Font = Enum.Font.Gotham
    worldFilter.TextSize = 12
    worldFilter.BorderSizePixel = 0
    worldFilter.ClearTextOnFocus = false
    worldFilter.LayoutOrder = 2
    worldFilter.Parent = pageWorld

    local wfCorner = Instance.new("UICorner")
    wfCorner.CornerRadius = UDim.new(0, 6)
    wfCorner.Parent = worldFilter

    local worldRow1 = Instance.new("Frame")
    worldRow1.Size = UDim2.new(1, -4, 0, 28)
    worldRow1.BackgroundTransparency = 1
    worldRow1.BorderSizePixel = 0
    worldRow1.LayoutOrder = 3
    worldRow1.Parent = pageWorld

    local espItemsBtn = smallBtn(worldRow1, "ESP: OFF", 0, 0, 0.5, -2)
    local grabBtn = smallBtn(worldRow1, "Grab: OFF", 0.5, 1, 0.5, -1)

    local worldRow2 = Instance.new("Frame")
    worldRow2.Size = UDim2.new(1, -4, 0, 28)
    worldRow2.BackgroundTransparency = 1
    worldRow2.BorderSizePixel = 0
    worldRow2.LayoutOrder = 4
    worldRow2.Parent = pageWorld

    local tpNearestBtn = smallBtn(worldRow2, "TP nearest", 0, 0, 0.5, -2)
    local pullBtn = smallBtn(worldRow2, "Pull all", 0.5, 1, 0.5, -1)

    local scanNamesBtn = flatButton(pageWorld, "Scan part names in this map", 5, 26)
    scanNamesBtn.TextXAlignment = Enum.TextXAlignment.Center

    local nameList = Instance.new("ScrollingFrame")
    nameList.Size = UDim2.new(1, -4, 0, 120)
    nameList.BackgroundColor3 = C.panel
    nameList.BorderSizePixel = 0
    nameList.ScrollBarThickness = 3
    nameList.CanvasSize = UDim2.new(0, 0, 0, 0)
    nameList.AutomaticCanvasSize = Enum.AutomaticSize.Y
    nameList.LayoutOrder = 6
    nameList.Parent = pageWorld

    local nlCorner = Instance.new("UICorner")
    nlCorner.CornerRadius = UDim.new(0, 6)
    nlCorner.Parent = nameList

    local nlLayout = Instance.new("UIListLayout")
    nlLayout.Padding = UDim.new(0, 2)
    nlLayout.Parent = nameList

    local hint = Instance.new("TextLabel")
    hint.Size = UDim2.new(1, -4, 0, 0)
    hint.AutomaticSize = Enum.AutomaticSize.Y
    hint.BackgroundColor3 = C.panel
    hint.BorderSizePixel = 0
    hint.Text = "Scan lists the part names this map uses, so you can filter for them. ESP, TP and Pull only move things on your client; the server can snap back anything it owns. Prompts and tools below go through the game itself. Take presses the map's own pickup, then checks your Backpack and equips whatever the server actually handed over. Coins and points go to the game's HUD, not the Backpack. Fast prompt mode skips the key hold, which some games can detect; Hold mode presses it for real."
    hint.TextColor3 = C.muted
    hint.Font = Enum.Font.Gotham
    hint.TextSize = 10
    hint.TextXAlignment = Enum.TextXAlignment.Left
    hint.TextYAlignment = Enum.TextYAlignment.Top
    hint.TextWrapped = true
    hint.LayoutOrder = 7
    hint.Parent = pageWorld

    local whCorner = Instance.new("UICorner")
    whCorner.CornerRadius = UDim.new(0, 7)
    whCorner.Parent = hint

    local whPad = Instance.new("UIPadding")
    whPad.PaddingTop = UDim.new(0, 8)
    whPad.PaddingBottom = UDim.new(0, 8)
    whPad.PaddingLeft = UDim.new(0, 10)
    whPad.PaddingRight = UDim.new(0, 10)
    whPad.Parent = hint

    sectionLabel(pageWorld, "WAYPOINTS", 8)

    local wpRow = Instance.new("Frame")
    wpRow.Size = UDim2.new(1, -4, 0, 28)
    wpRow.BackgroundTransparency = 1
    wpRow.BorderSizePixel = 0
    wpRow.LayoutOrder = 9
    wpRow.Parent = pageWorld

    local saveWpBtn = smallBtn(wpRow, "Save here", 0, 0, 0.62, -2)
    local clearWpBtn = smallBtn(wpRow, "Clear", 0.62, 1, 0.38, -1)

    local wpList = Instance.new("ScrollingFrame")
    wpList.Size = UDim2.new(1, -4, 0, 96)
    wpList.BackgroundColor3 = C.panel
    wpList.BorderSizePixel = 0
    wpList.ScrollBarThickness = 3
    wpList.CanvasSize = UDim2.new(0, 0, 0, 0)
    wpList.AutomaticCanvasSize = Enum.AutomaticSize.Y
    wpList.LayoutOrder = 10
    wpList.Parent = pageWorld

    local wlCorner = Instance.new("UICorner")
    wlCorner.CornerRadius = UDim.new(0, 6)
    wlCorner.Parent = wpList

    local wlLayout = Instance.new("UIListLayout")
    wlLayout.Padding = UDim.new(0, 2)
    wlLayout.Parent = wpList

    local waypoints = {}
    local wpCounter = 0

    local function renderWaypoints()
        for _, ch in ipairs(wpList:GetChildren()) do
            if ch:IsA("TextButton") then ch:Destroy() end
        end

        if #waypoints == 0 then
            local l = Instance.new("TextLabel")
            l.Size = UDim2.new(1, -6, 0, 24)
            l.BackgroundTransparency = 1
            l.Text = "  no waypoints yet"
            l.TextColor3 = C.dim
            l.Font = Enum.Font.Gotham
            l.TextSize = 10
            l.TextXAlignment = Enum.TextXAlignment.Left
            l.Parent = wpList
            return
        end

        for i, wp in ipairs(waypoints) do
            local b = Instance.new("TextButton")
            b.Size = UDim2.new(1, -6, 0, 24)
            b.BackgroundColor3 = C.row
            b.Text = ("  %d. %s"):format(i, wp.name)
            b.TextColor3 = C.text
            b.Font = Enum.Font.Gotham
            b.TextSize = 10
            b.TextXAlignment = Enum.TextXAlignment.Left
            b.AutoButtonColor = false
            b.BorderSizePixel = 0
            b.Parent = wpList

            local c = Instance.new("UICorner")
            c.CornerRadius = UDim.new(0, 4)
            c.Parent = b

            b.MouseButton1Click:Connect(function()
                local _, _, hrp = getChar()
                if not hrp then
                    notify("Character not loaded")
                    return
                end
                hrp.CFrame = wp.cf + Vector3.new(0, 3, 0)
                setStatus("tp to " .. wp.name)
            end)
        end
    end

    saveWpBtn.MouseButton1Click:Connect(function()
        local _, _, hrp = getChar()
        if not hrp then
            notify("Character not loaded")
            return
        end
        wpCounter += 1
        table.insert(waypoints, { name = "wp" .. wpCounter, cf = hrp.CFrame })
        if #waypoints > 12 then
            table.remove(waypoints, 1)
        end
        renderWaypoints()
        setStatus(("waypoint wp%d saved"):format(wpCounter))
    end)

    clearWpBtn.MouseButton1Click:Connect(function()
        waypoints = {}
        renderWaypoints()
        setStatus("waypoints cleared")
    end)

    renderWaypoints()

    local function clearItemBoxes()
        for part, box in pairs(itemBoxes) do
            if box then pcall(function() box:Destroy() end) end
            itemBoxes[part] = nil
        end
        itemBoxes = {}
    end

    local function matchingParts(q, limit)
        local out = {}
        if q == "" then return out end
        local ownChar = LP.Character
        for _, inst in ipairs(workspaceDescendants()) do
            if inst:IsA("BasePart") and inst.Name:lower():find(q, 1, true) then
                if not (ownChar and inst:IsDescendantOf(ownChar)) then
                    table.insert(out, inst)
                    if #out >= limit then break end
                end
            end
        end
        return out
    end

    local function sweepItemEsp()
        if not itemEsp then return end
        local q = worldFilter.Text:lower()
        if q == "" then
            clearItemBoxes()
            return
        end

        local alive = {}
        for _, part in ipairs(matchingParts(q, 200)) do
            alive[part] = true
            if not itemBoxes[part] then
                local box = Instance.new("SelectionBox")
                box.Adornee = part
                box.LineThickness = 0.03
                box.Color3 = Color3.fromRGB(120, 220, 150)
                box.SurfaceTransparency = 1
                box.Parent = part
                itemBoxes[part] = box
            end
        end

        for part, box in pairs(itemBoxes) do
            if not alive[part] or not part.Parent then
                pcall(function() box:Destroy() end)
                itemBoxes[part] = nil
            end
        end
    end

    local function tpNearestItem()
        local _, _, hrp = getChar()
        if not hrp then
            notify("Character not loaded")
            return
        end
        local q = worldFilter.Text:lower()
        if q == "" then
            notify("Filter empty - press Scan part names")
            setStatus("world: filter empty")
            return
        end
        local list = matchingParts(q, 400)
        if #list == 0 then
            notify("No part matches the filter")
            setStatus("world: no match for " .. q)
            return
        end

        local best, bestDist
        for _, part in ipairs(list) do
            local d = (part.Position - hrp.Position).Magnitude
            if not bestDist or d < bestDist then
                best, bestDist = part, d
            end
        end

        hrp.CFrame = best.CFrame + Vector3.new(0, 4, 0)
        setStatus(("tp to %s (%.0f studs)"):format(best.Name, bestDist))
    end

    local function pullAllItems()
        local _, _, hrp = getChar()
        if not hrp then
            notify("Character not loaded")
            return
        end
        local q = worldFilter.Text:lower()
        if q == "" then
            notify("Filter empty - press Scan part names")
            setStatus("world: filter empty")
            return
        end
        local list = matchingParts(q, 60)
        if #list == 0 then
            notify("No part matches the filter")
            setStatus("world: no match for " .. q)
            return
        end

        local n = 0
        for _, part in ipairs(list) do
            local offset = Vector3.new(math.random(-5, 5), 3 + math.random(0, 3), math.random(-5, 5))
            if pcall(function() part.CFrame = hrp.CFrame + offset end) then
                n += 1
            end
        end
        setStatus(("pulled %d parts - server may snap them back"):format(n))
    end

    local function grabFromScreen(x, y)
        local cam = workspace.CurrentCamera
        if not cam then return end

        local params = RaycastParams.new()
        local okEnum = pcall(function()
            params.FilterType = Enum.RaycastFilterType.Exclude
        end)
        if not okEnum then
            pcall(function() params.FilterType = Enum.RaycastFilterType.Blacklist end)
        end
        params.FilterDescendantsInstances = { LP.Character }

        local ray = cam:ViewportPointToRay(x, y)
        local hit = workspace:Raycast(ray.Origin, ray.Direction * 3000, params)
        if not hit or not hit.Instance then return end

        local part = hit.Instance
        local q = worldFilter.Text:lower()
        if q ~= "" and not part.Name:lower():find(q, 1, true) then
            setStatus("grab skipped: " .. part.Name)
            return
        end

        local _, _, hrp = getChar()
        if not hrp then return end

        part.CFrame = hrp.CFrame + Vector3.new(0, 4, 0)
        setStatus("grabbed " .. part.Name)
    end

    local function styleWorldBtns()
        espItemsBtn.Text = itemEsp and "ESP: ON" or "ESP: OFF"
        espItemsBtn.BackgroundColor3 = itemEsp and C.rowOn or C.row
        espItemsBtn.TextColor3 = itemEsp and C.accent or C.text

        grabBtn.Text = clickGrab and "Grab: ON" or "Grab: OFF"
        grabBtn.BackgroundColor3 = clickGrab and C.rowOn or C.row
        grabBtn.TextColor3 = clickGrab and C.accent or C.text
    end

    local function collectPartNames()
        local counts = {}
        for _, inst in ipairs(workspaceDescendants()) do
            if inst:IsA("BasePart") then
                counts[inst.Name] = (counts[inst.Name] or 0) + 1
            end
        end

        local list = {}
        for name, n in pairs(counts) do
            table.insert(list, { name = name, count = n })
        end
        table.sort(list, function(a, b)
            if a.count == b.count then return a.name < b.name end
            return a.count > b.count
        end)
        return list
    end

    local function renderPartNames()
        for _, ch in ipairs(nameList:GetChildren()) do
            if ch:IsA("TextButton") then ch:Destroy() end
        end

        local list = collectPartNames()
        if #list == 0 then
            local l = Instance.new("TextLabel")
            l.Size = UDim2.new(1, -6, 0, 24)
            l.BackgroundTransparency = 1
            l.Text = "  no parts found"
            l.TextColor3 = C.dim
            l.Font = Enum.Font.Gotham
            l.TextSize = 10
            l.TextXAlignment = Enum.TextXAlignment.Left
            l.Parent = nameList
            return 0
        end

        for i = 1, math.min(#list, 40) do
            local entry = list[i]
            local b = Instance.new("TextButton")
            b.Size = UDim2.new(1, -6, 0, 24)
            b.BackgroundColor3 = C.row
            b.Text = ("  %s   x%d"):format(entry.name, entry.count)
            b.TextColor3 = C.text
            b.Font = Enum.Font.Gotham
            b.TextSize = 10
            b.TextXAlignment = Enum.TextXAlignment.Left
            b.TextTruncate = Enum.TextTruncate.AtEnd
            b.AutoButtonColor = false
            b.BorderSizePixel = 0
            b.Parent = nameList

            local c = Instance.new("UICorner")
            c.CornerRadius = UDim.new(0, 4)
            c.Parent = b

            b.MouseButton1Click:Connect(function()
                worldFilter.Text = entry.name
                if not itemEsp then
                    itemEsp = true
                    styleWorldBtns()
                end
                sweepItemEsp()
                setStatus(("filter: %s (x%d)"):format(entry.name, entry.count))
            end)
        end

        return #list
    end

    scanNamesBtn.MouseButton1Click:Connect(function()
        local n = renderPartNames()
        setStatus(("world: %d unique part names"):format(n))
    end)

    espItemsBtn.MouseButton1Click:Connect(function()
        itemEsp = not itemEsp
        if not itemEsp then clearItemBoxes() end
        styleWorldBtns()
        sweepItemEsp()
        setStatus("item ESP " .. (itemEsp and "on" or "off"))
    end)

    grabBtn.MouseButton1Click:Connect(function()
        clickGrab = not clickGrab
        styleWorldBtns()
        setStatus("click grab " .. (clickGrab and "on - tap a part" or "off"))
    end)

    tpNearestBtn.MouseButton1Click:Connect(tpNearestItem)
    pullBtn.MouseButton1Click:Connect(pullAllItems)

    worldFilter:GetPropertyChangedSignal("Text"):Connect(function()
        if itemEsp then
            clearItemBoxes()
            sweepItemEsp()
        end
    end)

    UIS.InputBegan:Connect(function(input, gp)
        if gp or not clickGrab then return end
        if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
            grabFromScreen(input.Position.X, input.Position.Y)
        end
    end)

    task.spawn(function()
        while true do
            task.wait(1)
            if itemEsp and main.Visible and activeTab == "world" then
                sweepItemEsp()
            end
        end
    end)

    styleWorldBtns()

    -- Kept in its own function so its locals do not eat into buildUI's
    -- 200-variable budget.
    local function buildPromptsAndTools()
        -- ---------------------------------------------------------------- prompts / tools

        -- Games expose "pick up", "open", "buy", "sit" as ProximityPrompts. Firing a
        -- prompt goes through the game's own server handler, so the result is real
        -- and other players see it. No prompt means the game uses something else.
        sectionLabel(pageWorld, "PICKUP PROMPTS / CLICKS", 20)

        local promptRow = Instance.new("Frame")
        promptRow.Size = UDim2.new(1, -4, 0, 28)
        promptRow.BackgroundTransparency = 1
        promptRow.BorderSizePixel = 0
        promptRow.LayoutOrder = 21
        promptRow.Parent = pageWorld

        local promptScanBtn = smallBtn(promptRow, "Scan prompts", 0, 0, 0.5, -2)
        local promptNearBtn = smallBtn(promptRow, "Nearest", 0.5, 1, 0.5, -1)

        local promptOptRow = Instance.new("Frame")
        promptOptRow.Size = UDim2.new(1, -4, 0, 26)
        promptOptRow.BackgroundTransparency = 1
        promptOptRow.BorderSizePixel = 0
        promptOptRow.LayoutOrder = 22
        promptOptRow.Parent = pageWorld

        local modeBtn = smallBtn(promptOptRow, "Fast (bypass)", 0, 0, 0.46, -2)
        modeBtn.TextSize = 10
        local autoBtn = smallBtn(promptOptRow, "Auto in range: OFF", 0.46, 1, 0.54, -1)
        autoBtn.TextSize = 10

        local promptList = Instance.new("ScrollingFrame")
        promptList.Size = UDim2.new(1, -4, 0, 132)
        promptList.BackgroundColor3 = C.panel
        promptList.BorderSizePixel = 0
        promptList.ScrollBarThickness = 2
        promptList.CanvasSize = UDim2.new(0, 0, 0, 0)
        promptList.AutomaticCanvasSize = Enum.AutomaticSize.Y
        promptList.LayoutOrder = 23
        promptList.Parent = pageWorld

        local plCorner = Instance.new("UICorner")
        plCorner.CornerRadius = UDim.new(0, 7)
        plCorner.Parent = promptList

        local plLayout = Instance.new("UIListLayout")
        plLayout.Padding = UDim.new(0, 2)
        plLayout.Parent = promptList

        local function placeHolder(list, text)
            local l = Instance.new("TextLabel")
            l.Size = UDim2.new(1, -12, 0, 22)
            l.BackgroundTransparency = 1
            l.Text = text
            l.TextColor3 = C.dim
            l.Font = Enum.Font.Gotham
            l.TextSize = 10
            l.TextXAlignment = Enum.TextXAlignment.Left
            l.Parent = list
            return l
        end

        local function clearList(list)
            for _, ch in ipairs(list:GetChildren()) do
                if ch:IsA("TextButton") or ch:IsA("TextLabel") then ch:Destroy() end
            end
        end

        local function listRow(list, text, order)
            local b = Instance.new("TextButton")
            b.Size = UDim2.new(1, -8, 0, 24)
            b.BackgroundColor3 = C.row
            b.Text = "  " .. text
            b.TextColor3 = C.text
            b.Font = Enum.Font.Gotham
            b.TextSize = 10
            b.TextXAlignment = Enum.TextXAlignment.Left
            b.TextTruncate = Enum.TextTruncate.AtEnd
            b.AutoButtonColor = false
            b.BorderSizePixel = 0
            b.LayoutOrder = order or 0
            b.Parent = list

            local c = Instance.new("UICorner")
            c.CornerRadius = UDim.new(0, 5)
            c.Parent = b
            return b
        end

        -- The prompt sits on a part, but a ClickDetector often sits on a Model,
        -- which has no Position of its own. Fall back to its pivot.
        local function distanceTo(obj)
            local _, _, hrp = getChar()
            if not hrp or not obj then return math.huge end

            local ok, d = pcall(function() return (obj.Position - hrp.Position).Magnitude end)
            if ok and d then return d end

            local pOk, pivot = pcall(function() return obj:GetPivot().Position end)
            if pOk and pivot then return (pivot - hrp.Position).Magnitude end

            return math.huge
        end

        local function collectPrompts(limit)
            local out = {}
            for _, inst in ipairs(workspaceDescendants()) do
                local isPrompt = false
                pcall(function() isPrompt = inst:IsA("ProximityPrompt") end)
                local isClick = false
                pcall(function() isClick = inst:IsA("ClickDetector") end)

                if (isPrompt or isClick) and inst.Parent then
                    local enabled = true
                    pcall(function() enabled = inst.Enabled end)
                    if enabled ~= false then
                        table.insert(out, inst)
                        if #out >= (limit or 120) then break end
                    end
                end
            end
            table.sort(out, function(a, b)
                return distanceTo(a.Parent) < distanceTo(b.Parent)
            end)
            return out
        end

        local function promptLabel(prompt)
            if not prompt then return "?" end

            local isClick = false
            pcall(function() isClick = prompt:IsA("ClickDetector") end)
            if isClick then
                return tostring(prompt.Parent and prompt.Parent.Name or "click")
            end

            local label = prompt.ObjectText
            if label == nil or label == "" then
                label = prompt.ActionText or (prompt.Parent and prompt.Parent.Name) or "prompt"
            end
            return tostring(label)
        end

        -- ---------------------------------------------------- backpack check

        -- A tool only exists for real once the server puts it in your Backpack.
        -- Everything below watches that container, so a pickup that the map
        -- refused is reported as refused instead of faked locally.
        local function backpackTools()
            local found = {}
            local function scan(container)
                if not container then return end
                for _, c in ipairs(container:GetChildren()) do
                    local isTool = false
                    pcall(function() isTool = c:IsA("Tool") end)
                    if isTool then found[c.Name] = c end
                end
            end
            scan(LP:FindFirstChildOfClass("Backpack"))
            scan(LP.Character)
            return found
        end

        local function equipTool(tool)
            local char = LP.Character
            if not char or not tool or not tool.Parent then return end
            local hum = char:FindFirstChildOfClass("Humanoid")
            if not hum then return end
            pcall(function() hum:EquipTool(tool) end)
        end

        -- The server needs a moment to replicate the new tool, and a map may
        -- hand it over a few hundred milliseconds later. Poll instead of
        -- checking once.
        local function waitForGain(before, tries)
            for _ = 1, (tries or 8) do
                task.wait(0.2)
                local now = backpackTools()
                for name, tool in pairs(now) do
                    if not before[name] then return name, tool end
                end
            end
            return nil
        end

        local function reportGain(before, label)
            local name, tool = waitForGain(before)
            if name then
                setStatus(("%s -> backpack: %s"):format(label, name))
                equipTool(tool)
                return true
            end
            setStatus(("%s: fired, no new tool in backpack"):format(label))
            return false
        end

        local promptMode = "fast"

        local function firePrompt(prompt)
            if not prompt or not prompt.Parent then
                notify("Prompt is gone")
                return false
            end

            local isClick = false
            pcall(function() isClick = prompt:IsA("ClickDetector") end)

            if isClick then
                if type(fireclickdetector) ~= "function" then
                    setStatus("this executor has no fireclickdetector")
                    return false
                end
                local ok = pcall(fireclickdetector, prompt)
                setStatus((ok and "click fired: " or "click failed: ") .. promptLabel(prompt))
                return ok
            end

            -- Hold mode simulates the real key press, which also sends the
            -- PromptButtonHoldBegan signal that games use to detect the raw
            -- fireproximityprompt bypass. It needs the prompt in range.
            local function hold()
                local ok = pcall(function()
                    prompt:InputHoldBegin()
                    task.wait(math.min(tonumber(prompt.HoldDuration) or 0, 0.8))
                    prompt:InputHoldEnd()
                end)
                return ok
            end

            if promptMode == "hold" then
                if hold() then
                    setStatus("prompt held: " .. promptLabel(prompt))
                    return true
                end
            end

            -- fireproximityprompt is the executor-side shortcut: it calls the
            -- prompt's trigger on the server without walking over or holding
            -- the key. Every mainstream executor ships it.
            if type(fireproximityprompt) == "function" then
                local ok = pcall(fireproximityprompt, prompt)
                if ok then
                    setStatus("prompt fired: " .. promptLabel(prompt))
                    return true
                end
            end

            if promptMode ~= "hold" and hold() then
                setStatus("prompt held: " .. promptLabel(prompt))
                return true
            end

            setStatus("prompt failed: " .. promptLabel(prompt))
            return false
        end

        local function renderPrompts()
            clearList(promptList)
            local list = collectPrompts()

            if #list == 0 then
                placeHolder(promptList, "nothing found - the game may use its own remotes")
                return 0
            end

            for i, prompt in ipairs(list) do
                local parent = prompt.Parent
                local name = promptLabel(prompt)
                local action = ""
                pcall(function() action = tostring(prompt.ActionText or "") end)
                if action ~= "" and not name:find(action, 1, true) then
                    name = name .. " - " .. action
                end

                local d = distanceTo(parent)
                local text = (d < math.huge) and ("%s  (%.0f)"):format(name, d) or name

                local row = listRow(promptList, text, i)
                row.MouseButton1Click:Connect(function()
                    local before = backpackTools()
                    if firePrompt(prompt) then
                        task.spawn(function() reportGain(before, name) end)
                    end
                end)
            end

            return #list
        end

        promptScanBtn.MouseButton1Click:Connect(function()
            local n = renderPrompts()
            setStatus(("world: %d prompts"):format(n))
        end)

        promptNearBtn.MouseButton1Click:Connect(function()
            local list = collectPrompts(20)
            if #list == 0 then
                notify("No prompt in this map")
                return
            end
            local before = backpackTools()
            local label = promptLabel(list[1])
            if firePrompt(list[1]) then
                task.spawn(function() reportGain(before, label) end)
            end
        end)

        local autoPrompt = false
        local autoSeen = {}

        local function stylePromptOpts()
            local hold = promptMode == "hold"
            modeBtn.Text = hold and "Hold (safe)" or "Fast (bypass)"
            modeBtn.BackgroundColor3 = hold and C.rowOn or C.row
            modeBtn.TextColor3 = hold and C.accent or C.text

            autoBtn.Text = autoPrompt and "Auto in range: ON" or "Auto in range: OFF"
            autoBtn.BackgroundColor3 = autoPrompt and C.rowOn or C.row
            autoBtn.TextColor3 = autoPrompt and C.accent or C.text
        end

        modeBtn.MouseButton1Click:Connect(function()
            promptMode = (promptMode == "hold") and "fast" or "hold"
            stylePromptOpts()
            setStatus(promptMode == "hold"
                and "prompt mode: hold - sends the real hold signal"
                or "prompt mode: fast - bypasses distance")
        end)

        autoBtn.MouseButton1Click:Connect(function()
            autoPrompt = not autoPrompt
            stylePromptOpts()
            setStatus(autoPrompt and "auto prompt: on, in-range prompts only" or "auto prompt: off")
        end)

        stylePromptOpts()

        -- PromptShown fires client-side only for prompts the player is close
        -- enough to use, so this never reaches across the map.
        PromptService.PromptShown:Connect(function(prompt)
            if not autoPrompt or not prompt or not prompt.Parent then return end

            local now = os.clock()
            local last = autoSeen[prompt]
            if last and (now - last) < 3 then return end
            autoSeen[prompt] = now

            task.spawn(function()
                local before = backpackTools()
                local label = promptLabel(prompt)
                if firePrompt(prompt) then
                    reportGain(before, label)
                end
            end)
        end)

        placeHolder(promptList, "press Scan prompts")

        sectionLabel(pageWorld, "TOOLS IN MAP", 24)

        local toolRow = Instance.new("Frame")
        toolRow.Size = UDim2.new(1, -4, 0, 28)
        toolRow.BackgroundTransparency = 1
        toolRow.BorderSizePixel = 0
        toolRow.LayoutOrder = 25
        toolRow.Parent = pageWorld

        local toolScanBtn = smallBtn(toolRow, "Scan tools", 0, 0, 0.5, -2)
        local toolNearBtn = smallBtn(toolRow, "TP to nearest", 0.5, 1, 0.5, -1)

        local toolList = Instance.new("ScrollingFrame")
        toolList.Size = UDim2.new(1, -4, 0, 108)
        toolList.BackgroundColor3 = C.panel
        toolList.BorderSizePixel = 0
        toolList.ScrollBarThickness = 2
        toolList.CanvasSize = UDim2.new(0, 0, 0, 0)
        toolList.AutomaticCanvasSize = Enum.AutomaticSize.Y
        toolList.LayoutOrder = 26
        toolList.Parent = pageWorld

        local tlCorner = Instance.new("UICorner")
        tlCorner.CornerRadius = UDim.new(0, 7)
        tlCorner.Parent = toolList

        local tlLayout = Instance.new("UIListLayout")
        tlLayout.Padding = UDim.new(0, 2)
        tlLayout.Parent = toolList

        -- A Tool is not a Model, so it has no Position/GetPivot of its own.
        -- Resolve the part that actually sits in the world.
        local function toolPart(tool)
            local h = nil
            pcall(function() h = tool.Handle end)
            if h and h.Parent then return h end
            local found = nil
            pcall(function()
                for _, d in ipairs(tool:GetDescendants()) do
                    if d:IsA("BasePart") then found = d break end
                end
            end)
            return found
        end

        local function toolPosition(tool)
            local part = toolPart(tool)
            if part then return part.Position end
            local parent = tool.Parent
            if parent then
                local p = nil
                pcall(function() p = parent.Position end)
                if p then return p end
            end
            return nil
        end

        local function distanceToTool(tool)
            local _, _, hrp = getChar()
            local pos = toolPosition(tool)
            if not hrp or not pos then return math.huge end
            return (pos - hrp.Position).Magnitude
        end

        local function collectTools(limit)
            local out = {}
            local char = LP.Character
            for _, inst in ipairs(workspaceDescendants()) do
                if inst:IsA("Tool") and not (char and inst:IsDescendantOf(char)) then
                    table.insert(out, inst)
                    if #out >= (limit or 80) then break end
                end
            end
            table.sort(out, function(a, b)
                return distanceToTool(a) < distanceToTool(b)
            end)
            return out
        end

        local function tpToTool(tool)
            local _, _, hrp = getChar()
            if not hrp then
                notify("Character not loaded")
                return
            end

            local pos = toolPosition(tool)
            if not pos then
                notify("Tool is gone")
                return
            end

            local ok = pcall(function()
                hrp.CFrame = CFrame.new(pos + Vector3.new(0, 3, 0))
            end)

            if ok then
                setStatus("tp to tool " .. tostring(tool.Name))
            else
                setStatus("could not reach " .. tostring(tool.Name))
            end
        end

        -- Community-standard argument order, as used by Infinite Yield:
        -- firetouchinterest(partThatGetsTouched, toucher, toggle).
        local function touchTool(tool)
            local _, _, hrp = getChar()
            local part = toolPart(tool)
            if not hrp or not part then
                notify("Tool has no part to touch")
                return false
            end
            if type(firetouchinterest) ~= "function" then
                setStatus("this executor has no firetouchinterest")
                return false
            end

            local ok = pcall(function()
                firetouchinterest(part, hrp, 0)
                task.wait()
                firetouchinterest(part, hrp, 1)
            end)

            setStatus((ok and "touched " or "touch failed ") .. tostring(tool.Name))
            return ok
        end

        -- The whole point of the section: get the tool into the player's own
        -- Backpack so it can be equipped and used. That only happens when the
        -- server does it, so this presses whatever the map uses and then checks
        -- the Backpack instead of cloning the tool locally.
        local function takeTool(tool)
            if not tool or not tool.Parent then
                notify("Tool is gone")
                return false
            end

            local char = LP.Character
            if char and tool:IsDescendantOf(char) then
                equipTool(tool)
                setStatus(tostring(tool.Name) .. " is already yours")
                return true
            end

            local bp = LP:FindFirstChildOfClass("Backpack")
            if bp and tool:IsDescendantOf(bp) then
                equipTool(tool)
                setStatus(tostring(tool.Name) .. " is already in your backpack")
                return true
            end

            local before = backpackTools()
            local label = tostring(tool.Name)
            local fired = false

            -- The pickup prompt usually sits on the tool or on the model that
            -- holds it (a rack, a shelf, a display stand).
            local roots = { tool }
            local holder = tool.Parent
            if holder and holder ~= workspace and not holder:IsA("Folder") then
                table.insert(roots, holder)
            end

            local candidates = {}
            for _, root in ipairs(roots) do
                for _, d in ipairs(root:GetDescendants()) do
                    local isPrompt, isClick = false, false
                    pcall(function()
                        isPrompt = d:IsA("ProximityPrompt")
                        isClick = d:IsA("ClickDetector")
                    end)
                    if (isPrompt or isClick) and d.Parent then
                        local enabled = true
                        pcall(function() enabled = d.Enabled end)
                        if enabled then table.insert(candidates, d) end
                    end
                end
            end

            -- A rack can hold one prompt per item. Fire only the one attached to
            -- this tool, never the whole shelf.
            if #candidates > 0 then
                local chosen = candidates[1]
                for _, c in ipairs(candidates) do
                    if c:IsDescendantOf(tool) then chosen = c break end
                end
                fired = firePrompt(chosen)
            end

            -- No prompt: the map probably grants it from a Touched handler.
            if not fired then touchTool(tool) end

            return reportGain(before, label)
        end

        local function renderTools()
            clearList(toolList)
            local list = collectTools()

            if #list == 0 then
                placeHolder(toolList, "no Tool in workspace right now")
                return 0
            end

            for i, tool in ipairs(list) do
                local d = distanceToTool(tool)
                local text = (d < math.huge) and ("%s  (%.0f)"):format(tool.Name, d) or tool.Name

                local row = Instance.new("Frame")
                row.Size = UDim2.new(1, -8, 0, 24)
                row.BackgroundTransparency = 1
                row.LayoutOrder = i
                row.Parent = toolList

                local nameBtn = listRow(row, text, i)
                nameBtn.Size = UDim2.new(1, -84, 1, 0)
                nameBtn.Position = UDim2.fromOffset(0, 0)
                nameBtn.MouseButton1Click:Connect(function() tpToTool(tool) end)

                local takeBtn = smallBtn(row, "Take", 1, -80, 0, 38)
                takeBtn.TextSize = 10
                takeBtn.MouseButton1Click:Connect(function()
                    local ok, err = pcall(takeTool, tool)
                    if not ok then setStatus("take failed: " .. tostring(err)) end
                end)

                local touchBtn = smallBtn(row, "Touch", 1, -40, 0, 38)
                touchBtn.TextSize = 10
                touchBtn.MouseButton1Click:Connect(function() touchTool(tool) end)
            end

            return #list
        end

        toolScanBtn.MouseButton1Click:Connect(function()
            local n = renderTools()
            setStatus(("world: %d tools"):format(n))
        end)

        toolNearBtn.MouseButton1Click:Connect(function()
            local list = collectTools(1)
            if #list == 0 then
                notify("No tool in this map")
                return
            end
            tpToTool(list[1])
        end)

        placeHolder(toolList, "press Scan tools")
    end

    buildPromptsAndTools()

    -- ---------------------------------------------------------------- avatar tab

    sectionLabel(pageAvatar, "COPY OUTFIT", 1)

    local copyBox = Instance.new("TextBox")
    copyBox.Size = UDim2.new(1, -4, 0, 28)
    copyBox.BackgroundColor3 = C.row
    copyBox.PlaceholderText = "name / UserId (empty = Player tab target)"
    copyBox.Text = ""
    copyBox.TextColor3 = C.text
    copyBox.PlaceholderColor3 = C.dim
    copyBox.Font = Enum.Font.Gotham
    copyBox.TextSize = 12
    copyBox.BorderSizePixel = 0
    copyBox.ClearTextOnFocus = false
    copyBox.LayoutOrder = 2
    copyBox.Parent = pageAvatar

    local cbCorner = Instance.new("UICorner")
    cbCorner.CornerRadius = UDim.new(0, 6)
    cbCorner.Parent = copyBox

    local copyBtn = flatButton(pageAvatar, "Copy outfit now", 3)
    copyBtn.MouseButton1Click:Connect(function()
        local query = copyBox.Text
        if query == "" then query = tpBox.Text end
        local ok, err = copyOutfit(query)
        if ok then
            setStatus("outfit copied from " .. query .. " (" .. tostring(err) .. ")")
        else
            notify("Copy outfit: " .. tostring(err))
        end
    end)

    sectionLabel(pageAvatar, "SIZE", 4)

    local sizeRow = Instance.new("Frame")
    sizeRow.Size = UDim2.new(1, -4, 0, 28)
    sizeRow.BackgroundTransparency = 1
    sizeRow.BorderSizePixel = 0
    sizeRow.LayoutOrder = 5
    sizeRow.Parent = pageAvatar

    local minusBtn = smallBtn(sizeRow, "Size -", 0, 0, 0.33, -2)
    local resetBtn = smallBtn(sizeRow, "1x", 0.33, 1, 0.34, -2)
    local plusBtn = smallBtn(sizeRow, "Size +", 0.67, 2, 0.33, 0)

    local function syncSizeLabel()
        resetBtn.Text = ("%.2fx"):format(SCALES[scaleIndex])
    end

    minusBtn.MouseButton1Click:Connect(function()
        scaleIndex = math.max(1, scaleIndex - 1)
        local ok, err = applyScale()
        if not ok then notify(tostring(err)) end
        syncSizeLabel()
    end)

    plusBtn.MouseButton1Click:Connect(function()
        scaleIndex = math.min(#SCALES, scaleIndex + 1)
        local ok, err = applyScale()
        if not ok then notify(tostring(err)) end
        syncSizeLabel()
    end)

    resetBtn.MouseButton1Click:Connect(function()
        scaleIndex = SCALE_RESET_INDEX
        applyScale()
        syncSizeLabel()
    end)

    syncSizeLabel()

    -- ---------------------------------------------------------------- emote tab

    local emoteCat = "all"

    sectionLabel(pageEmote, "EMOTES", 1)

    local catRow = Instance.new("Frame")
    catRow.Size = UDim2.new(1, -4, 0, 26)
    catRow.BackgroundTransparency = 1
    catRow.BorderSizePixel = 0
    catRow.LayoutOrder = 2
    catRow.Parent = pageEmote

    local searchBox = Instance.new("TextBox")
    searchBox.Size = UDim2.new(1, -4, 0, 28)
    searchBox.BackgroundColor3 = C.row
    searchBox.PlaceholderText = "search emote / lagu..."
    searchBox.Text = ""
    searchBox.TextColor3 = C.text
    searchBox.PlaceholderColor3 = C.dim
    searchBox.Font = Enum.Font.Gotham
    searchBox.TextSize = 12
    searchBox.BorderSizePixel = 0
    searchBox.ClearTextOnFocus = false
    searchBox.LayoutOrder = 3
    searchBox.Parent = pageEmote

    local searchCorner = Instance.new("UICorner")
    searchCorner.CornerRadius = UDim.new(0, 6)
    searchCorner.Parent = searchBox

    local results = Instance.new("ScrollingFrame")
    results.Size = UDim2.new(1, -4, 0, 240)
    results.BackgroundColor3 = C.panel
    results.BorderSizePixel = 0
    results.ScrollBarThickness = 3
    results.CanvasSize = UDim2.new(0, 0, 0, 0)
    results.AutomaticCanvasSize = Enum.AutomaticSize.Y
    results.LayoutOrder = 4
    results.Parent = pageEmote

    local resultsCorner = Instance.new("UICorner")
    resultsCorner.CornerRadius = UDim.new(0, 6)
    resultsCorner.Parent = results

    local resultsLayout = Instance.new("UIListLayout")
    resultsLayout.Padding = UDim.new(0, 2)
    resultsLayout.Parent = results

    local function renderEmotes()
        for _, ch in ipairs(results:GetChildren()) do
            if ch:IsA("TextButton") then ch:Destroy() end
        end

        local q = searchBox.Text:lower()
        for _, e in ipairs(EMOTE_DB) do
            local catOk = (emoteCat == "all") or (e.cat == emoteCat)
            local nameOk = (q == "") or (e.name:lower():find(q, 1, true) ~= nil)
            if catOk and nameOk then
                local b = Instance.new("TextButton")
                b.Size = UDim2.new(1, -6, 0, 26)
                b.BackgroundColor3 = C.row
                b.Text = "  " .. e.name
                b.TextColor3 = Color3.fromRGB(205, 205, 215)
                b.Font = Enum.Font.Gotham
                b.TextSize = 11
                b.TextXAlignment = Enum.TextXAlignment.Left
                b.AutoButtonColor = false
                b.BorderSizePixel = 0
                b.Parent = results

                local c = Instance.new("UICorner")
                c.CornerRadius = UDim.new(0, 4)
                c.Parent = b

                b.MouseButton1Click:Connect(function()
                    local ok, err = playEmote(e.id)
                    if ok then
                        setStatus("emote: " .. e.name)
                    else
                        notify("Emote " .. e.name .. ": " .. tostring(err))
                    end
                end)
            end
        end
    end

    local catButtons = {}
    local CATS = {
        { key = "all",   label = "All" },
        { key = "dance", label = "Dance" },
        { key = "kpop",  label = "K-pop" },
        { key = "viral", label = "Viral" },
    }

    local function styleCats()
        for key, b in pairs(catButtons) do
            local on = (key == emoteCat)
            b.BackgroundColor3 = on and C.rowOn or C.row
            b.TextColor3 = on and C.accent or C.muted
        end
    end

    for i, cat in ipairs(CATS) do
        local b = smallBtn(catRow, cat.label, (i - 1) * 0.25, (i - 1) * 2, 0.25, -2)
        b.TextSize = 11
        catButtons[cat.key] = b
        b.MouseButton1Click:Connect(function()
            emoteCat = cat.key
            styleCats()
            renderEmotes()
        end)
    end

    searchBox:GetPropertyChangedSignal("Text"):Connect(renderEmotes)

    local stopBtn = flatButton(pageEmote, "Stop emote", 5, 28)
    stopBtn.BackgroundColor3 = Color3.fromRGB(74, 44, 44)
    stopBtn.TextXAlignment = Enum.TextXAlignment.Center
    stopBtn.MouseButton1Click:Connect(stopEmote)

    sectionLabel(pageEmote, "CUSTOM ANIMATION ID", 6)

    local animIdBox = Instance.new("TextBox")
    animIdBox.Size = UDim2.new(1, -4, 0, 28)
    animIdBox.BackgroundColor3 = C.row
    animIdBox.PlaceholderText = "animation id, e.g. 507771019"
    animIdBox.Text = ""
    animIdBox.TextColor3 = C.text
    animIdBox.PlaceholderColor3 = C.dim
    animIdBox.Font = Enum.Font.Code
    animIdBox.TextSize = 11
    animIdBox.BorderSizePixel = 0
    animIdBox.ClearTextOnFocus = false
    animIdBox.LayoutOrder = 7
    animIdBox.Parent = pageEmote

    local aiCorner = Instance.new("UICorner")
    aiCorner.CornerRadius = UDim.new(0, 6)
    aiCorner.Parent = animIdBox

    local playIdBtn = flatButton(pageEmote, "Play animation", 8, 28)
    playIdBtn.TextXAlignment = Enum.TextXAlignment.Center

    playIdBtn.MouseButton1Click:Connect(function()
        local raw = tostring(animIdBox.Text or ""):gsub("[^%d]", "")
        if raw == "" then
            notify("Enter an animation id")
            return
        end
        local ok, err = playEmote(raw)
        if ok then
            setStatus("animation " .. raw .. " playing - others see this")
        else
            notify("Animation: " .. tostring(err))
        end
    end)

    styleCats()
    renderEmotes()

    -- ---------------------------------------------------------------- remotes tab

    sectionLabel(pageRemotes, "REMOTE SCANNER", 1)

    local remoteFilter = Instance.new("TextBox")
    remoteFilter.Size = UDim2.new(1, -4, 0, 28)
    remoteFilter.BackgroundColor3 = C.row
    remoteFilter.PlaceholderText = "filter by name or path..."
    remoteFilter.Text = ""
    remoteFilter.TextColor3 = C.text
    remoteFilter.PlaceholderColor3 = C.dim
    remoteFilter.Font = Enum.Font.Gotham
    remoteFilter.TextSize = 12
    remoteFilter.BorderSizePixel = 0
    remoteFilter.ClearTextOnFocus = false
    remoteFilter.LayoutOrder = 2
    remoteFilter.Parent = pageRemotes

    local rfCorner = Instance.new("UICorner")
    rfCorner.CornerRadius = UDim.new(0, 6)
    rfCorner.Parent = remoteFilter

    local scanBtn = flatButton(pageRemotes, "Scan game for remotes", 3, 28)
    scanBtn.TextXAlignment = Enum.TextXAlignment.Center
    scanBtn.BackgroundColor3 = Color3.fromRGB(38, 70, 55)

    local remoteList = Instance.new("ScrollingFrame")
    remoteList.Size = UDim2.new(1, -4, 0, 150)
    remoteList.BackgroundColor3 = C.panel
    remoteList.BorderSizePixel = 0
    remoteList.ScrollBarThickness = 3
    remoteList.CanvasSize = UDim2.new(0, 0, 0, 0)
    remoteList.AutomaticCanvasSize = Enum.AutomaticSize.Y
    remoteList.LayoutOrder = 4
    remoteList.Parent = pageRemotes

    local rlCorner = Instance.new("UICorner")
    rlCorner.CornerRadius = UDim.new(0, 6)
    rlCorner.Parent = remoteList

    local rlLayout = Instance.new("UIListLayout")
    rlLayout.Padding = UDim.new(0, 2)
    rlLayout.Parent = remoteList

    sectionLabel(pageRemotes, "SPY (what the game fires)", 9)

    local spyRow = Instance.new("Frame")
    spyRow.Size = UDim2.new(1, -4, 0, 28)
    spyRow.BackgroundTransparency = 1
    spyRow.BorderSizePixel = 0
    spyRow.LayoutOrder = 10
    spyRow.Parent = pageRemotes

    local spyBtn = smallBtn(spyRow, "Spy: OFF", 0, 0, 0.62, -2)
    spyBtn.BackgroundColor3 = C.row
    local clearSpyBtn = smallBtn(spyRow, "Clear", 0.62, 1, 0.38, -1)

    local spyLogFrame = Instance.new("ScrollingFrame")
    spyLogFrame.Size = UDim2.new(1, -4, 0, 110)
    spyLogFrame.BackgroundColor3 = C.panel
    spyLogFrame.BorderSizePixel = 0
    spyLogFrame.ScrollBarThickness = 3
    spyLogFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
    spyLogFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
    spyLogFrame.LayoutOrder = 11
    spyLogFrame.Parent = pageRemotes

    local slCorner = Instance.new("UICorner")
    slCorner.CornerRadius = UDim.new(0, 6)
    slCorner.Parent = spyLogFrame

    local slLayout = Instance.new("UIListLayout")
    slLayout.Padding = UDim.new(0, 1)
    slLayout.Parent = spyLogFrame

    local REMOTE_CLASSES = {
        RemoteEvent = true,
        RemoteFunction = true,
        UnreliableRemoteEvent = true,
    }

    local remoteCache = {}
    local remotesScanned = false

    -- Walk parents instead of GetFullName so this is safe to call inside the namecall hook.
    local function safePath(inst)
        local parts = {}
        local cur = inst
        local depth = 0
        while cur and cur ~= game and depth < 12 do
            table.insert(parts, 1, cur.Name)
            cur = cur.Parent
            depth += 1
        end
        return table.concat(parts, ".")
    end

    -- Compact one-line rendering of any value, used by both the fire result and the spy log.
    local function describeArg(v)
        local t = typeof(v)
        if t == "string" then
            local s = v
            if #s > 28 then s = s:sub(1, 28) .. "..." end
            return ("%q"):format(s)
        elseif t == "number" or t == "boolean" then
            return tostring(v)
        elseif t == "Instance" then
            return "<" .. v.ClassName .. ":" .. v.Name .. ">"
        elseif t == "nil" then
            return "nil"
        end
        return "<" .. t .. ">"
    end

    local function collectRemotes()
        remoteCache = {}
        local seen = {}
        local roots = {}

        local okRS, rs = pcall(function() return game:GetService("ReplicatedStorage") end)
        if okRS and rs then table.insert(roots, rs) end
        local okRF, rf = pcall(function() return game:GetService("ReplicatedFirst") end)
        if okRF and rf then table.insert(roots, rf) end
        table.insert(roots, workspace)

        for _, root in ipairs(roots) do
            local okD, desc = pcall(function() return root:GetDescendants() end)
            if okD and desc then
                for _, inst in ipairs(desc) do
                    if REMOTE_CLASSES[inst.ClassName] and not seen[inst] then
                        seen[inst] = true
                        table.insert(remoteCache, inst)
                    end
                end
            end
        end

        table.sort(remoteCache, function(a, b)
            return safePath(a):lower() < safePath(b):lower()
        end)

        remotesScanned = true
        return #remoteCache
    end

    local selectedRemote
    local selectedLabel

    local function addRemoteRow(text, color, onClick)
        local b = Instance.new("TextButton")
        b.Size = UDim2.new(1, -6, 0, 24)
        b.BackgroundColor3 = C.row
        b.Text = "  " .. text
        b.TextColor3 = color
        b.Font = Enum.Font.Gotham
        b.TextSize = 10
        b.TextXAlignment = Enum.TextXAlignment.Left
        b.TextTruncate = Enum.TextTruncate.AtEnd
        b.AutoButtonColor = false
        b.BorderSizePixel = 0
        b.Parent = remoteList

        local c = Instance.new("UICorner")
        c.CornerRadius = UDim.new(0, 4)
        c.Parent = b

        if onClick then
            b.MouseButton1Click:Connect(onClick)
        end
        return b
    end

    renderRemotes = function()
        for _, ch in ipairs(remoteList:GetChildren()) do
            if ch:IsA("TextButton") then ch:Destroy() end
        end

        if not remotesScanned then
            addRemoteRow("press Scan to list remotes", Color3.fromRGB(130, 130, 140))
            return
        end

        if #remoteCache == 0 then
            addRemoteRow("no RemoteEvent / RemoteFunction found", Color3.fromRGB(150, 130, 130))
            return
        end

        local q = remoteFilter.Text:lower()
        local shown = 0
        local total = 0

        for _, inst in ipairs(remoteCache) do
            local path = safePath(inst)
            if q == "" or path:lower():find(q, 1, true) then
                total += 1
                if shown < 250 then
                    shown += 1
                    addRemoteRow(path, C.text, function()
                        selectedRemote = inst
                        if selectedLabel then
                            selectedLabel.Text = "selected: " .. inst.Name
                        end
                        if setclipboard then setclipboard(path) end
                        setStatus("selected " .. path .. " - args in the box below")
                    end)
                end
            end
        end

        if total > shown then
            addRemoteRow(("+%d more - narrow the filter"):format(total - shown), Color3.fromRGB(130, 130, 140))
        end
    end

    remoteFilter:GetPropertyChangedSignal("Text"):Connect(function()
        renderRemotes()
    end)

    scanBtn.MouseButton1Click:Connect(function()
        local n = collectRemotes()
        renderRemotes()
        setStatus(("remote scan: %d found"):format(n))
    end)

    sectionLabel(pageRemotes, "FIRE (selected remote)", 5)

    selectedLabel = Instance.new("TextLabel")
    selectedLabel.Size = UDim2.new(1, -4, 0, 18)
    selectedLabel.BackgroundTransparency = 1
    selectedLabel.Text = "selected: none"
    selectedLabel.TextColor3 = Color3.fromRGB(150, 150, 160)
    selectedLabel.Font = Enum.Font.Gotham
    selectedLabel.TextSize = 11
    selectedLabel.TextXAlignment = Enum.TextXAlignment.Left
    selectedLabel.TextTruncate = Enum.TextTruncate.AtEnd
    selectedLabel.LayoutOrder = 6
    selectedLabel.Parent = pageRemotes

    local argsBox = Instance.new("TextBox")
    argsBox.Size = UDim2.new(1, -4, 0, 28)
    argsBox.BackgroundColor3 = C.row
    argsBox.PlaceholderText = 'args: "text", 5, true'
    argsBox.Text = ""
    argsBox.TextColor3 = C.text
    argsBox.PlaceholderColor3 = C.dim
    argsBox.Font = Enum.Font.Code
    argsBox.TextSize = 11
    argsBox.BorderSizePixel = 0
    argsBox.ClearTextOnFocus = false
    argsBox.LayoutOrder = 7
    argsBox.Parent = pageRemotes

    local abCorner = Instance.new("UICorner")
    abCorner.CornerRadius = UDim.new(0, 6)
    abCorner.Parent = argsBox

    local fireRow = Instance.new("Frame")
    fireRow.Size = UDim2.new(1, -4, 0, 28)
    fireRow.BackgroundTransparency = 1
    fireRow.BorderSizePixel = 0
    fireRow.LayoutOrder = 8
    fireRow.Parent = pageRemotes

    local fireBtn = smallBtn(fireRow, "Fire selected", 0, 0, 0.62, -2)
    fireBtn.BackgroundColor3 = Color3.fromRGB(74, 44, 44)
    local copyPathBtn = smallBtn(fireRow, "Copy path", 0.62, 1, 0.38, -1)

    -- Args are Lua literals:  "hello", 5, true, workspace.Baseplate
    local function parseArgs(text)
        text = tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
        if text == "" then return {} end
        if type(loadstring) ~= "function" then return nil, "loadstring missing" end
        local okChunk, chunk = pcall(loadstring, "return {" .. text .. "}")
        if not okChunk or type(chunk) ~= "function" then return nil, "bad syntax" end
        local okRun, res = pcall(chunk)
        if not okRun or type(res) ~= "table" then return nil, "bad args" end
        return res
    end

    local function argCount(t)
        local n = 0
        for _ in pairs(t) do n += 1 end
        return n
    end

    fireBtn.MouseButton1Click:Connect(function()
        if not selectedRemote or not selectedRemote.Parent then
            notify("Select a remote in the list first")
            setStatus("fire: no remote selected")
            return
        end

        local args, err = parseArgs(argsBox.Text)
        if not args then
            notify("Args: " .. tostring(err))
            setStatus("fire: " .. tostring(err))
            return
        end

        local target = selectedRemote
        local ok, res = pcall(function()
            if target:IsA("RemoteFunction") then
                return target:InvokeServer(table.unpack(args))
            end
            target:FireServer(table.unpack(args))
        end)

        if ok then
            local note = ""
            if target:IsA("RemoteFunction") then
                note = " -> " .. describeArg(res)
                print("[Utility] " .. target.Name .. note)
            end
            setStatus(("fired %s (%d args)%s"):format(target.Name, argCount(args), note))
        else
            notify("Fire failed: " .. tostring(res))
            setStatus("fire failed: " .. tostring(res))
        end
    end)

    copyPathBtn.MouseButton1Click:Connect(function()
        if not selectedRemote then
            notify("Select a remote first")
            return
        end
        local path = safePath(selectedRemote)
        if setclipboard then setclipboard(path) end
        setStatus("path: " .. path)
    end)

    -- ---------------------------------------------------------------- spy

    local spyEnabled = false
    local spyLog = {}
    local spyRenderQueued = false

    local function renderSpy()
        for _, ch in ipairs(spyLogFrame:GetChildren()) do
            if ch:IsA("TextLabel") then ch:Destroy() end
        end

        if #spyLog == 0 then
            local l = Instance.new("TextLabel")
            l.Size = UDim2.new(1, -6, 0, 24)
            l.BackgroundTransparency = 1
            l.Text = "  nothing recorded yet"
            l.TextColor3 = C.dim
            l.Font = Enum.Font.Gotham
            l.TextSize = 10
            l.TextXAlignment = Enum.TextXAlignment.Left
            l.Parent = spyLogFrame
            return
        end

        for _, line in ipairs(spyLog) do
            local l = Instance.new("TextLabel")
            l.Size = UDim2.new(1, -6, 0, 22)
            l.BackgroundTransparency = 1
            l.Text = "  " .. line
            l.TextColor3 = Color3.fromRGB(200, 215, 205)
            l.Font = Enum.Font.Code
            l.TextSize = 10
            l.TextXAlignment = Enum.TextXAlignment.Left
            l.TextTruncate = Enum.TextTruncate.AtEnd
            l.Parent = spyLogFrame
        end
    end

    -- Called from inside the namecall hook: queue the UI work instead of doing it here.
    local function addSpyLine(text)
        table.insert(spyLog, 1, text)
        while #spyLog > 60 do
            table.remove(spyLog)
        end
        if not spyRenderQueued then
            spyRenderQueued = true
            task.defer(function()
                spyRenderQueued = false
                renderSpy()
            end)
        end
    end

    local spyHook

    -- Executors differ a lot here: Delta has hookmetamethod, some have only
    -- getrawmetatable, some expose neither. Try every route, then say what was missing.
    local function spyPrimitives()
        return {
            hookmetamethod    = type(hookmetamethod) == "function",
            getrawmetatable   = type(getrawmetatable) == "function",
            debugmetatable    = type(debug) == "table" and type(debug.getmetatable) == "function",
            setreadonly       = type(setreadonly) == "function",
            getnamecallmethod = type(getnamecallmethod) == "function",
            newcclosure       = type(newcclosure) == "function",
        }
    end

    local function spyDiagText()
        local p = spyPrimitives()
        local out = {}
        for _, k in ipairs({ "hookmetamethod", "getrawmetatable", "debugmetatable", "setreadonly", "getnamecallmethod", "newcclosure" }) do
            table.insert(out, k .. "=" .. (p[k] and "yes" or "no"))
        end
        return table.concat(out, " ")
    end

    -- Runs inside pcall from the hook: nothing here may ever throw into the game.
    local function spyLogCall(self, args)
        local method
        local okM, m = pcall(getnamecallmethod)
        if okM and type(m) == "string" then
            method = m
        end

        -- No getnamecallmethod: infer from the receiver. Any namecall on a remote
        -- whose first argument is not a function is an outgoing call.
        if not method then
            if typeof(self) == "Instance" and REMOTE_CLASSES[self.ClassName] and type(args[1]) ~= "function" then
                method = (self.ClassName == "RemoteFunction") and "InvokeServer" or "FireServer"
            end
        end

        if method ~= "FireServer" and method ~= "InvokeServer" then
            return
        end

        local okP, path = pcall(safePath, self)
        local parts = {}
        for i = 1, math.min(args.n, 4) do
            table.insert(parts, describeArg(args[i]))
        end
        if args.n > 4 then
            table.insert(parts, ("+%d"):format(args.n - 4))
        end

        addSpyLine(("%s %s(%s)"):format(method, okP and path or "?", table.concat(parts, ", ")))
    end

    local function buildSpyHook(callOriginal)
        local wrapper = function(self, ...)
            if spyEnabled then
                pcall(spyLogCall, self, table.pack(...))
            end
            return callOriginal(self, ...)
        end

        if type(newcclosure) == "function" then
            local ok, c = pcall(newcclosure, wrapper)
            if ok and type(c) == "function" then wrapper = c end
        end

        return wrapper
    end

    local function installSpy()
        if spyHook then return true end
        local tried = {}

        -- Route 1: hookmetamethod works even on a locked metatable.
        if type(hookmetamethod) == "function" then
            local original
            local wrapper = buildSpyHook(function(self, ...)
                if original then return original(self, ...) end
            end)
            local ok, old = pcall(hookmetamethod, game, "__namecall", wrapper)
            if ok and type(old) == "function" then
                original = old
                spyHook = { kind = "hookmetamethod" }
                return true
            end
            table.insert(tried, "hookmetamethod:failed")
        else
            table.insert(tried, "hookmetamethod:missing")
        end

        -- Route 2: swap __namecall on the metatable itself.
        local mt
        if type(getrawmetatable) == "function" then
            local ok, m = pcall(getrawmetatable, game)
            if ok and type(m) == "table" then mt = m end
        end
        if not mt and type(debug) == "table" and type(debug.getmetatable) == "function" then
            local ok, m = pcall(debug.getmetatable, game)
            if ok and type(m) == "table" then mt = m end
        end

        if not mt then
            table.insert(tried, "metatable:unreachable")
            return false, table.concat(tried, " ") .. " | " .. spyDiagText()
        end

        local prev = rawget(mt, "__namecall")
        if type(prev) ~= "function" then
            table.insert(tried, "namecall:missing")
            return false, table.concat(tried, " ") .. " | " .. spyDiagText()
        end

        -- Write through even without setreadonly: the table is sometimes writable.
        local wrapper = buildSpyHook(function(self, ...) return prev(self, ...) end)
        if type(setreadonly) == "function" then
            pcall(setreadonly, mt, false)
        end
        local okSet = pcall(rawset, mt, "__namecall", wrapper)
        if type(setreadonly) == "function" then
            pcall(setreadonly, mt, true)
        end

        if not okSet or rawget(mt, "__namecall") ~= wrapper then
            table.insert(tried, "metatable:readonly")
            return false, table.concat(tried, " ") .. " | " .. spyDiagText()
        end

        spyHook = { kind = "metatable", mt = mt, prev = prev }
        return true
    end

    local function styleSpyBtn()
        if spyEnabled then
            spyBtn.Text = "Spy: ON"
            spyBtn.BackgroundColor3 = C.rowOn
            spyBtn.TextColor3 = C.accent
        else
            spyBtn.Text = "Spy: OFF"
            spyBtn.BackgroundColor3 = C.row
            spyBtn.TextColor3 = C.text
        end
    end

    spyBtn.MouseButton1Click:Connect(function()
        if not spyEnabled then
            local ok, err = installSpy()
            if not ok then
                local msg = tostring(err)
                notify("Spy unavailable - see console")
                setStatus("spy unavailable: " .. msg)
                print("[Utility] spy diag: " .. msg)
                return
            end
            spyEnabled = true
            setStatus("spy on - fire a remote in game")
        else
            spyEnabled = false
            setStatus("spy off")
        end
        styleSpyBtn()
    end)

    clearSpyBtn.MouseButton1Click:Connect(function()
        spyLog = {}
        renderSpy()
        setStatus("spy log cleared")
    end)

    styleSpyBtn()
    renderSpy()
    renderRemotes()

    -- ---------------------------------------------------------------- window controls

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

    local reopen = Instance.new("TextButton")
    reopen.Size = UDim2.fromOffset(44, 44)
    reopen.Position = UDim2.new(0, 8, 0, 160)
    reopen.BackgroundColor3 = C.panel
    reopen.Text = "="
    reopen.TextColor3 = C.text
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

    selectTab("main")
    refreshRows()
    fitMain()

    do
        local cam = workspace.CurrentCamera
        if cam then
            cam:GetPropertyChangedSignal("ViewportSize"):Connect(fitMain)
        end
        workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
            local c = workspace.CurrentCamera
            if c then
                c:GetPropertyChangedSignal("ViewportSize"):Connect(fitMain)
                fitMain()
            end
        end)
    end

    notify("Loaded - RightShift to toggle")

    genv.Util = {
        state = state,
        setFeature = setFeature,
        spyDiag = spyDiagText,
        scanRemotes = collectRemotes,
    }

    trace("ready")

end

buildUI()
