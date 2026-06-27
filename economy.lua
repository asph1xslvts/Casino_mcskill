-- ===================================================================
-- economy.lua - экономика казино через ME-сеть (IC2 монета "каз")
-- Точная автоматическая выдача через ME Interface + Database.
--
-- Внесение: игрок кидает "каз" в вакуумный сундук -> import в сеть ->
--           код видит прирост количества -> зачисляет на баланс.
-- Выдача:   setInterfaceConfiguration держит ровно N монет в слоте
--           интерфейса, сеть наталкивает их, интерфейс сам выталкивает
--           в сундук. Точно и автоматически.
-- ===================================================================

local component = require("component")
local computer  = require("computer")

local economy = {}

-- ===================== КОНФИГ =====================

local COIN_NAME  = "IC2:itemCoin"  -- технический id монеты
local COIN_LABEL = "каз"           -- отображаемое имя нашей монеты
local IFACE_SLOT = 1               -- слот конфигурации интерфейса для выдачи
local DB_SLOT    = 1               -- слот в database, где лежит образец монеты

-- Сколько ждать (сек), пока интерфейс вытолкнет монеты после запроса
local WITHDRAW_TIMEOUT = 10
local WITHDRAW_POLL    = 0.25

-- ===================== СОСТОЯНИЕ =====================

local meController = nil
local meInterface  = nil
local database     = nil

local balance      = 0
local totalWagered = 0
local totalWon     = 0
local knownCoins   = 0
local busy         = false
local dbReady      = false   -- образец монеты сохранён в database

-- ===================== ЧТЕНИЕ СЕТИ =====================

local function countCoinsInNetwork()
    if not meController then return 0 end
    local ok, items = pcall(meController.getItemsInNetwork, {name = COIN_NAME})
    if not ok or type(items) ~= "table" then return 0 end
    for _, it in ipairs(items) do
        if it.label == COIN_LABEL then
            return it.size or 0
        end
    end
    return 0
end

-- ===================== СОХРАНЕНИЕ ОБРАЗЦА МОНЕТЫ В DATABASE =====================
-- store фильтрует по name и сохраняет в базу. Среди itemCoin может оказаться
-- обычный кредит, поэтому после сохранения проверяем label через database.get
-- и, если не "каз", пробуем сохранить с более точным подбором.

local function prepareCoinSample()
    if not (meInterface and database) then return false end

    -- сначала пробуем сохранить по фильтру name+label (вдруг store учитывает label)
    local ok = pcall(meInterface.store, {name = COIN_NAME, label = COIN_LABEL}, database.address, DB_SLOT, 1)

    -- проверяем, что в базе именно "каз"
    local got = nil
    pcall(function() got = database.get(DB_SLOT) end)
    if got and got.label == COIN_LABEL then
        return true
    end

    -- если не та монета - пробуем просто по name (на случай если фильтр по label не сработал)
    pcall(database.clear, DB_SLOT)
    pcall(meInterface.store, {name = COIN_NAME}, database.address, DB_SLOT, 1)
    pcall(function() got = database.get(DB_SLOT) end)
    if got and got.label == COIN_LABEL then
        return true
    end
    -- если в базе кредит, а не каз - всё равно вернём true только при совпадении label
    return got ~= nil and got.label == COIN_LABEL
end

-- ===================== ИНИЦИАЛИЗАЦИЯ =====================

function economy.setup()
    meController = component.isAvailable("me_controller") and component.me_controller or nil
    meInterface  = component.isAvailable("me_interface")  and component.me_interface  or nil
    database     = component.isAvailable("database")      and component.database      or nil

    if not meController then return false, "ME Controller не найден" end
    if not meInterface  then return false, "ME Interface не найден" end
    -- database больше не обязательна: выдача идёт через exportItem напрямую

    knownCoins = countCoinsInNetwork()
    return true
end

-- ===================== ГЕТТЕРЫ =====================

function economy.getBalance()        return balance end
function economy.getTotalWagered()   return totalWagered end
function economy.getTotalWon()       return totalWon end
function economy.isBusy()            return busy end
function economy.getCoinsInNetwork() return countCoinsInNetwork() end

-- ===================== ВНЕСЕНИЕ =====================

function economy.update()
    if busy or not meController then return 0 end
    local current = countCoinsInNetwork()
    if current > knownCoins then
        local added = current - knownCoins
        balance = balance + added
        knownCoins = current
        return added
    elseif current < knownCoins then
        knownCoins = current
    end
    return 0
end

-- ===================== СТАВКА / ВЫИГРЫШ =====================

function economy.bet(amount)
    if busy or amount <= 0 or balance < amount then return false end
    balance = balance - amount
    totalWagered = totalWagered + amount
    return true
end

function economy.addWin(amount)
    if amount and amount > 0 then
        balance = balance + amount
        totalWon = totalWon + amount
    end
end

-- ===================== ВЫДАЧА (через exportItem в сундук сверху) =====================

-- Выдать count монет "каз" в сундук сверху (direction UP).
-- Возвращает сколько реально выдано.
function economy.withdraw(count)
    if not meInterface then return 0 end
    if not count or count <= 0 then return 0 end

    busy = true

    -- сколько именно "каз" в сети (по label) - не выдаём больше
    local available = countCoinsInNetwork()
    if available <= 0 then busy = false; return 0 end
    local target = math.min(count, available)

    -- фингерпринт монеты: id + damage (nbt_hash недоступен в этой версии,
    -- поэтому страхуемся лимитом target = число "каз" в сети)
    local fingerprint = {id = COIN_NAME, dmg = 0}

    local delivered = 0
    local ok, moved = pcall(meInterface.exportItem, fingerprint, "UP", target)
    if ok then
        -- exportItem может вернуть число или таблицу с полем size/count
        if type(moved) == "number" then
            delivered = moved
        elseif type(moved) == "table" then
            delivered = moved.size or moved.count or moved.n or 0
        end
    end

    knownCoins = countCoinsInNetwork()
    if delivered > balance then delivered = balance end
    balance = balance - delivered

    busy = false
    return delivered
end

-- ===================== ВЫХОД =====================

function economy.shutdown()
    if meInterface then pcall(meInterface.setInterfaceConfiguration, IFACE_SLOT) end
end

return economy
