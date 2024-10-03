local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local Cast = require(script.Parent.utils.raycast)
local config = require(script.Parent.config)
local projByNormal = require(script.Parent.utils.linearAlgebra).projByNormal
local camera = workspace.CurrentCamera

-- TODO: these blocking calls should be moved into corresponding coroutines.
--     OK for now because almost all systems depend on these resources
--     so the bottleneck is not incurring a strong performance delta.
local models = ReplicatedStorage:WaitForChild("Models")
local pipeModel = models:WaitForChild("Pipe")
local snapIndicatorModel = models:WaitForChild("SnapIndicator")


-- Snap encapsulates information regarding potential snap points
-- but is overloaded for the case of a position without snap
type Snap = {
    pos: Vector3,
    up: Vector3,
    forward: Vector3?,
    snap: BasePart?
}


function maintainHologram(reference: Model, active: Model?, viable: boolean): Model?
    if not viable then
        if active ~= nil then
            active:Destroy()
        end

        return nil
    end

    if active == nil then
        -- Blueprint Instantiation
        --     1. specify transparency
        --     2. disable colliders
        active = reference:Clone()
        active.Parent = Workspace

        -- :GetDescendants() is recursive
        -- not a performance concern: low depth
        -- TODO: replace part assemblies with unified meshes
        for _, part in pairs(active:GetDescendants()) do
            if part:IsA("BasePart") then
                part.CanQuery = false

                if part.Name == "PipeSnap" then continue end

                part.CanCollide = false
                part.CastShadow = false
                part.Transparency = config.BLUEPRINT_TRANSPARENCY
            end
        end
    end

    return active
end


function updateSnapIndicator(model: Model, pos: Vector3?, snap: boolean?)
    model:MoveTo(pos)
    model.PrimaryPart.BrickColor = snap and config.PIPE_COLORS.hologramValid or config.PIPE_COLORS.default
end


