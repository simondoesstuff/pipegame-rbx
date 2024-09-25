local UserInputService = game:GetService("UserInputService")
local player = game:GetService("Players").LocalPlayer
local mouse = player:GetMouse()

local Public = {}

function Public.isClicking()
    return UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1)
end

function Public.rangeHover(range)
    -- Returns mouse positions when hovered over a part and
    -- within range.
    if mouse.Target == nil then return nil end

    local mousePos = mouse.Hit.Position
    local playerPos = player.Character.HumanoidRootPart.Position
   
    if (mousePos - playerPos).Magnitude > range then return nil end
    return mousePos
end

return Public