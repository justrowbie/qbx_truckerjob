local config = require 'config.server'
local sharedConfig = require 'config.shared'
local storedRoutes = {}
local queue = {}
local spawnedTrailers = {}
local handlingPayments = {}

local function GetPlayer(id)
    return exports.qbx_core:GetPlayer(id)
end

local function GetPlyIdentifier(Player)
    return Player.PlayerData.citizenid
end

local function GetSourceFromIdentifier(cid)
    local Player = exports.qbx_core:GetPlayerByCitizenId(cid)
    return Player and Player.PlayerData.source or false
end

local function GetCharacterName(Player)
    return Player.PlayerData.charinfo.firstname.. ' ' ..Player.PlayerData.charinfo.lastname
end

local function AddItem(Player, item, amount)
    exports.ox_inventory:AddItem(Player.PlayerData.source, item, amount)
end

local function RemoveItem(Player, item, amount)
    exports.ox_inventory:RemoveItem(Player.PlayerData.source, item, amount)
end

local function AddMoney(Player, moneyType, amount)
    Player.Functions.AddMoney(moneyType, amount)
end

local function removeFromQueue(cid)
    for i, cids in ipairs(queue) do
        if cids == cid then
            table.remove(queue, i)
            break
        end
    end
end

local function createTruckingVehicle(source, model, warp, coords)
    if not coords then coords = sharedConfig.VehicleSpawn end

    -- CreateVehicleServerSetter can be funky and I cba, especially for a temp vehicle. Cry about it. I just need the entity handle.
    local vehicle = CreateVehicle(joaat(model), coords.x, coords.y, coords.z, coords.w, true, true)
    local ped = GetPlayerPed(source)

    while not DoesEntityExist(vehicle) do Wait(0) end 

    if warp then
        while GetVehiclePedIsIn(ped, false) ~= vehicle do
            TaskWarpPedIntoVehicle(ped, vehicle, -1)
            Wait(100)
        end
    end

    return vehicle
end

local function resetEverything()
    local players = GetPlayers()
    if #players > 0 then
        for i = 1, #players do
            local src = tonumber(players[i])
            local player = GetPlayer(src)

            if player then
                if Player(src).state.truckDuty then
                    Player(src).state:set('truckDuty', false, true)
                end
                local cid = GetPlyIdentifier(player)
                if storedRoutes[cid] and storedRoutes[cid].vehicle and DoesEntityExist(storedRoutes[cid].vehicle) then
                    DeleteEntity(storedRoutes[cid].vehicle)
                end
            end

            if spawnedTrailers[src] and DoesEntityExist(spawnedTrailers[src]) then
                DeleteEntity(spawnedTrailers[src])
            end
        end
    end
end

