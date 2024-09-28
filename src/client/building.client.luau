local UserInputService = game:GetService("UserInputService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local waitForInput = require(script.Parent.utils.waitForInput)
local mouseUtils = require(script.Parent.utils.mouseUtils)
local player = Players.LocalPlayer
local camera = workspace.CurrentCamera

-- TODO: these blocking calls should be moved into corresponding coroutines.
--     OK for now because almost all systems depend on these resources
--     so the bottleneck is not incurring a strong performance hit.
local models = ReplicatedStorage:WaitForChild("Models")
local pipeModel = models:WaitForChild("Pipe")
local snapIndicatorModel = models:WaitForChild("SnapIndicator")

local BUILD_REACH = 40
local MAX_PIPE_LENGTH = 20
local MIN_PIPE_HINGE_ANGLE = math.rad(80)
local PIPE_KEYBIND = Enum.KeyCode.Z
local CANCEL_KEYBIND = Enum.KeyCode.Escape
local BLUEPRINT_TRANSPARENCY = 0.5


local snapIndicator: Model?
function updateSnapIndicator(pos: Vector3?)
    -- This is function is similar an object. It is the sole maintainer
    -- of the snap indicator model. The workspace state is updated to match
    -- the source of truth (this function).
    if pos == nil then
        -- TODO: out of range indicator should be red, but visible
        if snapIndicator ~= nil then
            snapIndicator:Destroy()
            snapIndicator = nil
        end
        return
    end
    
    if snapIndicator == nil then
        snapIndicator = snapIndicatorModel:Clone()
        snapIndicator.Parent = workspace
    end
    
    snapIndicator:MoveTo(pos)
    -- TODO: color based on snap status
end


local pipeBlueprint: Model?
function updatePipeBlueprint(startPos: Vector3?, endPos: Vector3?, startVec: Vector3?, endVec: Vector3?): boolean
    -- The entire workspace state of pipeBlueprint is updated to match the source of truth.
    -- This prevents accumulative errors of any kind.

    if startPos == nil or endPos == nil then
        if pipeBlueprint ~= nil then
            pipeBlueprint:Destroy()
            pipeBlueprint = nil
        end
        return
    end
    
    if pipeBlueprint == nil then
        -- Blueprint Instantiation
        --     1. specify transparency
        --     2. disable colliders
        pipeBlueprint = pipeModel:Clone()
        pipeBlueprint.Parent = workspace
        
        -- :GetDescendants() is recursive
        -- not a performance concern: low depth
        -- TODO: replace part assemblies with unified meshes
        for _, part in pairs(pipeBlueprint:GetDescendants()) do
            if part:IsA("BasePart") then
                part.CanCollide = false
                part.Transparency = BLUEPRINT_TRANSPARENCY
            end
        end
    end
    
    -- this will run every frame as the mouse moves
    -- CRTICIAL ZONE:

    -- TODO: rm
    startVec = Vector3.new(0, 0, 1)
    endVec = -startVec

    startVec = startVec or (endPos - startPos).Unit
    startVec = startVec.Unit
    endVec = endVec or -startVec
    endVec = endVec.Unit
    
    local headPart: BasePart = pipeBlueprint.Head
    local tailPart: BasePart = pipeBlueprint.Tail

    headPart:PivotTo(CFrame.lookAlong(startPos, startVec))
    -- TODO: impl max pipe len
    tailPart:PivotTo(CFrame.lookAlong(endPos, endVec))
    
    local headJointPos = headPart.Joint.Position
    local tailJointPos = tailPart.Joint.Position
    
    -- adjust pipe shaft to fit distance
    local shaftVec = tailJointPos - headJointPos
    local pipeLength = shaftVec.Magnitude
    local shaftPart: BasePart = pipeBlueprint.Shaft
    shaftPart.Size = Vector3.new(pipeLength, shaftPart.Size.Y, shaftPart.Size.Z)
    local shaftCenter = (headJointPos + tailJointPos) / 2
    shaftPart:PivotTo(CFrame.new(shaftCenter, tailJointPos))
    
    -- checking for validity of placement
    -- TODO: VULNERABILITY: placement validity needs to be moved to server side

    if pipeLength > MAX_PIPE_LENGTH then
        return false
    end
    
    --      (shaftVec)
    --      --------->
    --      ^        ^
    --      |        |   (endVec)
    -- (startVec)
    
    -- dot product is invariant to orientation
    if shaftVec.Unit:Dot(-startVec) < math.cos(MIN_PIPE_HINGE_ANGLE) then
        return false
    end
    
    if shaftVec.Unit:Dot(endVec) < math.cos(MIN_PIPE_HINGE_ANGLE) then
        return false
    end
    
    return true
end


function placePipe()
    local primaryPart = pipeBlueprint.PrimaryPart

    -- Solidify the hologram
    for _, part in pairs(pipeBlueprint:GetDescendants()) do
        if part:IsA("BasePart") then
            part.CanCollide = true
            part.Transparency = 0
            -- let each individual part be unachored and instead form an assembly
            part.Anchored = false
            
            -- let each part be welded to the primary part
            local weld = Instance.new('WeldConstraint')
            weld.Parent = part
            weld.Part0 = primaryPart
            weld.Part1 = part
        end
    end
    
    -- TODO: pipe anchor state needs to be based on snapping
    primaryPart.Anchored = true
    
    -- this prevents the hologram manager from altering finished pipes
    pipeBlueprint = nil
end


function getMouseTarget()
    -- Get mouse position in 3D space
    local mousePos = UserInputService:GetMouseLocation()
    local ray = camera:ViewportPointToRay(mousePos.X, mousePos.Y)
    
    -- Cast the ray
    local raycastParams = RaycastParams.new()
    raycastParams.FilterType = Enum.RaycastFilterType.Exclude
    -- snapIndicator does not to be ignored because it can not be queried
    raycastParams.FilterDescendantsInstances = { player.Character, pipeBlueprint }
    raycastParams.IgnoreWater = true
    
    local raycastResult = workspace:Raycast(ray.Origin, ray.Direction * 1000, raycastParams)
    
    if raycastResult == nil then
        return nil
    end
    
    local pos = raycastResult.Position
    
    if (pos - player.Character.PrimaryPart.Position).Magnitude > BUILD_REACH then
        return nil
    end
    
    return pos
end


function buildingCoro()
    print("Good morning!") -- TODO: rm
    local pipeStart: Vector3?
    local pipeEnd: Vector3?
    local mouse: Vector3?
    
    local connection
    connection = UserInputService.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then
            if mouse == nil then
                return
            end

            print('click', pipeStart, pipeEnd)
            if pipeStart == nil then
                pipeStart = mouse
                updateSnapIndicator(nil)
            else
                pipeEnd = mouse
                connection:Disconnect()
            end
        end
    end)

    print('beginning loop')
    while pipeStart == nil or pipeEnd == nil do
        mouse = getMouseTarget()
        
        if pipeStart == nil then
            updateSnapIndicator(mouse)
        else
            updatePipeBlueprint(pipeStart, mouse)
        end

        task.wait() -- yield to next frame
    end

    print("Pipe built!") -- TODO: rm
    placePipe()
end


local buildThread: thread? = nil


-- kill a running coroutine
function tryKillCoro()
    if buildThread ~= nil and coroutine.status(buildThread) == "running" then
        coroutine.close(buildThread)
    end
end


-- dead? --> start coroutine
-- alive? --> kill & restart coroutine
UserInputService.InputBegan:Connect(function(input)
    if input.KeyCode == PIPE_KEYBIND then
        tryKillCoro()
        buildThread = coroutine.create(buildingCoro)
        coroutine.resume(buildThread)
    end
end)


UserInputService.InputBegan:Connect(function(input)
    if input.KeyCode == CANCEL_KEYBIND then
        tryKillCoro()
    end
end)