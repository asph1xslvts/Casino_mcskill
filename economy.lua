-- ===================================================================
-- economy.lua - экономика казино через ME-сеть IC2 moneta kaz
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
    if not database     then return false, "Database (адаптер+база) не найдена" end

    -- очистим слот конфигурации интерфейса на старте
    pcall(meInterface.setInterfaceConfiguration, IFACE_SLOT)

    -- сохраним образец монеты "каз" в базу (нужен для адресации NBT-монеты)
    dbReady = prepareCoinSample()
    if not dbReady then
        return false, "Не удалось сохранить образец 'каз' (положи каз в сеть)"
    end

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

-- ===================== ВЫДАЧА (config + pushItem в сундук сверху) =====================
-- exportItem не работает с NBT-монетой "каз" (нужен nbt_hash, недоступен).
-- Зато setInterfaceConfiguration находит "каз" по образцу из database и кладёт
-- в слот интерфейса, а pushItem выталкивает из слота в сундук сверху (UP).

local PUSH_DIRECTION = "UP"   -- куда выталкивать (сундук сверху интерфейса)

function economy.withdraw(count)
    print("[wd] старт, count=" .. tostring(count))
    if not (meInterface and database and dbReady) then
        print("[wd] нет железа: iface=" .. tostring(meInterface ~= nil)
            .. " db=" .. tostring(database ~= nil) .. " dbReady=" .. tostring(dbReady))
        return 0
    end
    if not count or count <= 0 then print("[wd] count<=0"); return 0 end

    busy = true

    local available = countCoinsInNetwork()
    print("[wd] каз в сети=" .. available)
    if available <= 0 then busy = false; print("[wd] сеть пустая"); return 0 end
    local target = math.min(count, available)
    print("[wd] target=" .. target)

    local delivered = 0

    while delivered < target do
        local chunk = math.min(target - delivered, 64)
        print("[wd] chunk=" .. chunk)

        local okc = pcall(meInterface.setInterfaceConfiguration, IFACE_SLOT, database.address, DB_SLOT, chunk)
        print("[wd] setConfig ok=" .. tostring(okc))

        os.sleep(1.5)

        local c = nil
        pcall(function() c = meInterface.getInterfaceConfiguration(IFACE_SLOT) end)
        print("[wd] в слоте: " .. (c and (tostring(c.label) .. " x" .. tostring(c.size)) or "ПУСТО"))

        local moved = 0
        local ok, res = pcall(meInterface.pushItem, PUSH_DIRECTION, IFACE_SLOT, chunk)
        print("[wd] pushItem ok=" .. tostring(ok) .. " res=" .. tostring(res))
        if ok and type(res) == "number" then moved = res end

        delivered = delivered + moved
        if moved == 0 then print("[wd] moved=0, выход"); break end
    end

    pcall(meInterface.setInterfaceConfiguration, IFACE_SLOT)

    knownCoins = countCoinsInNetwork()
    if delivered > balance then delivered = balance end
    balance = balance - delivered

    busy = false
    print("[wd] итого выдано=" .. delivered)
    return delivered
end

-- ===================== ВЫХОД =====================

function economy.shutdown()
    if meInterface then pcall(meInterface.setInterfaceConfiguration, IFACE_SLOT) end
end

return economy
