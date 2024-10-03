local Config = require(script.Parent.config)
local projByNormal = require(script.Parent.utils.linearAlgebra).projByNormal
local Cast = require(script.Parent.utils.raycast)


local Public = {}


export type Placement = {
    pos: Vector3,
    up: Vector3,
    forward: Vector3?,
    canSnap: boolean
}


function Public.shape(model: Model, headSnap: Placement, tailSnap: Placement): boolean
    -- The entire model state is updated to match the source of truth.
    -- This prevents accumulative errors of any kind.

    -- this will run every frame as the mouse moves
    -- INFO: CRTICIAL ZONE:

    local headPart: BasePart = model:WaitForChild("Head")
    local tailPart: BasePart = model:WaitForChild("Tail")

    -- 1. non snapped endpoints need to be raised to avoid clipping

    local headPos = headSnap.pos
    local tailPos = tailSnap.pos
    local endpointRadius = headPart:WaitForChild("Tip").Size.Y / 2

    if not headSnap.canSnap then
        headPos += headSnap.up * endpointRadius
    end

    if not tailSnap.canSnap then
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
        headJointPos = headPart:WaitForChild("Joint").Position
    end

    if tailDir ~= nil then
        tailPart:PivotTo(CFrame.lookAlong(tailPos, tailDir))
        tailJointPos = tailPart:WaitForChild("Joint").Position
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
        headJointPos = headPart:WaitForChild("Joint").Position

        tailPart:PivotTo(CFrame.lookAlong(tailPos, tailDir))
        tailJointPos = tailPart:WaitForChild("Joint").Position
    end

    local shaftVec = tailJointPos - headJointPos
    local pipeLength = shaftVec.Magnitude

    -- 3. adjust pipe shaft to fit distance

    local shaftPart: BasePart = model.Shaft
    shaftPart.Size = Vector3.new(pipeLength, shaftPart.Size.Y, shaftPart.Size.Z)
    local shaftCenter = (headJointPos + tailJointPos) / 2
    shaftPart:PivotTo(CFrame.new(shaftCenter, tailJointPos))

    -- 4. checking for validity of placement

    if pipeLength > Config.MAX_PIPE_LENGTH then
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
    if shaftVec.Unit:Dot(-headDir.Unit) > Config.MIN_PIPE_HINGE_ANGLE then
        return false
    end

    if shaftVec.Unit:Dot(tailDir.Unit) > Config.MIN_PIPE_HINGE_ANGLE then
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


return Public