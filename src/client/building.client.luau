--!strict

local UserInputService = game:GetService("UserInputService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local waitForInput = require(script.Parent.utils.waitForInput)
local mouseUtils = require(script.Parent.utils.mouseUtils)


-- TODO: these blocking calls should be moved into corresponding coroutines.
--     OK for now because almost all systems depend on these resources
--     so the bottleneck is not incurring a strong performance hit.
local models = ReplicatedStorage:WaitForChild("Models")
local pipeModel = models:WaitForChild("Pipe")
local snapIndicatorModel = models:WaitForChild("SnapIndicator")

local BUILD_REACH = 10
local PIPE_KEYBIND = Enum.KeyCode.Z
local BLUEPRINT_TRANSPARENCY = 0.5

local snapIndicator: Model?
function updateSnapIndicator(pos: Vector3?)
    -- This is function is similar an object. It is the sole maintainer
    -- of the snap indicator model. The workspace state is updated to match
    -- the source of truth (this function).
    if pos == nil then
        if snapIndicator ~= nil then
            snapIndicator:Destroy()
            snapIndicator = nil
        end
        return
    end
    
    if snapIndicator == nil then
        snapIndicator = snapIndicatorModel:Clone()
    end
    
    snapIndicator.Position = pos
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
        pipeBlueprint.Transparency = BLUEPRINT_TRANSPARENCY
        
        -- :GetChildren() is NOT recurive
        for _, part in pairs(pipeBlueprint:GetChildren()) do
            if part:IsA("BasePart") then
                part.CanCollide = false
            end
        end
    end
    
    -- note: this will run every frame as the mouse moves
    -- pipeBlueprint origin is at the startHead.tip
    pipeBlueprint.CFrame = CFrame.new(startPos, endPos)
end

function placePipe(startPos: Vector3, endPos: Vector3, startAngle: number, endAngle: number)
    error("Not implemented")
end

function buildingCoro()
    print("Good morning!") -- TODO: rm
    local pipeStart: Vector3?
    local pipeEnd: Vector3?

    while pipeStart == nil do
        local startCandidate = mouseUtils.rangeHover(BUILD_REACH)
        updateSnapIndicator(startCandidate)

        if mouseUtils.isClicking() then
            pipeStart = startCandidate
            break
        end
        
        task.wait() -- yield to next frame
    end
    
    print("Pipe start!") -- TODO: rm
    while pipeEnd == nil do
        local endCandidate = mouseUtils.rangeHover(BUILD_REACH)
        updatePipeBlueprint(pipeStart, endCandidate)

        if mouseUtils.isClicking() then
            pipeEnd = endCandidate
            break
        end

        task.wait() -- yield to next frame
    end
    
    print("Pipe built!") -- TODO: rm
    placePipe(pipeStart, pipeEnd)
end

local buildThread: thread? = nil

-- dead? --> start coroutine
-- alive? --> kill & restart coroutine
UserInputService.InputBegan:Connect(function(input)
    if input.KeyCode == PIPE_KEYBIND then
        if buildThread ~= nil and coroutine.status(buildThread) == "running" then
            coroutine.close(buildThread)
        end

        buildThread = coroutine.create(buildingCoro)
        coroutine.resume(buildThread)
    end
end)