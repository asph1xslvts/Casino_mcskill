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
--   2) Itemduct с серво: вакуумный сундук -> ME Interface №1 (входной,
--      подключён кабелем к ME Controller). Труба сама постоянно закидывает
--      монеты в интерфейс, AE2 утаскивает их в сеть.
--   3) Adapter, стоящий рядом с ME Controller и подключённый к корпусу
--      компьютера - виден как component.me_controller. Комп ЧИТАЕТ количество
--      монет в сети через него (НЕ через входной интерфейс).
--
--   ВЫВОД (полностью автоматический, без Export Bus):
--   4) ME Interface №2 - ОТДЕЛЬНЫЙ блок только для выдачи, подключён кабелем
--      к тому же ME Controller. У него свой ОТДЕЛЬНЫЙ Adapter, подключённый к
--      корпусу компьютера - виден как component.me_interface.
--   5) Database Upgrade, вставленный в корпус компьютера (виден как
--      component.database). Комп программно заполняет его слот через
--      controller.store({label=...}, database.address, slot) - сеть сама
--      находит монету по имени и кладёт её "призрак" в базу, без участия игрока.
--   6) Комп вызывает meInterface2.setInterfaceConfiguration(withdrawSlot,
--      database.address, dbSlot, count) - сеть сама выкладывает count монет в
--      withdrawSlot ИНТЕРФЕЙСА №2 (того, что только для выдачи).
--   7) Itemduct с РЕДСТОУН-СЕРВО: ME Interface №2 -> сундук выдачи. Труба
--      активна только при сигнале. Комп включает редстоун через Redstone
--      Card/IO, ждёт пока слот интерфейса опустеет (труба забрала), выключает.
--
-- ЛОГИКА:
--   * economy.update() сравнивает текущее количество монет в сети (через
--     me_controller) с тем, что было при прошлом вызове. Рост засчитывается
--     в баланс (труба+интерфейс №1 уже сами отвезли монеты в сеть).
--   * economy.withdraw(amount) программно заполняет database через контроллер,
--     конфигурирует слот ВТОРОГО интерфейса на выдачу amount монет, включает
--     редстоун на трубу и ждёт, пока слот не опустеет - тогда списывает баланс.
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

    -- Чтение баланса и доступ к store() - через Adapter на ME Controller.
    meControllerAddress = nil,  -- nil = единственный me_controller на компе

    -- Выдача - через ОТДЕЛЬНЫЙ ME Interface №2 (только для вывода), у него свой
    -- отдельный Adapter, подключённый к корпусу компьютера - виден как
    -- component.me_interface, отдельно от входного интерфейса №1 (который не
    -- подключён к OC вообще и этому модулю не нужен).
    meInterfaceAddress = nil,   -- адрес ME Interface №2 (nil = единственный me_interface)
    databaseAddress     = nil,  -- адрес Database Upgrade (nil = единственный)
    dbSlot       = 1,   -- слот базы данных для описания монеты
    withdrawSlot = 1,   -- слот ME Interface №2, используемый для выдачи

    redstoneSide  = 3,   -- сторона, куда подаётся редстоун-сигнал на трубу выдачи
    redstoneValue = 15,  -- сила сигнала ("включить" трубу)

    withdrawTimeout = 10,  -- сек. макс. ожидания, пока труба забирает выданное
}

local state = {
    balance = 0,
    totalWagered = 0,
    totalWon = 0,
    lastNetworkCount = nil,  -- для отслеживания прироста монет в сети между update()
}

local busy = false
local meController = nil
local meInterface = nil
local database = nil
local redstone = nil

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

local function resolveMeController() return resolveComponent(cfg.meControllerAddress, "me_controller") end
local function resolveMeInterface() return resolveComponent(cfg.meInterfaceAddress, "me_interface") end
local function resolveDatabase() return resolveComponent(cfg.databaseAddress, "database") end
local function resolveRedstone() return resolveComponent(nil, "redstone") end

