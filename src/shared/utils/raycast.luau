local Players = game:GetService("Players")


function playersSet()
    local playerSet = {}
    
    for _, player in ipairs(Players:GetPlayers()) do
        local char = player.Character

        -- only loaded characters are relevant
        if char then
            table.insert(playerSet, char)
        end
    end
    
    return playerSet
end


export type Cast = {
    IgnoreWater: boolean,
    IgnorePlayers: boolean,
    CollisionGroup: string,
    Exclude: {Instance},
    Include: {Instance},
}


local Cast: Cast = {}


function Cast.new()
    local self = setmetatable({}, {__index = Cast})
    self.IgnoreWater = true
    self.IgnorePlayers = false
    self.CollisionGroup = "Default"
    self.Exclude = nil
    self.Include = nil
    return self
end


function Cast:FilterType()
    -- this makes the default Exclude
    if self.Include == nil then
        return {Enum.RaycastFilterType.Exclude, self.Exclude or {}}
    end

    if self.Exclude == nil then
        return {Enum.RaycastFilterType.Include, self.Include or {}}
    end
    
    error("Invalid filter type, one of Exclude or Include must be unset.")
end


function Cast:Cast(origin, direction)
    local castArgs = RaycastParams.new()
    castArgs.IgnoreWater = self.IgnoreWater
    castArgs.CollisionGroup = self.CollisionGroup

    local filter = self:FilterType()
    local filterType = filter[1]
    local filterContent = filter[2]

    castArgs.FilterType = filterType
    
    if self.IgnorePlayers then
        if castArgs.FilterType == Enum.RaycastFilterType.Exclude then
            filterContent = {
                unpack(filterContent),
                unpack(playersSet())
            }
        else
            error("Invalid filter type, IgnorePlayers requires Exclude filter type.")
        end
    end
    
    castArgs.FilterDescendantsInstances = filterContent
    return workspace:Raycast(origin, direction, castArgs)
end


return Cast