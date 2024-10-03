local UserInputService = game:GetService("UserInputService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
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
local MIN_PIPE_HINGE_ANGLE = math.cos(math.rad(70))
local BLUEPRINT_TRANSPARENCY = 0.7
local PIPE_COLORS = {
    default = BrickColor.new("Medium brown"),
    hologramValid = BrickColor.new("Shamrock"),
    hologramInvalid = BrickColor.new("Burgundy")
}
local KEYBINDS = {
    cancel = Enum.KeyCode.Escape,
    pipe = Enum.KeyCode.Z,
    junct3 = Enum.KeyCode.X,
    junct4 = Enum.KeyCode.C
}


local snapIndicator: Model?
function updateSnapIndicator(pos: Vector3?, snap: boolean?)
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
    snapIndicator.PrimaryPart.BrickColor = snap and PIPE_COLORS.hologramValid or PIPE_COLORS.default
end


local pipeBlueprint: Model?
function updatePipeBpShape(headSnap: Snap?, tailSnap: Snap?): boolean
    -- The entire workspace state of pipeBlueprint is updated to match the source of truth.
    -- This prevents accumulative errors of any kind.

    if headSnap == nil or tailSnap == nil then
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
        pipeBlueprint.Parent = Workspace
        
        -- :GetDescendants() is recursive
        -- not a performance concern: low depth
        -- TODO: replace part assemblies with unified meshes
        for _, part in pairs(pipeBlueprint:GetDescendants()) do
            if part:IsA("BasePart") then
                if part.CollisionGroup == "PipeSnap" then continue end
                part.CanCollide = false
                part.CastShadow = false 
                part.CanQuery = false
                part.Transparency = BLUEPRINT_TRANSPARENCY
            end
        end
    end
    
    -- this will run every frame as the mouse moves
    -- CRTICIAL ZONE:
    
    local headDir = headSnap.forward
    local tailDir = tailSnap.forward

    local headPart: BasePart = pipeBlueprint.Head
    local tailPart: BasePart = pipeBlueprint.Tail
    
    -- both to be initialized, definitively
    local headJointPos: Vector3?
    local tailJointPos: Vector3?
    
    -- non snapped endpoints need to be raised to avoid clipping

    local headPos = headSnap.pos
    local tailPos = tailSnap.pos
    local endpointRadius = pipeBlueprint.Head.Tip.Size.Y / 2

    if headSnap.snap == nil then
        headPos += headSnap.normal * endpointRadius
    end

    if tailSnap.snap == nil then
        tailPos += tailSnap.normal * endpointRadius
    end
    
    -- Case A: neither end point orientation is known: infer straight pipe
    if headDir == nil and tailSnap.forward == nil then
        local headToTail = tailPos - headPos
        headDir = headToTail.Unit
        tailDir = -headDir
    end

    -- Case B: both end point orientations are known: attempt no inference
    
    if headDir ~= nil then
        headPart:PivotTo(CFrame.lookAlong(headPos, headDir))
        headJointPos = headPart.Joint.Position
    end
    
    if tailDir ~= nil then
        tailPart:PivotTo(CFrame.lookAlong(tailPos, tailDir))
        tailJointPos = tailPart.Joint.Position
    end
    
    -- Case C: one end point orientation is known, and fixed: infer the other

    if headDir == nil then
        headDir = tailJointPos - headPos
        headPart:PivotTo(CFrame.lookAlong(headPos, headDir))
        headJointPos = headPart.Joint.Position
    end
    
    if tailDir == nil then
        tailDir = headJointPos - tailPos
        tailPart:PivotTo(CFrame.lookAlong(tailPos, tailDir))
        tailJointPos = tailPart.Joint.Position
    end

    local shaftVec = headJointPos - tailJointPos
    local pipeLength = shaftVec.Magnitude
    
    -- adjust pipe shaft to fit distance
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
    
    shaftVec = shaftVec.Unit
    
    -- A dot B = |A| * |B| * cos(theta)
    -- as A and B get more aligned, theta decreases, cos(theta) increases.
    -- Consider cosine "similarity"
    if shaftVec:Dot(headDir.Unit) > MIN_PIPE_HINGE_ANGLE then
        return false
    end
    
    if shaftVec:Dot(-tailDir.Unit) > MIN_PIPE_HINGE_ANGLE then
        return false
    end
    
    return true
end


function updatePipeBpColor(valid: boolean, snap: boolean)
    if pipeBlueprint == nil then return end

    -- pipe "valid" will be colored standard
    local color
    
    if not valid then
        color = PIPE_COLORS.hologramInvalid
    elseif snap then
        color = PIPE_COLORS.hologramValid
    else
        color = PIPE_COLORS.default
    end

    for _, part: BasePart in pairs(pipeBlueprint:GetDescendants()) do
        if not part:IsA("BasePart") then continue end
        if part:GetAttribute("doNotRecolor") == true then continue end
        part.BrickColor = color
    end
end


function realizePipeBp(headSnap: Snap, tailSnap: Snap)
    -- solidifies the pipe blueprint hologram into a physical pipe
    local primaryPart = pipeBlueprint.PrimaryPart

    -- Solidify the hologram
    for _, part in pairs(pipeBlueprint:GetDescendants()) do
        if part:IsA("BasePart") then
            part.Anchored = false
            
            -- let each part be welded to the primary part
            local weld = Instance.new('WeldConstraint')
            weld.Parent = part
            weld.Part0 = primaryPart
            weld.Part1 = part

            if part.CollisionGroup == "PipeSnap" then continue end
            
            -- visual modifications

            part.Transparency = 0
            part.CanCollide = true
            part.CastShadow = true
            part.CanQuery = true 
            -- let each individual part be unachored and instead form an assembly
            
            -- return colorable parts to default coloring
            if part:GetAttribute("doNotRecolor") ~= true then
                part.BrickColor = PIPE_COLORS.default
            end
        end
    end
    
    -- TODO: pipe anchor state needs to be based on snapping
    primaryPart.Anchored = true
    
    -- disabling the snaps from being used again
    -- TODO: need mechanism to re-enable snaps when pipe are destroyed

    if headSnap.snap ~= nil then
        headSnap.snap.CanQuery = false -- remote snap
        pipeBlueprint.Head.PipeSnap.CanQuery = false -- local snap
    end
    
    if tailSnap.snap ~= nil then
        tailSnap.snap.CanQuery = false -- remote snap
        pipeBlueprint.Tail.PipeSnap.CanQuery = false -- local snap
    end

    -- it is finished and should no longer be modified
    pipeBlueprint = nil
end


type Snap = {
    pos: Vector3,
    normal: Vector3,
    forward: Vector3?,
    snap: BasePart?
}


function getMouseTarget(): Snap?
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
    
    if raycastResult.Instance.Name == "PipeSnap" then
        local snap: BasePart = raycastResult.Instance
        local pivot = snap:GetPivot()
        
        return {
            pos = pivot.Position,
            normal = pivot.UpVector,
            forward = pivot.LookVector,
            snap = snap,
        }
    end

    return {
        pos = raycastResult.Position,
        normal = raycastResult.Normal,
    }
end



-- function trySnap(): Snap?
--     -- Note: VeiewportPointToRay call can be reused from getMouseTarget
--     -- but it is a non-issue.
--     local mousePos = UserInputService:GetMouseLocation()
--     local ray = camera:ViewportPointToRay(mousePos.X, mousePos.Y)
    
--     -- Cast the ray
--     local raycastParams = RaycastParams.new()
--     raycastParams.IgnoreWater = true
--     raycastParams.CollisionGroup = "PipeSnap"
--     raycastParams.FilterType = Enum.RaycastFilterType.Exclude
--     raycastParams.FilterDescendantsInstances = { player.Character, pipeBlueprint }

--     local raycastResult = workspace:Raycast(ray.Origin, ray.Direction * 1000, raycastParams)
    
--     if raycastResult == nil then
--         return nil
--     end
    
--     local snapPart: BasePart = raycastResult.Instance
--     local snapPivot = snapPart:GetPivot()
--     local snapPos = snapPivot.Position
--     local snapDir = snapPivot.LookVector
    
--     if snapPos == nil then
--         error('snapPos is nil')
--     end
    
--     return {
--         pos = snapPos,
--         dir = snapDir,
--         part = snapPart
--     }
-- end


----------------------------------
--  Coroutines
----------------------------------


local deferCleanup: {() -> nil} = {}


function junct3Coro()
    error('not implemented') -- TODO:
end


function pipeCoro()
    print("Good morning!") -- TODO: rm
    -- snap encapsulates information regarding potential snap points
    -- but is overloaded for the case of a position with no snap
    local headCast: Snap?
    local tailCast: Snap?

    local activeCast: Snap?
    local validShape = true
    
    local connection
    connection = UserInputService.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then
            if activeCast == nil then return end

            print('click', headCast, tailCast) -- TODO: rm
            if headCast == nil then
                headCast = activeCast
                updateSnapIndicator(nil)
            elseif validShape then
                tailCast = activeCast
                connection:Disconnect()
            end
        end
    end)

    deferCleanup[#deferCleanup + 1] = function()
        connection:Disconnect()
    end

    print('beginning loop')
    while headCast == nil or tailCast == nil do
        local nextCast = getMouseTarget()
        local canSnap = nextCast.snap ~= nil
        
        -- only non nil and uniquely positioned snaps are considered
        if activeCast ~= nil and nextCast ~= nil then
            -- posA ~= posB not sufficient due to floating point error
            if (nextCast.pos - activeCast.pos).Magnitude < 0.1 then
                task.wait()
                continue
            end
        end
        
        -- only frames with a new snap are allowed to perform updates
        if nextCast ~= nil then
            if headCast == nil then
                -- the canSnap parameter refers to the existence of a PipeSnap
                updateSnapIndicator(nextCast.pos, canSnap)
            else
                validShape = updatePipeBpShape(headCast, nextCast)
                updatePipeBpColor(validShape, canSnap)
            end
            
            -- setting the activeSnap enables the click listener
            -- to commit endpoints of the pipe
            activeCast = nextCast
        end

        task.wait() -- yield to next frame
    end

    print("Pipe built!") -- TODO: rm
    realizePipeBp(headCast, tailCast)
end


----------------------------------
--   Coroutine Management
----------------------------------


local buildThread: thread? = nil


-- kill a running coroutine
function tryKillCoro()
    if buildThread ~= nil then
        task.cancel(buildThread)

        if pipeBlueprint ~= nil then
            pipeBlueprint:Destroy()
            pipeBlueprint = nil
        end
        
        -- iterate deferCleanup to remove open connections
        for _, cleanup in pairs(deferCleanup) do
            cleanup()
        end
        
        deferCleanup = {}
    end
end


function startCoro(coro)
    -- this guarantees proper handling of resources
    -- dead? --> start coroutine
    -- alive? --> kill & restart coroutine
    tryKillCoro()
    buildThread = task.spawn(coro)
end


UserInputService.InputBegan:Connect(function(input)
    if input.KeyCode == KEYBINDS.cancel then
        tryKillCoro()
    end
end)

local bindToCoro = {
    {KEYBINDS.pipe, pipeCoro},
    {KEYBINDS.junct3, junct3Coro}
}

for _, bind in pairs(bindToCoro) do
    local key = bind[1]
    local coro = bind[2]

    UserInputService.InputBegan:Connect(function(input)
        if input.KeyCode == key then
            startCoro(coro)
        end
    end)
end
