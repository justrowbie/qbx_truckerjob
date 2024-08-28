local config = require 'config.client'
local sharedConfig = require 'config.shared'
local DropOffZone, activeTrailer, pickupZone, PICKUP_BLIP, DELIVERY_BLIP
local activeRoute = {}
local droppingOff = false
local delay = false
local truckingPedZone, truckerPed = nil, nil

local TruckerWork = AddBlipForCoord(config.BossCoords.x, config.BossCoords.y, config.BossCoords.z)
SetBlipSprite(TruckerWork, 477)
SetBlipDisplay(TruckerWork, 4)
SetBlipScale(TruckerWork, 0.7)
SetBlipAsShortRange(TruckerWork, true)
SetBlipColour(TruckerWork, 5)
BeginTextCommandSetBlipName('STRING')
AddTextComponentSubstringPlayerName(locale('zone.job_label'))
EndTextCommandSetBlipName(TruckerWork)

local function targetLocalEntity(entity, options, distance)
    if config.UsingTarget then
        for _, option in ipairs(options) do
            option.distance = distance
            option.onSelect = option.action
            option.action = nil
        end
        exports.ox_target:addLocalEntity(entity, options)
    else
        exports.interact:AddLocalEntityInteraction({
            entity = entity,
            name = 'qbx_truckerjob_ped',
            id = 'qbx_truckerjob_ped',
            distance = distance,
            interactDst = distance - 1.0,
            options = options
        })
    end
end

local function cleanupShit()
    if DropOffZone then DropOffZone:remove() DropOffZone = nil end
    if pickupZone then pickupZone:remove() pickupZone = nil end
    if DoesBlipExist(PICKUP_BLIP) then RemoveBlip(PICKUP_BLIP) end
    if DoesBlipExist(DELIVERY_BLIP) then RemoveBlip(DELIVERY_BLIP) end

    activeTrailer, PICKUP_BLIP, DELIVERY_BLIP = nil
    table.wipe(activeRoute)
    delay = false
    droppingOff = false
end

local function getStreetandZone(coords)
    local currentStreetHash = GetStreetNameAtCoord(coords.x, coords.y, coords.z)
    local currentStreetName = GetStreetNameFromHashKey(currentStreetHash)
    return currentStreetName
end

local function createRouteBlip(coords, label)
    local blip = AddBlipForCoord(coords.x, coords.y, coords.z)
    SetBlipSprite(blip, 479)
    SetBlipDisplay(blip, 4)
    SetBlipScale(blip, 0.7)
    SetBlipAsShortRange(blip, true)
    SetBlipColour(blip, 5)
    SetBlipRoute(blip, true)
    SetBlipRouteColour(blip, 5)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName(label)
    EndTextCommandSetBlipName(blip)
    return blip
end

local function viewRoutes()
    local context = {}

    local routes = lib.callback.await('qbx_truckerjob:server:getRoutes', false)
    if not next(routes) then
        return exports.qbx_core:Notify(locale('error.no_route'), 'error', 5000)
    end

    for index, data in pairs(routes) do
        local isDisabled = activeRoute.index == index
        local info = (locale('info.route_info')):format(getStreetandZone(data.deliver.xyz), data.payment)
        context[#context + 1] = {
            title = getStreetandZone(data.pickup.xyz),
            description = info,
            icon = 'fa-solid fa-location-dot',
            disabled = isDisabled,
            onSelect = function()
                local choice = lib.callback.await('qbx_truckerjob:server:chooseRoute', false, index)
                if choice and type(choice) == 'table' then
                    activeRoute = choice
                    activeRoute.index = index
                    SetRoute()
                end
            end,
        }
    end

    lib.registerContext({ id = 'view_work_routes', title = locale('target.work_routes'), options = context })
    lib.showContext('view_work_routes')
end

