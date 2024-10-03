local ReplicatedStorage = game:GetService("ReplicatedStorage")
local shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(shared:WaitForChild("config"))

local SNAP_RADIUS = Config.SNAP_RADIUS

-- Adjusts all PipeSnap radii at start time for the client only.
-- This enables the client to configure this value later if desired.
-- Modifying all PipeSnaps in RepStore at init time is a one-time cost,
-- but avoids PartsInRadius scans or SphereCasts later. This will result
-- in more performant and accurate snaps.
for _, part in ReplicatedStorage:GetDescendants() do
    if part:IsA("BasePart") then
        if part.CollisionGroup == "PipeSnap" then
            part.Size = Vector3.new(SNAP_RADIUS, SNAP_RADIUS, SNAP_RADIUS)
        end
    end
end