-- ===================================================================
-- economy.lua - модуль экономики для казино OpenComputers (AE2-версия)
--
--     local economy = require("economy")
--     economy.setup({ ... })
--     economy.update()   -- вызывать регулярно в главном цикле игры
--
-- СХЕМА ЖЕЛЕЗА:
--   ВНЕСЕНИЕ (полностью автоматическое, без участия компьютера):
--   1) Вакуумный сундук (Ender IO): игрок БРОСАЕТ монеты рядом, всасываются.
--   2) Itemduct с серво: вакуумный сундук -> ME Interface (подключённый к
--      ME-сети). Труба сама постоянно закидывает монеты в интерфейс, AE2
--      утаскивает их в сеть.
--   3) ME Interface рядом с корпусом компьютера - подключён и к OC (виден как
--      component.me_interface), и к той же сети. Комп ЧИТАЕТ количество монет.
--
--   ВЫВОД (полностью автоматический, без ручной настройки в игре):
--   4) ME Export Bus, направленный в сундук выдачи, подключён к OC (виден как
--      component.me_exportbus) и к той же сети.
--   5) Database Upgrade, вставленный в корпус компьютера (виден как
--      component.database). Комп программно заполняет его слот через
--      meInterface.store({label=...}, database.address, slot) - сеть сама
--      находит монету по имени и кладёт её "призрак" в базу, без участия игрока.
--   6) Комп настраивает export bus на этот слот базы и вызывает exportIntoSlot
--      нужное число раз, пока не выдаст нужное количество монет.
--
-- ЛОГИКА:
--   * economy.update() сравнивает текущее количество монет в сети с тем, что
--     было при прошлом вызове. Рост засчитывается в баланс (труба+интерфейс
--     №1 уже сами отвезли монеты в сеть - этот метод просто следит за итогом).
--   * economy.withdraw(amount) программно настраивает database+exportbus и
--     выгружает amount монет в сундук выдачи, подтверждая успех по факту
--     уменьшения количества в сети, и только потом списывает баланс.
--   * Защита: баланс с 0, растёт только от подтверждённого прироста в сети.
--     Вывод не может выдать больше, чем реально есть в сети. busy-флаг
--     защищает от параллельных вызовов (анти-дюп).
-- ===================================================================

local component = require("component")
local fs = require("filesystem")
local serialization = require("serialization")
local computer = require("computer")

local economy = {}

-- ===================== КОНФИГ =====================

local cfg = {
    balanceFile = "/home/casino_balance.dat",
    coinLabel   = "Монета казино",   -- ТОЧНОЕ имя монеты (label стека)
    coinName    = nil,                -- доп. сверка по тех. id (name), необязательно
    coinValue   = 1,                  -- 1 монета = столько единиц баланса

    meInterfaceAddress = nil,  -- адрес ME Interface у компьютера (nil = единственный)
    exportBusAddress    = nil, -- адрес ME Export Bus (nil = единственный)
    databaseAddress      = nil, -- адрес Database Upgrade (nil = единственный)
    exportSide  = 3,    -- сторона, в которую смотрит export bus (на сундук выдачи)
    dbSlot      = 1,    -- слот базы данных, используемый для описания монеты

    withdrawTimeout = 10,  -- сек. макс. ожидания подтверждения вывода
}

local state = {
    balance = 0,
    totalWagered = 0,
    totalWon = 0,
    lastNetworkCount = nil,  -- для отслеживания прироста монет в сети между update()
}

local busy = false
local meInterface = nil
local exportBus = nil
local database = nil

-- ===================== ПЕРСИСТЕНТНОСТЬ =====================

local function save()
    local f = io.open(cfg.balanceFile, "w")
    if f then
        f:write(serialization.serialize({
            balance = state.balance,
            totalWagered = state.totalWagered,
            totalWon = state.totalWon,
        }))
        f:close()
    end
end