local function nearZone(point)
    if point.isClosest and point.currentDistance <= 4 then
        if not showText then
            showText = true
            lib.showTextUI(locale('info.drop_trailer'))
        end
        if next(activeRoute) and cache.vehicle and IsEntityAttachedToEntity(cache.vehicle, activeTrailer) then
            if IsControlJustPressed(0, 38) and not droppingOff then
                droppingOff = true
                FreezeEntityPosition(cache.vehicle, true)
                lib.hideTextUI()
                if lib.progressCircle({
                    duration = 5000,
                    position = 'bottom',
                    label = locale('progress.drop_trailer'),
                    useWhileDead = false,
                    canCancel = false,
                    disable = { move = true, car = true, mouse = false, combat = true, },
                }) then
                    DetachEntity(activeTrailer, true, true)
                    NetworkFadeOutEntity(activeTrailer, 0, 1)
                    Wait(500)
                    lib.callback.await('qbx_truckerjob:server:updateRoute', false, NetworkGetNetworkIdFromEntity(activeTrailer), activeRoute)
                    FreezeEntityPosition(cache.vehicle, false)
                    cleanupShit()
                end
            end
        end
    elseif showText then
        showText = false
        lib.hideTextUI()
    end
end

local function createDropoff()
    RemoveBlip(PICKUP_BLIP)
    pickupZone:remove()
    DropOffZone = lib.points.new({ coords = vec3(activeRoute.deliver.x, activeRoute.deliver.y, activeRoute.deliver.z), distance = 40, nearby = nearZone })
    DELIVERY_BLIP = createRouteBlip(activeRoute.deliver.xyz, locale('zone.delivery_zone'))
    SetNewWaypoint(activeRoute.deliver.x, activeRoute.deliver.y)
    exports.qbx_core:Notify(locale('success.route_marked'), 'success', 7500)
    Wait(1000)
    delay = false
end

function SetRoute()
    PICKUP_BLIP = createRouteBlip(activeRoute.pickup.xyz, locale('zone.truck_zone'))
    exports.qbx_core:Notify(locale('success.go_to_container'), 'success', 7500)
    pickupZone = lib.points.new({ 
        coords = vec3(activeRoute.pickup.x, activeRoute.pickup.y, activeRoute.pickup.z), 
        distance = 70, 
        onEnter = function()
            if not activeTrailer then
                local success, netid = lib.callback.await('qbx_truckerjob:server:spawnTrailer', false)
                if success and netid then
                    activeTrailer = lib.waitFor(function()
                        if NetworkDoesEntityExistWithNetworkId(netid) then
                            return NetToVeh(netid)
                        end
                    end, 'Could not load entity in time.', 3000)
                end
            end
        end,
        nearby = function()
            if cache.vehicle and IsEntityAttachedToEntity(cache.vehicle, activeTrailer) and not delay then
                delay = true
                createDropoff()
            end
        end,
    })
end

local function removePedSpawned()
    if config.UsingTarget then
        exports.ox_target:removeLocalEntity(truckerPed, {'Clock In', 'Clock Out', 'View Routes', 'Pull Out Vehicle', 'Abort Route'})
    else
        exports.interact:RemoveLocalEntityInteraction(truckerPed, 'qbx_truckerjob_ped')
    end
    DeleteEntity(truckerPed)
    truckerPed = nil
end