function updatePipeBpShape(model: Model, headSnap: Snap, tailSnap: Snap): boolean
    -- The entire model state is updated to match the source of truth.
    -- This prevents accumulative errors of any kind.

    -- this will run every frame as the mouse moves
    -- INFO: CRTICIAL ZONE:

    local headPart: BasePart = model.Head
    local tailPart: BasePart = model.Tail

    -- 1. non snapped endpoints need to be raised to avoid clipping

    local headPos = headSnap.pos
    local tailPos = tailSnap.pos
    local endpointRadius = headPart.Tip.Size.Y / 2

    if headSnap.snap == nil then
        headPos += headSnap.up * endpointRadius
    end

    if tailSnap.snap == nil then
        tailPos += tailSnap.up * endpointRadius
    end

    -- 2. orientation inference and adjustment

    -- both to be initialized, definitively
    local headJointPos: Vector3?
    local tailJointPos: Vector3?
    local headDir = headSnap.forward
    local tailDir = tailSnap.forward

    -- Case A: both end point orientations are known: attempt no inference

    if headDir ~= nil then
        headPart:PivotTo(CFrame.lookAlong(headPos, headDir))
        -- cases B and C depend on this positioning
        headJointPos = headPart.Joint.Position
    end

    if tailDir ~= nil then
        tailPart:PivotTo(CFrame.lookAlong(tailPos, tailDir))
        tailJointPos = tailPart.Joint.Position
    end

    if headDir == nil or tailDir == nil then
        if headDir == nil and tailDir == nil then
            -- Case B: neither end point orientation is known: infer straight pipe
            local headToTail = tailPos - headPos
            headDir = headToTail
            tailDir = -headDir
        else
            -- Case C: one end point orientation is known, and fixed: infer the other
            if headDir == nil then
                headDir = tailJointPos - headPos
            elseif tailDir == nil then
                tailDir = headJointPos - tailPos
            end
        end

        -- project into the plane of the normals
        headDir = projByNormal(headDir, headSnap.up)
        tailDir = projByNormal(tailDir, tailSnap.up)

        -- place endpoints

        headPart:PivotTo(CFrame.lookAlong(headPos, headDir))
        headJointPos = headPart.Joint.Position

        tailPart:PivotTo(CFrame.lookAlong(tailPos, tailDir))
        tailJointPos = tailPart.Joint.Position
    end

    local shaftVec = tailJointPos - headJointPos
    local pipeLength = shaftVec.Magnitude

    -- 3. adjust pipe shaft to fit distance

    local shaftPart: BasePart = model.Shaft
    shaftPart.Size = Vector3.new(pipeLength, shaftPart.Size.Y, shaftPart.Size.Z)
    local shaftCenter = (headJointPos + tailJointPos) / 2
    shaftPart:PivotTo(CFrame.new(shaftCenter, tailJointPos))

    -- 4. checking for validity of placement
    -- TODO: VULNERABILITY: placement validity needs to be moved to server side

    if pipeLength > config.MAX_PIPE_LENGTH then
        return false
    end

    --      (shaftVec)
    --      --------->
    --      ^        ^
    --      |        |   (endVec)
    -- (startVec)

    -- A dot B = |A| * |B| * cos(theta)
    -- as A and B get more aligned, theta decreases, cos(theta) increases.
    -- Consider cosine "similarity"
    if shaftVec.Unit:Dot(-headDir.Unit) > config.MIN_PIPE_HINGE_ANGLE then
        return false
    end

    if shaftVec.Unit:Dot(tailDir.Unit) > config.MIN_PIPE_HINGE_ANGLE then
        return false
    end
    
    -- do a raycast through the shaft to get an approximation for intersetions
    -- NOTE: this will not check intersections that partially clip. This ONLY
    -- ensures pipes can not outright go straight through walls. This is very
    -- fast and forgiving, but not perfectly accurate.
    -- TODO: pipe intersection test can be fooled if head is placed in wall

    local castArgs = Cast.new()
    castArgs.IgnorePlayers = false
    castArgs.Exclude = { model }

    local cast = castArgs:Cast(headJointPos, shaftVec)
    if cast ~= nil then return false end

    local headToJoint = headJointPos - headPos
    local cast = castArgs:Cast(headPos + .02 * headToJoint, headToJoint)
    if cast ~= nil then return false end

    local tailToJoint = tailJointPos - tailPos
    local cast = castArgs:Cast(tailPos + .02 * tailToJoint, tailToJoint)
    if cast ~= nil then return false end

    return true
end


function updatePipeBpColor(model: Model, valid: boolean, snap: boolean)
    if model == nil then return end

    -- pipe "valid" will be colored standard
    local color

    if not valid then
        color = config.PIPE_COLORS.hologramInvalid
    elseif snap then
        color = config.PIPE_COLORS.hologramValid
    else
        color = config.PIPE_COLORS.default
    end

    for _, part: BasePart in pairs(model:GetDescendants()) do
        if not part:IsA("BasePart") then continue end
        if part:GetAttribute("doNotRecolor") == true then continue end
        part.BrickColor = color
    end
end


function realizePipeBp(model: Model, headSnap: Snap, tailSnap: Snap)
    -- solidifies the pipe blueprint hologram into a physical pipe
    local primaryPart = model.PrimaryPart

    -- Solidify the hologram
    for _, part in pairs(model:GetDescendants()) do
        if part:IsA("BasePart") then
            part.Anchored = false

            -- let each part be welded to the primary part
            local weld = Instance.new('WeldConstraint')
            weld.Parent = part
            weld.Part0 = primaryPart
            weld.Part1 = part

            part.CanQuery = true

            if part.Name == "PipeSnap" then continue end

            part.Transparency = 0
            part.CanCollide = true
            part.CastShadow = true
            -- let each individual part be unachored and instead form an assembly

            -- return colorable parts to default coloring
            if part:GetAttribute("doNotRecolor") ~= true then
                part.BrickColor = config.PIPE_COLORS.default
            end
        end
    end

    -- TODO: pipe anchor state needs to be based on snapping
    primaryPart.Anchored = true

    -- disabling the snaps from being used again
    -- TODO: need mechanism to re-enable snaps when pipe are destroyed

    if headSnap.snap ~= nil then
        headSnap.snap.CanQuery = false -- remote snap
        model.Head.PipeSnap.CanQuery = false -- local snap
    end

    if tailSnap.snap ~= nil then
        tailSnap.snap.CanQuery = false -- remote snap
        model.Tail.PipeSnap.CanQuery = false -- local snap
    end
