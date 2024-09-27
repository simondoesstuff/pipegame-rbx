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
function updatePipeBlueprint(startPos: Vector3?, endPos: Vector3?)
    -- This is function is similar an object.The pipeBlueprint
    -- model is updated to match the source of truth (this function).

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
        -- TODO: replace part assemblies with unified meshes
        for _, part in pairs(pipeBlueprint:GetDescendants()) do
            if part:IsA("BasePart") then
                part.CanCollide = false
                part.Transparency = BLUEPRINT_TRANSPARENCY
            end
        end
    end
    
    -- note: this will run every frame as the mouse moves
    -- pipeBlueprint origin is at the startHead.tip

    -- apparently, the front direction of the model is fixed and arbitrary :|
    -- so we need to manually apply a correction rotation
    pipeBlueprint.PrimaryPart.CFrame = CFrame.new(startPos, endPos) * CFrame.Angles(0, -math.pi/2, 0)
    
    -- scale the pipe to fit the distance
    local shaft = pipeBlueprint:FindFirstChild("Shaft")
    local pipeLength = math.clamp((endPos - startPos).Magnitude, BUILD_REACH)
    shaft.Size = Vector3.new(pipeLength, shaft.Size.Y, shaft.Size.Z)
end

function placePipe(startPos: Vector3, endPos: Vector3, startAngle: number, endAngle: number)
    error("Not implemented")
end

function getMouseTarget()
    -- Get mouse position in 3D space
    local mousePos = UserInputService:GetMouseLocation()
    local ray = camera:ViewportPointToRay(mousePos.X, mousePos.Y)
    
    -- Cast the ray
    local raycastParams = RaycastParams.new()
    raycastParams.FilterType = Enum.RaycastFilterType.Exclude
    raycastParams.FilterDescendantsInstances = { player, snapIndicator, pipeBlueprint }
    raycastParams.IgnoreWater = true
    
    local raycastResult = workspace:Raycast(ray.Origin, ray.Direction * BUILD_REACH, raycastParams)
    
    if raycastResult == nil then
        return nil
    end
    
    return raycastResult.Position
end
        

function buildingCoro()
    print("Good morning!") -- TODO: rm
    local pipeStart: Vector3?
    local pipeEnd: Vector3?
    local mouse: Vector3?
    
    local connection
    connection = UserInputService.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then
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
    placePipe(pipeStart, pipeEnd)
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