local function spawnPed()
    if DoesEntityExist(truckerPed) then return end
    local model = joaat(config.BossModel)
    lib.requestModel(model)
    truckerPed = CreatePed(3, model, config.BossCoords.x, config.BossCoords.y, config.BossCoords.z - 1, config.BossCoords.w, false, false)
    SetEntityAsMissionEntity(truckerPed, true, true)
    SetPedFleeAttributes(truckerPed, 0, 0)
    SetBlockingOfNonTemporaryEvents(truckerPed, true)
    SetEntityInvincible(truckerPed, true)
    FreezeEntityPosition(truckerPed, true)
    SetModelAsNoLongerNeeded(model)
    targetLocalEntity(truckerPed, {
        { 
            num = 1,
            icon = 'fa-solid fa-clipboard-check',
            label = locale('target.start_job'),
            canInteract = function()
                return not LocalPlayer.state.truckDuty
            end,
            action = function()
                lib.callback.await('qbx_truckerjob:server:clockIn', false)
            end,
        },
        { 
            num = 2,
            icon = 'fa-solid fa-clipboard-check',
            label = locale('target.stop_job'),
            canInteract = function() return LocalPlayer.state.truckDuty end,
            action = function()
                local returnRent = lib.callback.await('qbx_truckerjob:server:returnrentvehicle', false)
                if returnRent then
                    lib.callback.await('qbx_truckerjob:server:clockOut', false)
                end
            end,
        },
        {
            num = 3,
            icon = 'fa-solid fa-clipboard-check',
            label = locale('target.view_routes'),
            canInteract = function() return LocalPlayer.state.truckDuty end,
            action = function()
                viewRoutes()
            end,
        },
        {
            num = 4,
            icon = 'fa-solid fa-truck',
            label = locale('target.take_vehicle'),
            canInteract = function() return LocalPlayer.state.truckDuty end,
            action = function()
                if IsAnyVehicleNearPoint(sharedConfig.VehicleSpawn.x, sharedConfig.VehicleSpawn.y, sharedConfig.VehicleSpawn.z, 15.0) then 
                    return exports.qbx_core:Notify(locale('error.vehicle_block'), 'error', 5000) 
                end
                local hasMoney = lib.callback.await('qbx_truckerjob:server:rentvehicle', false)
                if hasMoney then
                    local success, coords = lib.callback.await('qbx_truckerjob:server:spawnTruck', false)
                    if not success and coords then
                        SetNewWaypoint(coords.x, coords.y)
                        exports.qbx_core:Notify(locale('error.vehicle_out'), 'error', 5000)
                    end
                end
            end,
        },
        {
            num = 5,
            icon = 'fa-solid fa-xmark',
            label = locale('target.abort_route'),
            canInteract = function() return LocalPlayer.state.truckDuty and next(activeRoute) end,
            action = function()
                local success = lib.callback.await('qbx_truckerjob:server:abortRoute', false, activeRoute.index)
                if success then
                    exports.qbx_core:Notify(locale('success.abort_route'), 'success', 5000)
                end
            end,
        },
    }, 3.0)
end

local function createTruckingStart()
    truckingPedZone = lib.points.new({
        coords = config.BossCoords.xyz,
        distance = 60,
        onEnter = spawnPed,
        onExit = removePedSpawned,
    })
end

RegisterNetEvent('qbx_truckerjob:client:clearRoutes', function()
    if GetInvokingResource() then return end
    cleanupShit()
end)

RegisterNetEvent('qbx_truckerjob:server:spawnTruck', function(netid)
    if GetInvokingResource() or not netid then return end
    local veh = lib.waitFor(function()
        if NetworkDoesEntityExistWithNetworkId(netid) then
            return NetToVeh(netid)
        end
    end, 'Could not load entity in time.', 3000)
    
    local plate = GetVehicleNumberPlateText(veh)
    TriggerServerEvent('qb-vehiclekeys:server:AcquireVehicleKeys', plate)

    if config.Fuel.enable then
        exports[config.Fuel.script]:SetFuel(veh, 100.0)
    else
        Entity(veh).state.fuel = 100
    end
end)

RegisterNetEvent('QBCore:Client:OnPlayerLoaded', function()
    createTruckingStart()
end)

RegisterNetEvent('QBCore:Client:OnPlayerUnload', function()
    if truckingPedZone then truckingPedZone:remove() truckingPedZone = nil end
    removePedSpawned()
    cleanupShit()
end)


AddEventHandler('onResourceStop', function(resourceName) 
    if GetCurrentResourceName() == resourceName and LocalPlayer.state.isLoggedIn then
        if truckingPedZone then truckingPedZone:remove() truckingPedZone = nil end
        removePedSpawned()
        cleanupShit()
    end 
end)

AddEventHandler('onResourceStart', function(resource)
    if GetCurrentResourceName() == resource and LocalPlayer.state.isLoggedIn then
        createTruckingStart()
    end
end)