local function generateRoute(cid)
    local data = {}
    data.pickup = config.Pickups[math.random(#config.Pickups)] 
    repeat
        data.deliver = config.Deliveries[math.random(#config.Deliveries)]

        local found = false
        for _, route in ipairs(storedRoutes[cid].routes) do
            if route.deliver == data.deliver then
                found = true
                break
            end
        end

        if not found then break end
    until false

    data.payment = math.ceil(#(data.deliver.xyz - data.pickup.xyz) * config.PaymentMultiplier)



    return data
end

lib.callback.register('qbx_truckerjob:server:clockIn', function(source)
    local src = source
    local player = GetPlayer(src)
    local cid = GetPlyIdentifier(player)

    if storedRoutes[cid] then
        exports.qbx_core:Notify(src, locale('error.already_request'), 'error', 7500)
        return false
    end

    queue[#queue+1] = cid
    storedRoutes[cid] = { routes = {}, vehicle = 0, }
    Player(src).state:set('truckDuty', true, true)

    exports.qbx_core:Notify(src, locale('success.check_routes'), 'success', 7000)
    return true
end)

lib.callback.register('qbx_truckerjob:server:clockOut', function(source) 
    local src = source
    local player = GetPlayer(src)
    local cid = GetPlyIdentifier(player)

    if not storedRoutes[cid] or not Player(src).state.truckDuty then
        exports.qbx_core:Notify(src, locale('error.not_request'), 'error', 7500)
        return false
    end

    local workTruck = storedRoutes[cid].vehicle
    local workTrailer = spawnedTrailers[src]

    if workTruck and DoesEntityExist(workTruck) then DeleteEntity(workTruck) end
    if workTrailer and DoesEntityExist(workTrailer) then DeleteEntity(workTrailer) end

    removeFromQueue(cid)
    storedRoutes[cid] = nil
    Player(src).state:set('truckDuty', false, true)
    TriggerClientEvent('qbx_truckerjob:client:clearRoutes', src)
    exports.qbx_core:Notify(src, locale('success.clear_routes'), 'success', 7500)
    return true
end)

lib.callback.register('qbx_truckerjob:server:spawnTruck', function(source) 
    local src = source
    local player = GetPlayer(src)
    local cid = GetPlyIdentifier(player)

    if not storedRoutes[cid] or not Player(src).state.truckDuty then
        exports.qbx_core:Notify(src, locale('error.not_request'), 'error', 7500)
        return false
    end

    local workTruck = storedRoutes[cid].vehicle

    if DoesEntityExist(workTruck) then
        local coords = GetEntityCoords(workTruck)
        return false, coords, NetworkGetNetworkIdFromEntity(workTruck)
    end

    local model = config.Trucks[math.random(#config.Trucks)]
    local vehicle = createTruckingVehicle(src, model, true)

    storedRoutes[cid].vehicle = vehicle
    exports.qbx_core:Notify(src, locale('success.pull_out_truck'), 'success', 7500)
    TriggerClientEvent('qbx_truckerjob:server:spawnTruck', src, NetworkGetNetworkIdFromEntity(vehicle))
    return true
end)

lib.callback.register('qbx_truckerjob:server:spawnTrailer', function(source) 
    local src = source
    local player = GetPlayer(src)
    local cid = GetPlyIdentifier(player)

    if not storedRoutes[cid] or not Player(src).state.truckDuty then return false end

    local model = config.Trailers[math.random(#config.Trailers)]
    local coords = storedRoutes[cid].currentRoute.pickup
    local trailer = createTruckingVehicle(src, model, false, coords)

    spawnedTrailers[src] = trailer
    return true, NetworkGetNetworkIdFromEntity(trailer)
end)

lib.callback.register('qbx_truckerjob:server:chooseRoute', function(source, index) 
    local src = source
    local player = GetPlayer(src)
    local cid = GetPlyIdentifier(player)

    if not storedRoutes[cid] or not Player(src).state.truckDuty then return false end

    if spawnedTrailers[src] or storedRoutes[cid].currentRoute then
        exports.qbx_core:Notify(src, locale('success.active_routes'), 'success')
        return false 
    end

    storedRoutes[cid].currentRoute = storedRoutes[cid].routes[index]
    storedRoutes[cid].currentRoute.index = index

    return storedRoutes[cid].currentRoute
end)

lib.callback.register('qbx_truckerjob:server:getRoutes', function(source) 
    local src = source
    local player = GetPlayer(src)
    local cid = GetPlyIdentifier(player)

    if not storedRoutes[cid] or not Player(src).state.truckDuty then return false end

    return storedRoutes[cid].routes
end)

lib.callback.register('qbx_truckerjob:server:updateRoute', function(source, netid, route)
    if handlingPayments[source] then return false end
    handlingPayments[source] = true
    local src = source
    local player = GetPlayer(src)
    local cid = GetPlyIdentifier(player)
    local pos = GetEntityCoords(GetPlayerPed(src))
    local entity = NetworkGetEntityFromNetworkId(netid)
    local coords = GetEntityCoords(entity)
    local data = storedRoutes[cid]

    if not data or not DoesEntityExist(entity) or #(coords - data.currentRoute.deliver.xyz) > 15.0 or #(pos - data.currentRoute.deliver.xyz) > 15.0 then
        handlingPayments[src] = nil
        return false 
    end
    
    if spawnedTrailers[src] == entity and route.index == data.currentRoute.index then
        local payout = data.currentRoute.payment
        DeleteEntity(entity)
        spawnedTrailers[src] = nil
        data.currentRoute = nil
        table.remove(data.routes, route.index)
        AddMoney(player, 'cash', payout)
        exports.qbx_core:Notify(src, (locale('success.finish_route')):format(payout), 'success', 7000)
        SetTimeout(2000, function()
            handlingPayments[src] = nil
        end)
    end
end)

lib.callback.register('qbx_truckerjob:server:abortRoute', function(source, index)
    local src = source
    local player = GetPlayer(src)
    local cid = GetPlyIdentifier(player)

    if not storedRoutes[cid] or not Player(src).state.truckDuty then return false end

    local data = storedRoutes[cid]

    if data.currentRoute and data.currentRoute.index == index then
        if spawnedTrailers[src] and DoesEntityExist(spawnedTrailers[src]) then
            DeleteEntity(spawnedTrailers[src])
            spawnedTrailers[src] = nil
        end
        data.currentRoute = nil
        table.remove(data.routes, index)
        TriggerClientEvent('qbx_truckerjob:client:clearRoutes', src)
        return true
    end

    return false
end)

lib.callback.register('qbx_truckerjob:server:rentvehicle', function(source)
    local src = source
    local player = GetPlayer(src)
    if not player then return end
    local money = player.PlayerData.money
    if money.cash < config.RentPrice then
        if money.bank < config.RentPrice then
            exports.qbx_core:Notify(src, locale('error.no_deposit', config.RentPrice), 'error')
            return false
        end
        player.Functions.RemoveMoney('bank', config.RentPrice, 'Rental Vehicle')
        exports.qbx_core:Notify(src, locale('success.paid_with_bank', config.RentPrice), 'success')
        return true
    else
        player.Functions.RemoveMoney('cash', config.RentPrice, 'Rental Vehicle')
        exports.qbx_core:Notify(src, locale('success.paid_with_cash', config.RentPrice), 'success')
        return true
    end
end)

lib.callback.register('qbx_truckerjob:server:returnrentvehicle', function()
    local src = source
    local player = GetPlayer(src)
    if not player then return end
    player.Functions.RemoveMoney('cash', config.RentPrice * (config.ReturnRentPercentage/100), 'Rental Vehicle')
    exports.qbx_core:Notify(src, locale('success.refund_to_cash', math.abs(config.RentPrice * (config.ReturnRentPercentage/100))), 'success')
    return true
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    resetEverything()
end)

AddEventHandler('playerDropped', function()
    local src = source
    if Player(src).state.truckDuty then
        Player(src).state:set('truckDuty', false, true)
        if spawnedTrailers[src] and DoesEntityExist(spawnedTrailers[src]) then
            DeleteEntity(spawnedTrailers[src])
        end
    end
end)

RegisterNetEvent('QBCore:Server:OnPlayerUnload', function(source)
    local src = source
    if Player(src).state.truckDuty then
        Player(src).state:set('truckDuty', false, true)
        if spawnedTrailers[src] and DoesEntityExist(spawnedTrailers[src]) then
            DeleteEntity(spawnedTrailers[src])
        end
    end
end)

RegisterNetEvent('QBCore:Server:OnPlayerLoaded', function()
    local src = source
    local player = GetPlayer(src)
    local cid = GetPlyIdentifier(player)
    
    if storedRoutes[cid] then
        Player(src).state:set('truckDuty', true, true)
    end
end)

local function initQueue()
    if #queue == 0 then return end

    for i = 1, #queue do
        local cid = queue[i]
        local src = GetSourceFromIdentifier(cid)
        local player = GetPlayer(src)
        if player and Player(src).state.truckDuty then
            if #storedRoutes[cid].routes < 5 then
                storedRoutes[cid].routes[#storedRoutes[cid].routes + 1] = generateRoute(cid)
                exports.qbx_core:Notify(src, locale('success.new_route'), 'success', 7500)
            end
        end
    end
end

SetInterval(initQueue, config.QueueTimer * 60000)