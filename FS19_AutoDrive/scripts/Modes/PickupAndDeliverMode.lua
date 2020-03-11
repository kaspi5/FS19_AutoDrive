PickupAndDeliverMode = ADInheritsFrom(AbstractMode)

PickupAndDeliverMode.STATE_DELIVER = 1
PickupAndDeliverMode.STATE_PICKUP = 2
PickupAndDeliverMode.STATE_FINISHED = 3

function PickupAndDeliverMode:new(vehicle)
    local o = PickupAndDeliverMode:create()
    o.vehicle = vehicle
    PickupAndDeliverMode.reset(o)
    return o
end

function PickupAndDeliverMode:reset()
    self.state = PickupAndDeliverMode.STATE_DELIVER
    self.loopsDone = 0
    self.activeTask = nil
end

function PickupAndDeliverMode:start()
    print("PickupAndDeliverMode:start")
    if not self.vehicle.ad.isActive then
        AutoDrive:startAD(self.vehicle)
    end

    local trailers, _ = AutoDrive.getTrailersOf(self.vehicle, false)
    local fillLevel, leftCapacity = AutoDrive.getFillLevelAndCapacityOfAll(trailers)
    local maxCapacity = fillLevel + leftCapacity

    if (leftCapacity <= (maxCapacity * (1 - AutoDrive.getSetting("unloadFillLevel", self.vehicle) + 0.001))) then
        self.state = PickupAndDeliverMode.STATE_PICKUP
    end

    if ADGraphManager:getMapMarkerById(self.vehicle.ad.mapMarkerSelected) == nil or ADGraphManager:getMapMarkerById(self.vehicle.ad.mapMarkerSelected_Unload) == nil then
        return
    end

    self.activeTask = self:getNextTask()
    if self.activeTask ~= nil then
        self.vehicle.ad.taskModule:addTask(self.activeTask)
    end
end

function PickupAndDeliverMode:monitorTasks(dt)
end

function PickupAndDeliverMode:handleFinishedTask()
    print("PickupAndDeliverMode:handleFinishedTask")
    self.vehicle.ad.trailerModule:reset()
    self.activeTask = self:getNextTask()
    if self.activeTask ~= nil then
        self.vehicle.ad.taskModule:addTask(self.activeTask)
    end
end

function PickupAndDeliverMode:stop()
end

function PickupAndDeliverMode:continue()
    if self.state == PickupAndDeliverMode.STATE_PICKUP then
        self.activeTask:continue()
    end
end

function PickupAndDeliverMode:getNextTask()
    local nextTask
    if self.state == PickupAndDeliverMode.STATE_DELIVER then
        print("PickupAndDeliverMode:getNextTask() - self.state == PickupAndDeliverMode.STATE_DELIVER")
        if self.vehicle.ad.loopCounterSelected == 0 or self.loopsDone < self.vehicle.ad.loopCounterSelected then
            nextTask = LoadAtDestinationTask:new(self.vehicle, self.vehicle.ad.targetSelected)
            self.state = PickupAndDeliverMode.STATE_PICKUP
        else
            nextTask = StopAndDisableADTask:new(self.vehicle, ADTaskModule.DONT_PROPAGATE)
            self.state = PickupAndDeliverMode.STATE_FINISHED
        end
    elseif self.state == PickupAndDeliverMode.STATE_PICKUP then
        print("PickupAndDeliverMode:getNextTask() - nextTask: = UnloadAtDestinationTask")
        nextTask = UnloadAtDestinationTask:new(self.vehicle, self.vehicle.ad.targetSelected_Unload)
        self.loopsDone = self.loopsDone + 1
        self.state = PickupAndDeliverMode.STATE_DELIVER
    end

    return nextTask
end

function PickupAndDeliverMode:shouldUnloadAtTrigger()
    return self.state == PickupAndDeliverMode.STATE_DELIVER and (AutoDrive.getDistanceToUnloadPosition(self.vehicle) <= AutoDrive.getSetting("maxTriggerDistance"))
end

function PickupAndDeliverMode:shouldLoadOnTrigger()
    return self.state == PickupAndDeliverMode.STATE_PICKUP and (AutoDrive.getDistanceToTargetPosition(self.vehicle) <= AutoDrive.getSetting("maxTriggerDistance"))
end