-- Сколько монет сейчас лежит в ME-сети (только чтение, через me_controller).
-- Не полагаемся на точный формат filter (отличается между версиями AE2/OC) -
-- получаем все предметы сети и фильтруем сами по label/name в Lua.
local function countCoinsInNetwork()
    if not meController then return 0 end
    local ok, items = pcall(meController.getItemsInNetwork)
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
    meController = resolveMeController()
    meInterface = resolveMeInterface()
    database = resolveDatabase()
    redstone = resolveRedstone()
    load()

    -- Запоминаем текущее число монет в сети, чтобы не засчитать как "новый
    -- депозит" то, что уже физически лежало в сети до запуска программы.
    state.lastNetworkCount = countCoinsInNetwork()

    return meController ~= nil
end

function economy.getBalance() return state.balance end
function economy.getTotalWagered() return state.totalWagered end
function economy.getTotalWon() return state.totalWon end
function economy.isBusy() return busy end
function economy.hasHardware() return meController ~= nil end
function economy.hasWithdrawHardware()
    return (meController ~= nil) and (meInterface ~= nil) and (database ~= nil) and (redstone ~= nil)
end
function economy.coinsInNetwork() return countCoinsInNetwork() end

-- ОБНОВЛЕНИЕ ДЕПОЗИТА: вызывай регулярно (например в главном цикле между
-- событиями). Сравнивает текущее число монет в сети с предыдущим; рост
-- засчитывается в баланс игрока. Труба сама уже отвезла монеты в сеть - этот
-- метод просто следит за итогом.
-- Возвращает количество вновь обнаруженных монет (0 если изменений нет).
function economy.update()
    if busy or not meController then return 0 end
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

-- ВЫВОД: программно заполняет Database Upgrade (через meController.store, сеть
-- сама находит монету по label), настраивает слот ВТОРОГО ME Interface на
-- выдачу amount монет (meInterface.setInterfaceConfiguration), затем включает
-- редстоун на трубу-выдачу и ждёт, пока слот не опустеет (труба забрала), потом
-- выключает сигнал. Списывает баланс только по факту подтверждённой выдачи -
-- если труба не успела забрать за withdrawTimeout, баланс не трогаем (защита от
-- потери монет игрока "в пустоту").
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

    -- 1) Просим сеть (через контроллер) положить описание монеты в слот базы данных.
    pcall(database.clear, cfg.dbSlot)
    local storedOk = false
    local okStore = pcall(function()
        storedOk = meController.store({label = cfg.coinLabel}, database.address, cfg.dbSlot)
    end)

    if not okStore or not storedOk then
        busy = false
        return 0, state.balance
    end

    -- 2) Настраиваем слот ВТОРОГО (выделенного для выдачи) интерфейса на выдачу
    -- `want` штук этой монеты. Сеть сама положит их в withdrawSlot интерфейса №2.
    local configuredOk = false
    pcall(function()
        configuredOk = meInterface.setInterfaceConfiguration(
            cfg.withdrawSlot, database.address, cfg.dbSlot, want)
    end)

    if not configuredOk then
        pcall(meInterface.setInterfaceConfiguration, cfg.withdrawSlot)  -- сброс
        busy = false
        return 0, state.balance
    end

    -- 3) Даём сети немного времени выложить монеты в слот, затем включаем
    -- редстоун на трубу выдачи и ждём, пока слот не опустеет (труба забрала).
    os.sleep(0.5)

    redstone.setOutput(cfg.redstoneSide, cfg.redstoneValue)

    local startTime = computer.uptime()
    local delivered = 0
    while computer.uptime() - startTime < cfg.withdrawTimeout do
        os.sleep(0.3)
        local okk, current = pcall(meInterface.getInterfaceConfiguration, cfg.withdrawSlot)
        if okk and (not current or (current.size or 0) == 0) then
            delivered = want
            break
        end
    end

    redstone.setOutput(cfg.redstoneSide, 0)

    -- Сбрасываем конфигурацию слота интерфейса и базы данных
    pcall(meInterface.setInterfaceConfiguration, cfg.withdrawSlot)
    pcall(database.clear, cfg.dbSlot)

    if delivered > 0 then
        state.balance = state.balance - delivered * cfg.coinValue
        if state.balance < 0 then state.balance = 0 end
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