end


function getMouseTarget(): Snap?
    -- Get mouse position in 3D space
    local mousePos = UserInputService:GetMouseLocation()
    local ray = camera:ViewportPointToRay(mousePos.X, mousePos.Y)
    local origin = ray.Origin
    local dir = ray.Direction * 1000
    
    -- Here we cast two rays, one for two possibe collision groups:
    --   PipeSnap
    --   Default
    -- It is possible to get the parts of PipeSnap and use the exclude
    -- filter to do a single raycast, but this appraoch likely has no
    -- associated cost or even an improvement because each raycast is
    -- individually faster in theory. This also enables set logic to be
    -- done in other parts of the code using the collision groups. 
    
    -- Cast ray 1
    local castArgs = Cast.new()
    castArgs.IgnorePlayers = true

    castArgs.CollisionGroup = "PipeSnap"
    local cast1 = castArgs:Cast(origin, dir)

    if cast1 ~= nil then
        local snap: BasePart = cast1.Instance
        local pivot = snap:GetPivot()

        return {
            pos = pivot.Position,
            up = pivot.UpVector,
            forward = pivot.LookVector,
            snap = snap,
        }
    end
    
    castArgs.CollisionGroup = "Default"
    local cast2 = castArgs:Cast(origin, dir)
    
    if cast2 ~= nil then
        return {
            pos = cast2.Position,
            up = cast2.Normal,
            forward = nil,
            snap = nil
        }
    end
    
    return nil
end


----------------------------------
--  Coroutines
----------------------------------


local deferCleanup: {() -> nil} = {}


function pipeCoro()
    local activeCast: Snap?

    local headCast: Snap?
    local tailCast: Snap?
    local validShape = true

    local connection
    connection = UserInputService.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then
            if activeCast == nil then return end

            if headCast == nil then
                headCast = activeCast
            elseif validShape then
                tailCast = activeCast
                connection:Disconnect()
            end
        end
    end)

    local pipeHologram: Model?
    local snapHologram: Model?

    deferCleanup[#deferCleanup + 1] = function()
        connection:Disconnect()
        -- this has the hologram destroyed
        pipeHologram = maintainHologram(pipeModel, pipeHologram, false)
        snapHologram = maintainHologram(snapIndicatorModel, snapHologram, false)
    end
    
    while headCast == nil or tailCast == nil do
        local nextCast = getMouseTarget()

        -- only process frames with motion
        -- posA ~= posB not sufficient due to floating point error
        if nextCast == nil or
            activeCast ~= nil and (nextCast.pos - activeCast.pos).Magnitude < 0.1 then
                task.wait()
                continue
        end

        snapHologram = maintainHologram(snapIndicatorModel, snapHologram, headCast == nil)
        pipeHologram = maintainHologram(pipeModel, pipeHologram, headCast ~= nil)

        local canSnap = nextCast.snap ~= nil

        if headCast == nil then
            -- the canSnap parameter refers to the existence of a PipeSnap
            updateSnapIndicator(snapHologram, nextCast.pos, canSnap)
        else
            validShape = updatePipeBpShape(pipeHologram, headCast, nextCast)
            updatePipeBpColor(pipeHologram, validShape, canSnap)
        end

        -- setting the activeSnap enables the click listener
        -- to commit endpoints of the pipe
        activeCast = nextCast
        task.wait() -- yield to next frame
    end

    realizePipeBp(pipeHologram, headCast, tailCast)
    pipeHologram = nil -- prevents further modification
end


----------------------------------
--   Coroutine Management
----------------------------------


local buildThread: thread? = nil


-- kill a running coroutine
function tryKillCoro()
    if buildThread ~= nil then
        task.cancel(buildThread)

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
    if input.KeyCode == config.KEYBINDS.cancel then
        tryKillCoro()
    end
end)

local bindToCoro = {
    {config.KEYBINDS.pipe, pipeCoro}
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