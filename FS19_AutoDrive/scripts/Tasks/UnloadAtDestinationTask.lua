UnloadAtDestinationTask = ADInheritsFrom(AbstractTask)

UnloadAtDestinationTask.STATE_PATHPLANNING = 1
UnloadAtDestinationTask.STATE_DRIVING = 2

function UnloadAtDestinationTask:new(vehicle, destinationID)
    local o = UnloadAtDestinationTask:create()
    o.vehicle = vehicle
    o.destinationID = destinationID
    return o
end

function UnloadAtDestinationTask:setUp()
    print("Setting up UnloadAtDestinationTask")
    if ADGraphManager:getDistanceFromNetwork(self.vehicle) > 30 then
        self.state = UnloadAtDestinationTask.STATE_PATHPLANNING
        self.vehicle.ad.pathFinderModule:startPathPlanningToNetwork(self.destinationID)
    else
        self.state = UnloadAtDestinationTask.STATE_DRIVING
        self.vehicle.ad.drivePathModule:setPathTo(self.destinationID)
    end
end

function UnloadAtDestinationTask:update(dt)
    if self.state == UnloadAtDestinationTask.STATE_PATHPLANNING then
        if self.vehicle.ad.pathFinderModule:hasFinished() then
            self.wayPoints = self.vehicle.ad.pathFinderModule:getPath()
            self.vehicle.ad.drivePathModule:setWayPoints(self.wayPoints)
            self.state = UnloadAtDestinationTask.STATE_DRIVING
        else
            self.vehicle.ad.pathFinderModule:update()
            self.vehicle.ad.specialDrivingModule:stopVehicle()
            self.vehicle.ad.specialDrivingModule:update(dt)
        end
    else
        if self.vehicle.ad.drivePathModule:isTargetReached() then
            self:finished()
        else
            self.vehicle.ad.trailerModule:update(dt)
            self.vehicle.ad.specialDrivingModule:releaseVehicle()
            if self.vehicle.ad.trailerModule:isActiveAtTrigger() then
                --print("UnloadAtDestinationTask - trailerModule:isActiveAtTrigger()")
                if self.vehicle.ad.trailerModule:isUnloadingToBunkerSilo() then
                    self.vehicle.ad.drivePathModule:update(dt)
                else
                    --print("UnloadAtDestinationTask - trailerModule:isActiveAtTrigger() - stop Vehicle")
                    self.vehicle.ad.specialDrivingModule:stopVehicle()
                    self.vehicle.ad.specialDrivingModule:update(dt)
                end
            else
                self.vehicle.ad.drivePathModule:update(dt)
            end
        end
    end    
end

function UnloadAtDestinationTask:abort()
end

function UnloadAtDestinationTask:finished()
    self.vehicle.ad.taskModule:setCurrentTaskFinished()
end
