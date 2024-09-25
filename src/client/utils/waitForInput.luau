local UserInputService = game:GetService("UserInputService")

function waitForInput(keyCode: Enum.KeyCode)
    local event = Instance.new("BindableEvent")
    
    local connection
    connection = UserInputService.InputBegan:Connect(function(input)
        if input.KeyCode == keyCode then
            event:Fire(input)
            connection:Disconnect()
        end
    end)
    
    return event.Event:Wait()
end

return waitForInput