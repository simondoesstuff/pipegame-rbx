local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(shared:WaitForChild("config"))
local Cast = require(shared:WaitForChild("utils"):WaitForChild("raycast"))
local PipeBuilder = require(shared:WaitForChild("pipeBuilder"))

local camera = workspace.CurrentCamera
local pipePlaceRemote: RemoteFunction = ReplicatedStorage:WaitForChild("Events"):WaitForChild("PipePlace")

-- TODO: these blocking calls should be moved into corresponding coroutines.
--     OK for now because almost all systems depend on these resources
--     so the bottleneck is not incurring a strong performance delta.
local models = ReplicatedStorage:WaitForChild("Models")
local pipeModel = models:WaitForChild("Pipe")
local snapIndicatorModel = models:WaitForChild("SnapIndicator")


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
                part.Transparency = Config.BLUEPRINT_TRANSPARENCY
            end
        end
    end

    return active
end


function updateSnapIndicator(model: Model, pos: Vector3?, snap: boolean?)
    model:MoveTo(pos)
    model.PrimaryPart.BrickColor = snap and Config.PIPE_COLORS.hologramValid or Config.PIPE_COLORS.default
end


function updatePipeBpColor(model: Model, valid: boolean, snap: boolean)
    if model == nil then return end

    -- pipe "valid" will be colored standard
    local color

    if not valid then
        color = Config.PIPE_COLORS.hologramInvalid
    elseif snap then
        color = Config.PIPE_COLORS.hologramValid
    else
        color = Config.PIPE_COLORS.default
    end

    for _, part: BasePart in pairs(model:GetDescendants()) do
        if not part:IsA("BasePart") then continue end
        if part:GetAttribute("doNotRecolor") == true then continue end
        part.BrickColor = color
    end
end


function solidifyBlueprint(model: Model)
    for _, part in pairs(model:GetDescendants()) do
        if part:IsA("BasePart") then
            part.CanQuery = true

            if part.Name == "PipeSnap" then continue end

            part.Transparency = 0
            part.CanCollide = true
            part.CastShadow = true
            -- let each individual part be unachored and instead form an assembly

            -- return colorable parts to default coloring
            if part:GetAttribute("doNotRecolor") ~= true then
                part.BrickColor = Config.PIPE_COLORS.default
            end
        end
    end
end


function getMouseTarget(exclude)
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
    castArgs.Exclude = exclude

    castArgs.CollisionGroup = "PipeSnap"
    local cast1 = castArgs:Cast(origin, dir)

    if cast1 ~= nil then
        local snap: BasePart = cast1.Instance
        local pivot = snap:GetPivot()

        return {
            pos = pivot.Position,
            up = pivot.UpVector,
            forward = pivot.LookVector,
            canSnap = true,
            snap = snap
        }
    end
    
    castArgs.CollisionGroup = "Default"
    local cast2 = castArgs:Cast(origin, dir)
    
    if cast2 ~= nil then
        return {
            pos = cast2.Position,
            up = cast2.Normal,
            forward = nil,
            canSnap = false,
            snap = nil
        }
    end
    
    return nil
end


----------------------------------
--  Coroutines
-- TODO: extract resourceful coroutine
----------------------------------


local clickConnection: RBXScriptConnection? = nil
local pipeHologram: Model?
local snapHologram: Model?


function pipeCoro()
    local activeCast: Placement?
    local headCast: Placement?
    local tailCast: Placement?
    local validShape = false

    clickConnection = UserInputService.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then
            if activeCast == nil then return end

            if headCast == nil then
                headCast = activeCast
            elseif validShape then
                tailCast = activeCast
                clickConnection:Disconnect()
            end
        end
    end)
    
    while headCast == nil or tailCast == nil do
        local exclude
        if headCast ~= nil then
            exclude = {headCast.snap}
        end

        local nextCast = getMouseTarget(exclude)

        -- only process frames with motion
        -- posA ~= posB not sufficient due to floating point error
        if nextCast == nil or
            activeCast ~= nil and (nextCast.pos - activeCast.pos).Magnitude < 0.1 then
                task.wait()
                continue
        end

        snapHologram = maintainHologram(snapIndicatorModel, snapHologram, headCast == nil)
        pipeHologram = maintainHologram(pipeModel, pipeHologram, headCast ~= nil)

        if headCast == nil then
            -- the canSnap parameter refers to the existence of a PipeSnap
            updateSnapIndicator(snapHologram, nextCast.pos, nextCast.canSnap)
        else
            validShape = PipeBuilder.shape(pipeHologram, headCast, nextCast)
            updatePipeBpColor(pipeHologram, validShape, nextCast.canSnap)
        end

        -- setting the activeSnap enables the click listener
        -- to commit endpoints of the pipe
        activeCast = nextCast
        task.wait() -- yield to next frame
    end

    solidifyBlueprint(pipeHologram)
    local hologramCopy = pipeHologram
    pipeHologram = nil
    
    coroutine.wrap(function()
        pipePlaceRemote:InvokeServer(headCast, tailCast)
        hologramCopy:Destroy()
    end)()
end


----------------------------------
--   Coroutine Management
----------------------------------


local buildThread: thread? = nil


-- kill a running coroutine
function softKillCoro()
    if buildThread == nil then return end
    task.cancel(buildThread)

    if clickConnection ~= nil then
        clickConnection:Disconnect()
        clickConnection = nil
    end

    pipeHologram = maintainHologram(pipeModel, pipeHologram, false)
    snapHologram = maintainHologram(snapIndicatorModel, snapHologram, false)
    buildThread = nil
end


function startCoro(coro)
    -- this guarantees proper handling of resources
    -- dead? --> start coroutine
    -- alive? --> kill & restart coroutine
    softKillCoro()
    buildThread = task.spawn(coro)
end


UserInputService.InputBegan:Connect(function(input)
    if input.KeyCode == Config.KEYBINDS.cancel then
        softKillCoro()
    end
end)

local bindToCoro = {
    {Config.KEYBINDS.pipe, pipeCoro}
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