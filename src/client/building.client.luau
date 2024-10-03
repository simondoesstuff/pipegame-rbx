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


-- TODO: extract
function projByNormal(vector: Vector3, normal: Vector3)
    -- Projects a vector into the plane of the normal.
    normal = normal.Unit
    return vector - normal:Dot(vector) * normal
end


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
                part.Transparency = BLUEPRINT_TRANSPARENCY
            end
        end
    end

    return active
end


function updateSnapIndicator(model: Model, pos: Vector3?, snap: boolean?)
    model:MoveTo(pos)
    model.PrimaryPart.BrickColor = snap and PIPE_COLORS.hologramValid or PIPE_COLORS.default
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

    local shaftVec = headJointPos - tailJointPos
    local pipeLength = shaftVec.Magnitude

    -- 3. adjust pipe shaft to fit distance

    local shaftPart: BasePart = model.Shaft
    shaftPart.Size = Vector3.new(pipeLength, shaftPart.Size.Y, shaftPart.Size.Z)
    local shaftCenter = (headJointPos + tailJointPos) / 2
    shaftPart:PivotTo(CFrame.new(shaftCenter, tailJointPos))

    -- 4. checking for validity of placement
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


function updatePipeBpColor(model: Model, valid: boolean, snap: boolean)
    if model == nil then return end

    -- pipe "valid" will be colored standard
    local color

    if not valid then
        color = PIPE_COLORS.hologramInvalid
    elseif snap then
        color = PIPE_COLORS.hologramValid
    else
        color = PIPE_COLORS.default
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
        model.Head.PipeSnap.CanQuery = false -- local snap
    end

    if tailSnap.snap ~= nil then
        tailSnap.snap.CanQuery = false -- remote snap
        model.Tail.PipeSnap.CanQuery = false -- local snap
    end
end


-- Snap encapsulates information regarding potential snap points
-- but is overloaded for the case of a position without snap
type Snap = {
    pos: Vector3,
    up: Vector3,
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
    raycastParams.FilterDescendantsInstances = { player.Character }
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
            up = pivot.UpVector,
            forward = pivot.LookVector,
            snap = snap,
        }
    end

    return {
        pos = raycastResult.Position,
        up = raycastResult.Normal,
        forward = nil,
        snap = nil
    }
end


----------------------------------
--  Coroutines
----------------------------------


local deferCleanup: {() -> nil} = {}


function junct3Coro()
    error('not implemented') -- TODO:
end


function pipeCoro()
    print("Good morning!") -- TODO: rm

    local activeCast: Snap?

    -- don't start primary algorithm until at least one
    -- valid mouse position has been found
    while activeCast == nil do
        activeCast = getMouseTarget()
    end

    local headCast: Snap?
    local tailCast: Snap?
    local validShape = true

    local connection
    connection = UserInputService.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then
            if activeCast == nil then return end

            print('click', headCast, tailCast) -- TODO: rm
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
    end

    print('beginning loop')
    while headCast == nil or tailCast == nil do
        local nextCast = getMouseTarget()

        -- only process frames with motion
        -- posA ~= posB not sufficient due to floating point error
        if nextCast == nil or
            (nextCast.pos - activeCast.pos).Magnitude < 0.1 then
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

    print("Pipe built!") -- TODO: rm
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

        if model ~= nil then
            model:Destroy()
            model = nil
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