local function load()
    if fs.exists(cfg.balanceFile) then
        local f = io.open(cfg.balanceFile, "r")
        if f then
            local data = f:read("*a")
            f:close()
            local ok, result = pcall(serialization.unserialize, data)
            if ok and type(result) == "table" then
                state.balance = result.balance or 0
                state.totalWagered = result.totalWagered or 0
                state.totalWon = result.totalWon or 0
                return
            end
        end
    end
    state.balance = 0
    state.totalWagered = 0
    state.totalWon = 0
end

-- ===================== AE2 / КОМПОНЕНТЫ =====================

local function resolveComponent(address, ctype)
    if address then
        local ok, proxy = pcall(component.proxy, address)
        if ok and proxy then return proxy end
        return nil
    end
    if component.isAvailable(ctype) then
        return component[ctype]
    end
    return nil
end

local function resolveMeInterface() return resolveComponent(cfg.meInterfaceAddress, "me_interface") end
local function resolveExportBus() return resolveComponent(cfg.exportBusAddress, "me_exportbus") end
local function resolveDatabase() return resolveComponent(cfg.databaseAddress, "database") end

-- Сколько монет сейчас лежит в ME-сети (только чтение, ничего не двигаем).
-- Не полагаемся на точный формат filter (отличается между версиями AE2/OC) -
-- получаем все предметы сети и фильтруем сами по label/name в Lua.
local function countCoinsInNetwork()
    if not meInterface then return 0 end
    local ok, items = pcall(meInterface.getItemsInNetwork)
    if not ok or not items then return 0 end
    local total = 0
    for _, item in ipairs(items) do
        if item.label == cfg.coinLabel and (not cfg.coinName or item.name == cfg.coinName) then
            total = total + (item.size or 0)
        end
    end
    return total
end

-- ===================== ПУБЛИЧНОЕ API =====================

function economy.setup(options)
    if type(options) == "table" then
        for k, v in pairs(options) do cfg[k] = v end
    end
    meInterface = resolveMeInterface()
    exportBus = resolveExportBus()
    database = resolveDatabase()
    load()

    -- Запоминаем текущее число монет в сети, чтобы не засчитать как "новый
    -- депозит" то, что уже физически лежало в сети до запуска программы.
    state.lastNetworkCount = countCoinsInNetwork()

    return meInterface ~= nil
end

function economy.getBalance() return state.balance end
function economy.getTotalWagered() return state.totalWagered end
function economy.getTotalWon() return state.totalWon end
function economy.isBusy() return busy end
function economy.hasHardware() return meInterface ~= nil end
function economy.hasWithdrawHardware()
    return (meInterface ~= nil) and (exportBus ~= nil) and (database ~= nil)
end
function economy.coinsInNetwork() return countCoinsInNetwork() end

-- ОБНОВЛЕНИЕ ДЕПОЗИТА: вызывай регулярно (например в главном цикле между
-- событиями). Сравнивает текущее число монет в сети с предыдущим; рост
-- засчитывается в баланс игрока. Труба сама уже отвезла монеты в сеть - этот
-- метод просто следит за итогом.
-- Возвращает количество вновь обнаруженных монет (0 если изменений нет).
function economy.update()
    if busy or not meInterface then return 0 end
    local current = countCoinsInNetwork()
    if state.lastNetworkCount == nil then
        state.lastNetworkCount = current
        return 0
    end

    local delta = current - state.lastNetworkCount
    state.lastNetworkCount = current

    if delta > 0 then
        state.balance = state.balance + delta * cfg.coinValue
        save()
        return delta
    end

    return 0
end

