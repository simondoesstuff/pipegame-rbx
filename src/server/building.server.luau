local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local shared = ReplicatedStorage:WaitForChild("Shared")
local PipeBuilder = require(shared:WaitForChild("pipeBuilder"))

local pipePlaceRemote: RemoteFunction = ReplicatedStorage:WaitForChild("Events"):WaitForChild("PipePlace")
local models = ReplicatedStorage:WaitForChild("Models")
local pipeModel = models:WaitForChild("Pipe")


function solidyBlueprint(model)
        -- solidifies the pipe blueprint hologram into a physical pipe
    local primaryPart = model.PrimaryPart

    -- TODO: pipe anchor state needs to be based on snapping
    primaryPart.Anchored = true

    -- Solidify the hologram
    for _, part in pairs(model:GetDescendants()) do
        if part:IsA("BasePart") then
            if part == primaryPart then continue end

            -- let each part be welded to the primary part
            local weld = Instance.new('WeldConstraint')
            weld.Parent = part
            weld.Part0 = primaryPart
            weld.Part1 = part

            part.CanQuery = true
            part.Anchored = false
        end
    end
end


function weldSnaps(model: Model)
    local scanArgs = OverlapParams.new()
    scanArgs.CollisionGroup = "PipeSnap"

    for _, domestic in pairs(model:GetDescendants()) do
        if not domestic:IsA("BasePart") then continue end
        if domestic.CollisionGroup ~= "PipeSnap" then continue end

        local neighbors = workspace:GetPartsInPart(domestic, scanArgs)
        
        if #neighbors > 1 then
            warn("Attemping to join one pipe snap to multiple others.")
        end

        for _, foreign in pairs(neighbors) do
            if foreign == domestic then continue end

            -- TODO: this is a hacky way to check if an assembly is a hologram
            if foreign.AssemblyRootPart.Transparency < 1 then continue end
            if (foreign:GetPivot().Position - domestic:GetPivot().Position).Magnitude > 0.2 then continue end

            local weld = Instance.new('WeldConstraint')
            weld.Parent = domestic
            weld.Part0 = domestic
            weld.Part1 = foreign
            
            foreign.CanQuery = false
            domestic.CanQuery = false
        end
    end
end


pipePlaceRemote.OnServerInvoke = function(sender: Player, headSnap: Placement, tailSnap: Placement)
    local model = pipeModel:Clone()
    local valid = PipeBuilder.shape(model, headSnap, tailSnap)

    if not valid then
        -- TODO: handle security flags
        warn("Client sent pipe with invalid configuration.")
        return
    end

    solidyBlueprint(model)
    weldSnaps(model)
    model.Parent = Workspace

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