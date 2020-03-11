function AutoDrive.prerequisitesPresent(specializations)
    return SpecializationUtil.hasSpecialization(Motorized, specializations) and SpecializationUtil.hasSpecialization(Drivable, specializations) and SpecializationUtil.hasSpecialization(Enterable, specializations)
end

function AutoDrive.registerEventListeners(vehicleType)
    -- "onReadUpdateStream", "onWriteUpdateStream"
    for _, n in pairs({"load", "onUpdate", "onRegisterActionEvents", "onDelete", "onDraw", "onPostLoad", "onLoad", "saveToXMLFile", "onReadStream", "onWriteStream"}) do
        SpecializationUtil.registerEventListener(vehicleType, n, AutoDrive)
    end
end

function AutoDrive.registerOverwrittenFunctions(vehicleType)
    SpecializationUtil.registerOverwrittenFunction(vehicleType, "updateAILights", AutoDrive.updateAILights)
    SpecializationUtil.registerOverwrittenFunction(vehicleType, "getCanMotorRun", AutoDrive.getCanMotorRun)
end

function AutoDrive:onRegisterActionEvents(isSelected, isOnActiveVehicle)
    -- continue on client side only
    -- TODO: I think we should remove that since everyone 'isClient' even the dedicated server (if I'm not wrong)
    if not self.isClient then
        return
    end

    local registerEvents = isOnActiveVehicle
    if self.ad ~= nil then
        registerEvents = registerEvents or self == g_currentMission.controlledVehicle -- or self.ad.isActive;
    end

    -- only in active vehicle
    if registerEvents then
        -- we could have more than one event, so prepare a table to store them
        if self.ActionEvents == nil then
            self.ActionEvents = {}
        else
            --self:clearActionEventsTable( self.ActionEvents )
        end

        -- attach our actions
        local _, eventName
        local toggleButton = false
        local showF1Help = AutoDrive.getSetting("showHelp")
        for _, action in pairs(AutoDrive.actions) do
            _, eventName = InputBinding.registerActionEvent(g_inputBinding, action[1], self, AutoDrive.onActionCall, toggleButton, true, false, true)
            g_inputBinding:setActionEventTextVisibility(eventName, action[2] and showF1Help)
            if showF1Help then
                g_inputBinding:setActionEventTextPriority(eventName, action[3])
            end
        end
    end
end

function AutoDrive:onLoad(savegame)
    -- This will run before initial MP sync
    self.ad = {}
    self.ad.smootherDriving = {}
    self.ad.smootherDriving.lastMaxSpeed = 0
    self.ad.targetSelected = -1
    self.ad.mapMarkerSelected = -1
    self.ad.nameOfSelectedTarget = ""
    self.ad.targetSelected_Unload = -1
    self.ad.mapMarkerSelected_Unload = -1
    self.ad.nameOfSelectedTarget_Unload = ""
    self.ad.groups = {}
    
    self.ad.taskModule = ADTaskModule:new(self)
    self.ad.trailerModule = ADTrailerModule:new(self)
    self.ad.drivePathModule = ADDrivePathModule:new(self)
    self.ad.specialDrivingModule = ADSpecialDrivingModule:new(self)
    self.ad.collisionDetectionModule = ADCollisionDetectionModule:new(self)
    self.ad.pathFinderModule = PathFinderModule:new(self)

    self.ad.modes = {}
    self.ad.modes[AutoDrive.MODE_DRIVETO] = DriveToMode:new(self)
    self.ad.modes[AutoDrive.MODE_DELIVERTO] = UnloadAtMode:new(self)
    self.ad.modes[AutoDrive.MODE_PICKUPANDDELIVER] = PickupAndDeliverMode:new(self)
    self.ad.modes[AutoDrive.MODE_LOAD] = LoadMode:new(self)
    self.ad.modes[AutoDrive.MODE_BGA] = BGAMode:new(self)
    self.ad.modes[AutoDrive.MODE_UNLOAD] = CombineUnloaderMode:new(self)
end

function AutoDrive:onPostLoad(savegame)
    -- This will run before initial MP sync
    if self.isServer then
        if savegame ~= nil then
            local xmlFile = savegame.xmlFile
            local key = savegame.key .. ".FS19_AutoDrive.AutoDrive"

            local mode = getXMLInt(xmlFile, key .. "#mode")
            if mode ~= nil then
                self.ad.mode = mode
            end
            local targetSpeed = getXMLInt(xmlFile, key .. "#targetSpeed")
            if targetSpeed ~= nil then
                self.ad.targetSpeed = math.min(targetSpeed, AutoDrive.getVehicleMaxSpeed(self))
            end

            local mapMarkerSelected = getXMLInt(xmlFile, key .. "#mapMarkerSelected")
            if mapMarkerSelected ~= nil then
                self.ad.mapMarkerSelected = mapMarkerSelected
            end

            local mapMarkerSelected_Unload = getXMLInt(xmlFile, key .. "#mapMarkerSelected_Unload")
            if mapMarkerSelected_Unload ~= nil then
                self.ad.mapMarkerSelected_Unload = mapMarkerSelected_Unload
            end
            local unloadFillTypeIndex = getXMLInt(xmlFile, key .. "#unloadFillTypeIndex")
            if unloadFillTypeIndex ~= nil then
                self.ad.unloadFillTypeIndex = unloadFillTypeIndex
            end
            local driverName = getXMLString(xmlFile, key .. "#driverName")
            if driverName ~= nil then
                self.ad.driverName = driverName
            end
            local selectedLoopCounter = getXMLInt(xmlFile, key .. "#loopCounterSelected")
            if selectedLoopCounter ~= nil then
                self.ad.loopCounterSelected = selectedLoopCounter
            end
            local parkDestination = getXMLInt(xmlFile, key .. "#parkDestination")
            if parkDestination ~= nil then
                self.ad.parkDestination = parkDestination
            end

            local groupString = getXMLString(xmlFile, key .. "#groups")
            if groupString ~= nil then
                local groupTable = groupString:split(";")
                for _, groupCombined in pairs(groupTable) do
                    local groupNameAndBool = groupCombined:split(",")
                    if tonumber(groupNameAndBool[2]) >= 1 then
                        self.ad.groups[groupNameAndBool[1]] = true
                    else
                        self.ad.groups[groupNameAndBool[1]] = false
                    end
                end
            end

            AutoDrive.readVehicleSettingsFromXML(self, xmlFile, key)
        end
    end

    AutoDrive.init(self)

    -- Creating a new transform on front of the vehicle
    self.ad.frontNode = createTransformGroup(self:getName() .. "_frontNode")
    link(self.components[1].node, self.ad.frontNode)
    setTranslation(self.ad.frontNode, 0, 0, self.sizeLength / 2 + self.lengthOffset + 0.75)
    self.ad.frontNodeGizmo = DebugGizmo:new()
end

function AutoDrive:init()
    self.ad.isActive = false
    self.ad.initialized = false
    self.ad.creationMode = false
    self.ad.creationModeDual = false

    if self.ad.settings == nil then
        AutoDrive.copySettingsToVehicle(self)
    end

    if AutoDrive ~= nil then
        local set = false
        if self.ad.mapMarkerSelected ~= nil then
            if ADGraphManager:getMapMarkerById(self.ad.mapMarkerSelected) ~= nil then
                self.ad.targetSelected = ADGraphManager:getMapMarkerById(self.ad.mapMarkerSelected).id
                self.ad.nameOfSelectedTarget = ADGraphManager:getMapMarkerById(self.ad.mapMarkerSelected).name
                set = true
            end
        end
        if not set then
            self.ad.mapMarkerSelected = 1
            if ADGraphManager:getMapMarkerById(1) ~= nil then
                self.ad.targetSelected = ADGraphManager:getMapMarkerById(1).id
                self.ad.nameOfSelectedTarget = ADGraphManager:getMapMarkerById(1).name
            end
        end
    end
    if self.ad.mode == nil then
        self.ad.mode = AutoDrive.MODE_DRIVETO
    end
    if self.ad.targetSpeed == nil then
        self.ad.targetSpeed = AutoDrive.getVehicleMaxSpeed(self) --math.min(AutoDrive.getVehicleMaxSpeed(self), AutoDrive.lastSetSpeed)
    end
    self.ad.createMapPoints = false
    self.ad.extendedEditorMode = false
    self.ad.displayMapPoints = false
    self.ad.showClosestPoint = true
    self.ad.selectedDebugPoint = -1
    self.ad.showSelectedDebugPoint = false
    self.ad.changeSelectedDebugPoint = false
    self.ad.iteratedDebugPoints = {}
    self.ad.inDeadLock = false
    self.ad.timeTillDeadLock = 15000
    self.ad.inDeadLockRepairCounter = 4

    self.ad.creatingMapMarker = false

    self.name = g_i18n:getText("UNKNOWN")
    if self.getName ~= nil then
        self.name = self:getName()
    end
    if self.ad.driverName == nil then
        self.ad.driverName = self.name
    end

    self.ad.moduleInitialized = true
    self.ad.currentInput = ""

    if self.ad.unloadFillTypeIndex == nil then
        self.ad.unloadFillTypeIndex = 2
    end
    
    self.ad.combineUnloadInFruit = false
    self.ad.combineUnloadInFruitWaitTimer = AutoDrive.UNLOAD_WAIT_TIMER
    self.ad.combineFruitToCheck = nil
    self.ad.driverOnTheWay = false
    self.ad.tryingToCallDriver = false
    self.ad.stoppedTimer = 5000
    self.ad.driveForwardTimer = AutoDriveTON:new()
    self.ad.closeCoverTimer = AutoDriveTON:new()
    self.ad.currentTrailer = 1
    self.ad.usePathFinder = false

    self.ad.onRouteToPark = false

    if AutoDrive ~= nil then
        local set = false
        if self.ad.mapMarkerSelected_Unload ~= nil then
            if ADGraphManager:getMapMarkerById(self.ad.mapMarkerSelected_Unload) ~= nil then
                self.ad.targetSelected_Unload = ADGraphManager:getMapMarkerById(self.ad.mapMarkerSelected_Unload).id
                self.ad.nameOfSelectedTarget_Unload = ADGraphManager:getMapMarkerById(self.ad.mapMarkerSelected_Unload).name
                set = true
            end
        end
        if not set then
            self.ad.mapMarkerSelected_Unload = 1
            if ADGraphManager:getMapMarkerById(1) ~= nil then
                self.ad.targetSelected_Unload = ADGraphManager:getMapMarkerById(1).id
                self.ad.nameOfSelectedTarget_Unload = ADGraphManager:getMapMarkerById(1).name
            end
        end
    end

    self.ad.nToolTipWait = 300
    self.ad.sToolTip = ""

    if AutoDrive.showingHud ~= nil then
        self.ad.showingHud = AutoDrive.showingHud
    else
        self.ad.showingHud = true
    end
    self.ad.showingMouse = false

    -- Variables the server sets so that the clients can act upon it:
    self.ad.disableAI = 0
    self.ad.enableAI = 0

    self.ad.combineState = AutoDrive.COMBINE_UNINITIALIZED
    self.ad.currentCombine = nil
    self.ad.currentDriver = nil

    if self.spec_autodrive == nil then
        self.spec_autodrive = AutoDrive
    end

    self.ad.pullDownList = {}
    self.ad.pullDownList.active = false
    self.ad.pullDownList.start = false
    self.ad.pullDownList.destination = false
    self.ad.pullDownList.fillType = false
    self.ad.pullDownList.itemList = {}
    self.ad.pullDownList.selectedItem = nil
    self.ad.pullDownList.posX = 0
    self.ad.pullDownList.posY = 0
    self.ad.pullDownList.width = 0
    self.ad.pullDownList.height = 0
    self.ad.lastMouseState = false

    if self.ad.loopCounterSelected == nil then
        self.ad.loopCounterSelected = 0
    end

    if self.ad.parkDestination == nil then
        self.ad.parkDestination = -1
    end
    
    self.ad.noMovementTimer = AutoDriveTON:new()
    self.ad.noTurningTimer = AutoDriveTON:new()

    if self.ad.groups == nil then
        self.ad.groups = {}
    end
    for groupName, _ in pairs(AutoDrive.groups) do
        if self.ad.groups[groupName] == nil then
            self.ad.groups[groupName] = false
        end
    end
    self.ad.reverseTimer = 3000
    self.ad.ccMode = AutoDrive.CC_MODE_IDLE
    self.ccInfos = {}
    self.ad.distanceToCombine = math.huge
    self.ad.destinationFilterText = ""
    self.ad.pointsInProximity = {}
    self.ad.lastPointCheckedForProximity = 1

    if self.spec_pipe ~= nil and self.spec_enterable ~= nil and self.getIsBufferCombine ~= nil then
        ADHarvestManager:registerHarvester(self)
    end
end

function AutoDrive:onPreLeaveVehicle()
    if self.ad == nil then
        return
    end
    -- We have to do that only for the player who were in the vehicle ( this also fix mouse cursor hiding bug in MP )
    if self.getIsEntered ~= nil and self:getIsEntered() then
        local storedshowingHud = self.ad.showingHud
        if g_inputBinding:getShowMouseCursor() == true and (g_currentMission.controlledVehicle == nil or (g_currentMission.controlledVehicle.ad.showingHud == false) or self == g_currentMission.controlledVehicle) then
            g_inputBinding:setShowMouseCursor(false)
            AutoDrive:onToggleMouse(self)
        end
        self.ad.showingHud = storedshowingHud
        if (g_currentMission.controlledVehicle == nil or (g_currentMission.controlledVehicle.ad.showingHud == false) or self == g_currentMission.controlledVehicle) then
            AutoDrive.Hud:closeAllPullDownLists(self)
        end
    end
end
Enterable.leaveVehicle = Utils.prependedFunction(Enterable.leaveVehicle, AutoDrive.onPreLeaveVehicle)

function AutoDrive:onToggleMouse(vehicle)
    if g_inputBinding:getShowMouseCursor() == true then
        if vehicle.spec_enterable ~= nil then
            if vehicle.spec_enterable.cameras ~= nil then
                for _, camera in pairs(vehicle.spec_enterable.cameras) do
                    camera.allowTranslation = false
                    camera.isRotatable = false
                end
            end
        end
    else
        if vehicle.spec_enterable ~= nil then
            if vehicle.spec_enterable.cameras ~= nil then
                for _, camera in pairs(vehicle.spec_enterable.cameras) do
                    camera.allowTranslation = true
                    camera.isRotatable = true
                end
            end
        end
    end

    vehicle.ad.lastMouseState = g_inputBinding:getShowMouseCursor()
end

function AutoDrive:onWriteStream(streamId, connection)
    for settingName, setting in pairs(AutoDrive.settings) do
        if setting ~= nil and setting.isVehicleSpecific then
            streamWriteInt16(streamId, AutoDrive.getSettingState(settingName, self))
        end
    end
    streamWriteUInt8(streamId, self.ad.targetSpeed)
    streamWriteUIntN(streamId, self.ad.parkDestination or 0, 20)
end

function AutoDrive:onReadStream(streamId, connection)
    for settingName, setting in pairs(AutoDrive.settings) do
        if setting ~= nil and setting.isVehicleSpecific then
            self.ad.settings[settingName].current = streamReadInt16(streamId)
        end
    end
    self.ad.targetSpeed = streamReadUInt8(streamId)
    self.ad.parkDestination = streamReadUIntN(streamId, 20)
end

function AutoDrive:onUpdate(dt)
    if self.ad.currentInput ~= "" and self.isServer then
        AutoDrive:InputHandling(self, self.ad.currentInput)
    end

    self.ad.closest = nil
    
    self.ad.taskModule:update(dt)

    AutoDrive:handleRecording(self)
    ADSensor:handleSensors(self, dt)
    AutoDrive:handleVehicleIntegrity(self)
    AutoDrive.handleVehicleMultiplayer(self, dt)
    AutoDrive:handleDriverWages(self, dt)   

    if g_currentMission.controlledVehicle == self and AutoDrive.getDebugChannelIsSet(AutoDrive.DC_VEHICLEINFO) then
        AutoDrive.renderTable(0.1, 0.9, 0.012, AutoDrive:createVehicleInfoTable(self), 5)
    end

    local vehicleSteering = self.rotatedTime ~= nil and (math.deg(self.rotatedTime) > 10)
    if (not vehicleSteering) and ((self.lastSpeedReal * self.movingDirection) >= 0.0008) then
        self.ad.driveForwardTimer:timer(true, 20000, dt)
    else
        self.ad.driveForwardTimer:timer(false)
    end

    if math.abs(self.lastSpeedReal) <= 0.0005 then
        self.ad.stoppedTimer = math.max(0, self.ad.stoppedTimer - dt)
    else
        self.ad.stoppedTimer = 5000
    end

    if self.isServer and self.ad.isActive and self.lastMovedDistance > 0 then
        g_currentMission:farmStats(self:getOwnerFarmId()):updateStats("driversTraveledDistance", self.lastMovedDistance * 0.001)
    end
end

function AutoDrive:createVehicleInfoTable(vehicle)
    local infoTable = {}

    infoTable["isActive"] = vehicle.ad.isActive
    infoTable["mode"] = AutoDriveHud:getModeName(vehicle)
    infoTable["onRouteToRefuel"] = vehicle.ad.onRouteToRefuel
    infoTable["unloadFillTypeIndex"] = vehicle.ad.unloadFillTypeIndex
    infoTable["combineUnloadInFruit"] = vehicle.ad.combineUnloadInFruit
    infoTable["combineFruitToCheck"] = vehicle.ad.combineFruitToCheck
    infoTable["currentTrailer"] = vehicle.ad.currentTrailer
    infoTable["combineState"] = AutoDrive.combineStateToName(vehicle)
    infoTable["ccMode"] = AutoDrive.combineCCStateToName(vehicle)
    infoTable["initialized"] = vehicle.ad.initialized

    local vehicleFull, trailerFull, fillUnitFull = AutoDrive.getIsFilled(vehicle, vehicle.ad.isLoadingToTrailer, vehicle.ad.isLoadingToFillUnitIndex)
    local vehicleEmpty, trailerEmpty, fillUnitEmpty = AutoDrive.getIsEmpty(vehicle, vehicle.ad.isUnloadingWithTrailer, vehicle.ad.isUnloadingWithFillUnit)
    local trailers, trailerCount = AutoDrive.getTrailersOf(vehicle, false)
    local fillLevel, leftCapacity = AutoDrive.getFillLevelAndCapacityOfAll(trailers)
    local maxCapacity = fillLevel + leftCapacity

    infoTable["Filllevels"] = {}
    infoTable["Filllevels"]["vehicle"] = {}
    infoTable["Filllevels"]["vehicle"]["fillLevel"] = fillLevel
    infoTable["Filllevels"]["vehicle"]["leftCapacity"] = leftCapacity
    infoTable["Filllevels"]["vehicle"]["maxCapacity"] = maxCapacity
    infoTable["Filllevels"]["vehicle"]["trailerCount"] = trailerCount
    infoTable["Filllevels"]["vehicle"]["filled"] = vehicleFull
    infoTable["Filllevels"]["vehicle"]["empty"] = vehicleEmpty
    infoTable["Filllevels"]["vehicle"]["trailerFull"] = trailerFull
    infoTable["Filllevels"]["vehicle"]["fillUnitFull"] = fillUnitFull
    infoTable["Filllevels"]["vehicle"]["trailerEmpty"] = trailerEmpty
    infoTable["Filllevels"]["vehicle"]["fillUnitEmpty"] = fillUnitEmpty

    local trailerIndex = 1
    if trailers ~= nil then
        for _, trailer in pairs(trailers) do
            local trailerFillLevel, trailerLeftCapacity = AutoDrive.getFilteredFillLevelAndCapacityOfAllUnits(trailer, nil)
            local trailerMaxCapacity = trailerFillLevel + trailerLeftCapacity
            vehicleFull, trailerFull, fillUnitFull = AutoDrive.getIsFilled(vehicle, trailer, vehicle.ad.isLoadingToFillUnitIndex)
            vehicleEmpty, trailerEmpty, fillUnitEmpty = AutoDrive.getIsEmpty(vehicle, trailer, vehicle.ad.isUnloadingWithFillUnit)

            infoTable["Filllevels"]["trailer_" .. trailerIndex] = {}
            infoTable["Filllevels"]["trailer_" .. trailerIndex]["fillLevel"] = trailerFillLevel
            infoTable["Filllevels"]["trailer_" .. trailerIndex]["leftCapacity"] = trailerLeftCapacity
            infoTable["Filllevels"]["trailer_" .. trailerIndex]["maxCapacity"] = trailerMaxCapacity
            infoTable["Filllevels"]["trailer_" .. trailerIndex]["filled"] = trailerFull
            infoTable["Filllevels"]["trailer_" .. trailerIndex]["empty"] = trailerEmpty
            infoTable["Filllevels"]["trailer_" .. trailerIndex]["length"] = trailer.sizeLength

            for fillUnitIndex, _ in pairs(trailer:getFillUnits()) do
                local unitFillLevel, unitLeftCapacity = AutoDrive.getFilteredFillLevelAndCapacityOfOneUnit(trailer, fillUnitIndex, nil)
                local unitMaxCapacity = unitFillLevel + unitLeftCapacity
                vehicleFull, trailerFull, fillUnitFull = AutoDrive.getIsFilled(vehicle, trailer, fillUnitIndex)
                vehicleEmpty, trailerEmpty, fillUnitEmpty = AutoDrive.getIsEmpty(vehicle, trailer, fillUnitIndex)

                infoTable["Filllevels"]["trailer_" .. trailerIndex]["fillUnit_" .. fillUnitIndex] = {}
                infoTable["Filllevels"]["trailer_" .. trailerIndex]["fillUnit_" .. fillUnitIndex]["fillLevel"] = unitFillLevel
                infoTable["Filllevels"]["trailer_" .. trailerIndex]["fillUnit_" .. fillUnitIndex]["leftCapacity"] = unitLeftCapacity
                infoTable["Filllevels"]["trailer_" .. trailerIndex]["fillUnit_" .. fillUnitIndex]["maxCapacity"] = unitMaxCapacity
                infoTable["Filllevels"]["trailer_" .. trailerIndex]["fillUnit_" .. fillUnitIndex]["filled"] = fillUnitFull
                infoTable["Filllevels"]["trailer_" .. trailerIndex]["fillUnit_" .. fillUnitIndex]["empty"] = fillUnitEmpty
            end

            trailerIndex = trailerIndex + 1
        end
    end

    return infoTable
end

function AutoDrive:handleDriverWages(vehicle, dt)
    local spec = vehicle.spec_aiVehicle
    if vehicle.isServer and spec ~= nil then
        if vehicle:getIsAIActive() and spec.startedFarmId ~= nil and spec.startedFarmId > 0 and vehicle.ad.isActive then
            local driverWages = AutoDrive.getSetting("driverWages")
            local difficultyMultiplier = g_currentMission.missionInfo.buyPriceMultiplier
            local price = -dt * difficultyMultiplier * (driverWages - 1) * spec.pricePerMS
            g_currentMission:addMoney(price, spec.startedFarmId, MoneyType.AI, true)
        end
    end
end

function AutoDrive:saveToXMLFile(xmlFile, key)
    setXMLInt(xmlFile, key .. "#mode", self.ad.mode)
    setXMLInt(xmlFile, key .. "#targetSpeed", self.ad.targetSpeed)
    setXMLInt(xmlFile, key .. "#mapMarkerSelected", self.ad.mapMarkerSelected)
    setXMLInt(xmlFile, key .. "#mapMarkerSelected_Unload", self.ad.mapMarkerSelected_Unload)
    setXMLInt(xmlFile, key .. "#unloadFillTypeIndex", self.ad.unloadFillTypeIndex)
    setXMLString(xmlFile, key .. "#driverName", self.ad.driverName)
    setXMLInt(xmlFile, key .. "#loopCounterSelected", self.ad.loopCounterSelected)
    setXMLInt(xmlFile, key .. "#parkDestination", self.ad.parkDestination)

    for settingName, setting in pairs(AutoDrive.settings) do
        if setting.isVehicleSpecific and self.ad.settings ~= nil and self.ad.settings[settingName] ~= nil then
            setXMLInt(xmlFile, key .. "#" .. settingName, self.ad.settings[settingName].current)
        end
    end

    if self.ad.groups ~= nil then
        local combinedString = ""
        for groupName, _ in pairs(AutoDrive.groups) do
            for myGroupName, value in pairs(self.ad.groups) do
                if groupName == myGroupName then
                    if string.len(combinedString) > 0 then
                        combinedString = combinedString .. ";"
                    end
                    if value == true then
                        combinedString = combinedString .. myGroupName .. ",1"
                    else
                        combinedString = combinedString .. myGroupName .. ",0"
                    end
                end
            end
        end
        setXMLString(xmlFile, key .. "#groups", combinedString)
    end
end

function AutoDrive:onDraw()
    if self.ad.moduleInitialized == false then
        return
    end

    if self.ad ~= nil then
        if self.ad.showingHud ~= AutoDrive.Hud.showHud then
            AutoDrive.Hud:toggleHud(self)
        end
    end

    if AutoDrive.getSetting("showNextPath") == true then
        local wps, currentWp = self.ad.drivePathModule:getWayPoints()
        if wps ~= nil and currentWp ~= nil and currentWp > 0 and wps[currentWp] ~= nil and wps[currentWp + 1] ~= nil then
            --draw line with direction markers (arrow)
            local sWP = wps[currentWp]
            local eWP = wps[currentWp + 1]
            DrawingManager:addLineTask(sWP.x, sWP.y, sWP.z, eWP.x, eWP.y, eWP.z, 1, 1, 1)
            DrawingManager:addArrowTask(sWP.x, sWP.y, sWP.z, eWP.x, eWP.y, eWP.z, DrawingManager.arrows.position.start, 1, 1, 1)
        end
    end

    if self == g_currentMission.controlledVehicle and (g_dedicatedServerInfo == nil) then
        AutoDrive:onDrawControlledVehicle(self)
    end

    if (self.ad.createMapPoints or self.ad.displayMapPoints) and self == g_currentMission.controlledVehicle then
        AutoDrive:onDrawCreationMode(self)
    end

    if AutoDrive.experimentalFeatures.redLinePosition and AutoDrive.getDebugChannelIsSet(AutoDrive.DC_VEHICLEINFO) and self.ad.frontNodeGizmo ~= nil then
        self.ad.frontNodeGizmo:createWithNode(self.ad.frontNode, getName(self.ad.frontNode), false)
        self.ad.frontNodeGizmo:draw()
    end
end

function AutoDrive:onDrawControlledVehicle(vehicle)
    if AutoDrive.Hud ~= nil then
        if AutoDrive.Hud.showHud == true then
            AutoDrive.Hud:drawHud(vehicle)
        end
    end
end

function AutoDrive:onDrawCreationMode(vehicle)
    local AutoDriveDM = DrawingManager

    local startNode = vehicle.ad.frontNode
    if AutoDrive.getSetting("autoConnectStart") or not AutoDrive.experimentalFeatures.redLinePosition then
        startNode = vehicle.components[1].node
    end

    local x1, y1, z1 = getWorldTranslation(startNode)
    local dy = y1 + 3.5 - AutoDrive.getSetting("lineHeight")

    AutoDrive.drawPointsInProximity(vehicle)

    --Draw close destination (names)
    local maxDistance = AutoDrive.drawDistance
    for _, marker in pairs(ADGraphManager:getMapMarker()) do
        local wp = ADGraphManager:getWayPointById(marker.id)
        if AutoDrive.getDistance(wp.x, wp.z, x1, z1) < maxDistance then
            Utils.renderTextAtWorldPosition(wp.x, wp.y + 4, wp.z, marker.name, getCorrectTextSize(0.013), 0)
            if not vehicle.ad.extendedEditorMode then
                AutoDriveDM:addMarkerTask(wp.x, wp.y + 0.45, wp.z)
            end
        end
    end

    if vehicle.ad.createMapPoints and ADGraphManager:getWayPointById(1) ~= nil then
        local g = 0

        --Draw line to selected neighbor point
        if vehicle.ad.showSelectedDebugPoint == true and vehicle.ad.iteratedDebugPoints[vehicle.ad.selectedDebugPoint] ~= nil then
            local wp = vehicle.ad.iteratedDebugPoints[vehicle.ad.selectedDebugPoint]
            AutoDriveDM:addLineTask(x1, dy, z1, wp.x, wp.y, wp.z, 1, 1, 0)
            g = 0.4
        end

        --Draw line to closest point
        if vehicle.ad.showClosestPoint then
            local closest, _ = ADGraphManager:findClosestWayPoint(vehicle)
            local wp = ADGraphManager:getWayPointById(closest)
            AutoDriveDM:addLineTask(x1, dy, z1, wp.x, wp.y, wp.z, 1, 0, 0)
            AutoDriveDM:addSmallSphereTask(x1, dy, z1, 1, g, 0)
        end
    end
end

function AutoDrive.getNewPointsInProximity(vehicle)
    local x1, _, z1 = getWorldTranslation(vehicle.components[1].node)
    local maxDistance = AutoDrive.drawDistance

    if ADGraphManager:getWayPointById(1) ~= nil then
        local newPointsToDraw = {}
        local pointsCheckedThisFrame = 0
        --only handly a limited amount of points per frame
        while pointsCheckedThisFrame < 1000 and pointsCheckedThisFrame < ADGraphManager:getWayPointCount() do
            pointsCheckedThisFrame = pointsCheckedThisFrame + 1
            vehicle.ad.lastPointCheckedForProximity = vehicle.ad.lastPointCheckedForProximity + 1
            if vehicle.ad.lastPointCheckedForProximity > ADGraphManager:getWayPointCount() then
                vehicle.ad.lastPointCheckedForProximity = 1
            end
            local pointToCheck = ADGraphManager:getWayPointById(vehicle.ad.lastPointCheckedForProximity)
            if pointToCheck ~= nil then
                if AutoDrive.getDistance(pointToCheck.x, pointToCheck.z, x1, z1) < maxDistance then
                    table.insert(newPointsToDraw, pointToCheck.id, pointToCheck)
                end
            end
        end
        --go through all stored points to check if they are still in proximity
        for id, point in pairs(vehicle.ad.pointsInProximity) do
            if AutoDrive.getDistance(point.x, point.z, x1, z1) < maxDistance and newPointsToDraw[id] == nil and ADGraphManager:getWayPointById(id) ~= nil then
                table.insert(newPointsToDraw, id, point)
            end
        end
        --replace stored list with update
        vehicle.ad.pointsInProximity = newPointsToDraw
    end
end

function AutoDrive.mouseIsAtPos(position, radius)
    local x, y, _ = project(position.x, position.y + AutoDrive.drawHeight + AutoDrive.getSetting("lineHeight"), position.z)

    if g_lastMousePosX < (x + radius) and g_lastMousePosX > (x - radius) then
        if g_lastMousePosY < (y + radius) and g_lastMousePosY > (y - radius) then
            return true
        end
    end

    return false
end

function AutoDrive.drawPointsInProximity(vehicle)
    local AutoDriveDM = DrawingManager
    local arrowPosition = AutoDriveDM.arrows.position.start
    AutoDrive.getNewPointsInProximity(vehicle)

    for _, point in pairs(vehicle.ad.pointsInProximity) do
        local x = point.x
        local y = point.y
        local z = point.z
        if vehicle.ad.extendedEditorMode then
            arrowPosition = AutoDriveDM.arrows.position.middle
            if AutoDrive.mouseIsAtPos(point, 0.01) then
                AutoDriveDM:addSphereTask(x, y, z, 3, 0, 0, 1, 0.3)
            else
                if point.id == vehicle.ad.selectedNodeId then
                    AutoDriveDM:addSphereTask(x, y, z, 3, 0, 1, 0, 0.3)
                else
                    AutoDriveDM:addSphereTask(x, y, z, 3, 1, 0, 0, 0.3)
                end
            end

            -- If the lines are drawn above the vehicle, we have to draw a line to the reference point on the ground and a second cube there for moving the node position
            if AutoDrive.getSettingState("lineHeight") > 1 then
                local gy = y - AutoDrive.drawHeight - AutoDrive.getSetting("lineHeight")
                AutoDriveDM:addLineTask(x, y, z, x, gy, z, 1, 1, 1)

                if AutoDrive.mouseIsAtPos(point, 0.01) or AutoDrive.mouseIsAtPos({x = x, y = gy, z = z}, 0.01) then
                    AutoDriveDM:addSphereTask(x, gy, z, 3, 0, 0, 1, 0.15)
                else
                    if point.id == vehicle.ad.selectedNodeId then
                        AutoDriveDM:addSphereTask(x, gy, z, 3, 0, 1, 0, 0.15)
                    else
                        AutoDriveDM:addSphereTask(x, gy, z, 3, 1, 0, 0, 0.15)
                    end
                end
            end
        end

        if point.out ~= nil then
            for _, neighbor in pairs(point.out) do
                local target = ADGraphManager:getWayPointById(neighbor)
                if target ~= nil then
                    --check if outgoing connection is a dual way connection
                    local nWp = ADGraphManager:getWayPointById(neighbor)
                    if table.contains(point.incoming, neighbor) then
                        --draw simple line
                        AutoDriveDM:addLineTask(x, y, z, nWp.x, nWp.y, nWp.z, 0, 0, 1)
                    else
                        --draw line with direction markers (arrow)
                        AutoDriveDM:addLineTask(x, y, z, nWp.x, nWp.y, nWp.z, 0, 1, 0)
                        AutoDriveDM:addArrowTask(x, y, z, nWp.x, nWp.y, nWp.z, arrowPosition, 0, 1, 0)
                    end
                end
            end
        end

        if not vehicle.ad.extendedEditorMode then
            --just a quick way to highlight single (forgotten) points with no connections
            if (#point.out == 0) and (#point.incoming == 0) then
                AutoDriveDM:addSphereTask(x, y, z, 1.5, 1, 0, 0, 0.1)
            end
        end
    end
end

function AutoDrive:preRemoveVehicle(vehicle)
    if vehicle.ad ~= nil and vehicle.ad.isActive then
        AutoDrive:disableAutoDriveFunctions(vehicle)
    end
end
FSBaseMission.removeVehicle = Utils.prependedFunction(FSBaseMission.removeVehicle, AutoDrive.preRemoveVehicle)

function AutoDrive:onDelete()
    AutoDriveHud:deleteMapHotspot(self)
end

function AutoDrive:updateAILights(superFunc)
    if self.ad ~= nil and self.ad.isActive then
        -- If AutoDrive is active, then we take care of lights our self
        local spec = self.spec_lights
        local dayMinutes = g_currentMission.environment.dayTime / (1000 * 60)
        local needLights = (dayMinutes > g_currentMission.environment.nightStartMinutes or dayMinutes < g_currentMission.environment.nightEndMinutes)
        if needLights then
            if spec.lightsTypesMask ~= spec.aiLightsTypesMask and AutoDrive:checkIsOnField(self) then
                self:setLightsTypesMask(spec.aiLightsTypesMask)
            end
            if spec.lightsTypesMask ~= 1 and not AutoDrive:checkIsOnField(self) then
                self:setLightsTypesMask(1)
            end
        else
            if spec.lightsTypesMask ~= 0 then
                self:setLightsTypesMask(0)
            end
        end
        return
    else
        superFunc(self)
    end
end

function AutoDrive:getCanMotorRun(superFunc)
    if self.ad ~= nil and self.ad.isActive and self.ad.specialDrivingModule:shouldStopMotor() then
        return false
    else
        return superFunc(self)
    end
end

AIVehicleUtil.driveInDirection = function(self, dt, steeringAngleLimit, acceleration, slowAcceleration, slowAngleLimit, allowedToDrive, moveForwards, lx, lz, maxSpeed, slowDownFactor)
    if self.getMotorStartTime ~= nil then
        allowedToDrive = allowedToDrive and (self:getMotorStartTime() <= g_currentMission.time)
    end

    if self.ad ~= nil and AutoDrive.experimentalFeatures.smootherDriving then
        if self.ad.isActive and allowedToDrive then
            --slowAngleLimit = 90 -- Set it to high value since we don't need the slow down

            local accFactor = 2 / 1000 -- km h / s converted to km h / ms
            accFactor = accFactor + math.abs((maxSpeed - self.lastSpeedReal * 3600) / 2000) -- Changing accFactor based on missing speed to reach target (useful for sudden braking)
            if self.ad.smootherDriving.lastMaxSpeed < maxSpeed then
                self.ad.smootherDriving.lastMaxSpeed = math.min(self.ad.smootherDriving.lastMaxSpeed + accFactor / 2 * dt, maxSpeed)
            else
                self.ad.smootherDriving.lastMaxSpeed = math.max(self.ad.smootherDriving.lastMaxSpeed - accFactor * dt, maxSpeed)
            end

            if maxSpeed < 1 then
                -- Hard braking, is needed to prevent combine's pipe overstep and crash
                self.ad.smootherDriving.lastMaxSpeed = maxSpeed
            end
            --AutoDrive.renderTable(0.1, 0.9, 0.012, {maxSpeed = maxSpeed, lastMaxSpeed = self.ad.smootherDriving.lastMaxSpeed})
            maxSpeed = self.ad.smootherDriving.lastMaxSpeed
        else
            self.ad.smootherDriving.lastMaxSpeed = 0
        end
    end

    local angle = 0
    if lx ~= nil and lz ~= nil then
        local dot = lz
        angle = math.deg(math.acos(dot))
        if angle < 0 then
            angle = angle + 180
        end
        local turnLeft = lx > 0.00001
        if not moveForwards then
            turnLeft = not turnLeft
        end
        local targetRotTime = 0
        if turnLeft then
            --rotate to the left
            targetRotTime = self.maxRotTime * math.min(angle / steeringAngleLimit, 1)
        else
            --rotate to the right
            targetRotTime = self.minRotTime * math.min(angle / steeringAngleLimit, 1)
        end
        if targetRotTime > self.rotatedTime then
            self.rotatedTime = math.min(self.rotatedTime + dt * self:getAISteeringSpeed(), targetRotTime)
        else
            self.rotatedTime = math.max(self.rotatedTime - dt * self:getAISteeringSpeed(), targetRotTime)
        end
    end
    if self.firstTimeRun then
        local acc = acceleration
        if maxSpeed ~= nil and maxSpeed ~= 0 then
            if math.abs(angle) >= slowAngleLimit then
                maxSpeed = maxSpeed * slowDownFactor
            end
            self.spec_motorized.motor:setSpeedLimit(maxSpeed)
            if self.spec_drivable.cruiseControl.state ~= Drivable.CRUISECONTROL_STATE_ACTIVE then
                self:setCruiseControlState(Drivable.CRUISECONTROL_STATE_ACTIVE)
            end
        else
            if math.abs(angle) >= slowAngleLimit then
                acc = slowAcceleration
            end
        end
        if not allowedToDrive then
            acc = 0
        end
        if not moveForwards then
            acc = -acc
        end
        --FS 17 Version WheelsUtil.updateWheelsPhysics(self, dt, self.lastSpeedReal, acc, not allowedToDrive, self.requiredDriveMode);
        WheelsUtil.updateWheelsPhysics(self, dt, self.lastSpeedReal * self.movingDirection, acc, not allowedToDrive, true)
    end
end

function AIVehicle:onUpdateTick(dt, isActiveForInput, isActiveForInputIgnoreSelection, isSelected)
    local spec = self.spec_aiVehicle

    if self.isClient then
        local actionEvent = spec.actionEvents[InputAction.TOGGLE_AI]
        if actionEvent ~= nil then
            local showAction = false

            if self:getIsActiveForInput(true, true) then
                -- If ai is active we always display the dismiss helper action
                -- But only if the AutoDrive is not active :)
                showAction = self:getCanStartAIVehicle() or (self:getIsAIActive() and (self.ad == nil or not self.ad.isActive))

                if showAction then
                    if self:getIsAIActive() then
                        g_inputBinding:setActionEventText(actionEvent.actionEventId, g_i18n:getText("action_dismissEmployee"))
                    else
                        g_inputBinding:setActionEventText(actionEvent.actionEventId, g_i18n:getText("action_hireEmployee"))
                    end
                end
            end

            g_inputBinding:setActionEventActive(actionEvent.actionEventId, showAction)
        end
    end
end