-- ВЫВОД: программно настраивает Database Upgrade (через meInterface.store, сеть
-- сама находит монету по label) и ME Export Bus, затем вызывает exportIntoSlot
-- нужное число раз, выгружая amount монет в сундук выдачи. Подтверждает успех
-- по факту убывания количества монет в сети, и только тогда списывает баланс -
-- если сеть не подтвердила убыль (например труба/шина не сработали), баланс не
-- трогаем, чтобы не потерять монеты игрока "в пустоту".
-- Возвращает (выдано_монет, новый_баланс).
function economy.withdraw(amount)
    if busy then return 0, state.balance end
    if not economy.hasWithdrawHardware() then return 0, state.balance end

    local affordable = math.floor(state.balance / cfg.coinValue)
    local want = math.min(amount or affordable, affordable)
    if want <= 0 then return 0, state.balance end

    -- Не выводим больше, чем реально физически есть в сети.
    local inNetwork = countCoinsInNetwork()
    want = math.min(want, inNetwork)
    if want <= 0 then return 0, state.balance end

    busy = true

    -- 1) Просим сеть положить описание монеты в слот базы данных.
    pcall(database.clear, cfg.dbSlot)
    local storedOk = false
    local okStore = pcall(function()
        storedOk = meInterface.store({label = cfg.coinLabel}, database.address, cfg.dbSlot)
    end)

    if not okStore or not storedOk then
        busy = false
        return 0, state.balance
    end

    -- 2) Настраиваем export bus на этот слот базы данных.
    local configuredOk = false
    pcall(function()
        configuredOk = exportBus.setExportConfiguration(cfg.exportSide, 1, database.address, cfg.dbSlot)
    end)

    if not configuredOk then
        pcall(exportBus.setExportConfiguration, cfg.exportSide)  -- сброс конфигурации
        busy = false
        return 0, state.balance
    end

    -- 3) Вызываем экспорт нужное число раз (по одной монете за вызов, чтобы
    -- точно знать сколько физически ушло - не зависим от размера стека).
    local startTime = computer.uptime()
    local delivered = 0
    local startNetworkCount = countCoinsInNetwork()

    while delivered < want do
        if computer.uptime() - startTime > cfg.withdrawTimeout then
            break
        end
        pcall(exportBus.exportIntoSlot, cfg.exportSide, 1)
        os.sleep(0.2)

        local now = countCoinsInNetwork()
        local actuallyLeft = startNetworkCount - now
        if actuallyLeft > delivered then
            delivered = actuallyLeft
        end
    end

    -- Сбрасываем конфигурацию export bus, чтобы он не продолжал выгружать сам
    pcall(exportBus.setExportConfiguration, cfg.exportSide)
    pcall(database.clear, cfg.dbSlot)

    if delivered > want then delivered = want end

    if delivered > 0 then
        state.balance = state.balance - delivered * cfg.coinValue
        if state.balance < 0 then state.balance = 0 end
        -- Синхронизируем счётчик сети, чтобы update() не принял этот спад за
        -- что-то другое (он и так не реагирует на убыль, но обновим для точности)
        state.lastNetworkCount = countCoinsInNetwork()
        save()
    end

    busy = false
    return delivered, state.balance
end

-- СТАВКА: снимает ставку с баланса. true если хватило и не занято.
function economy.bet(amount)
    if busy then return false end
    if amount <= 0 then return false end
    if state.balance < amount then return false end
    state.balance = state.balance - amount
    state.totalWagered = state.totalWagered + amount
    save()
    return true
end

-- Возврат ставки (ничья/отмена).
function economy.refund(amount)
    if amount <= 0 then return end
    state.balance = state.balance + amount
    state.totalWagered = math.max(0, state.totalWagered - amount)
    save()
end

-- ВЫИГРЫШ: начисляет на баланс. Физическая выдача - отдельный вызов economy.withdraw().
function economy.addWin(amount)
    if amount <= 0 then return end
    state.balance = state.balance + amount
    state.totalWon = state.totalWon + amount
    save()
end

-- Можно ли сейчас играть (есть баланс под ставку)?
function economy.canPlay(minBet)
    minBet = minBet or 1
    return (not busy) and state.balance >= minBet
end

return economy
