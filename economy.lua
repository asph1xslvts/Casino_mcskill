-- ===================================================================
-- economy.lua - общий модуль экономики для казино OpenComputers
-- Используется всеми играми (слоты, рулетка, блекджек). Каждая игра/компьютер
-- подключает его и имеет СВОЙ локальный баланс и свои сундуки.
--
--     local economy = require("economy")
--     economy.setup({ ... })
--     economy.update()   -- вызывать регулярно (см. ниже) для авто-приёма монет
--
-- СХЕМА ЖЕЛЕЗА (без транспозера и без роботов - они недоступны):
--   1) Вакуумный сундук (Ender IO): игрок БРОСАЕТ монеты рядом, они всасываются.
--   2) Itemduct (Thermal Expansion) переносит монеты из вакуумного сундука в
--      сундук-кассу САМОСТОЯТЕЛЬНО, без участия компьютера (труба работает всегда).
--   3) Adapter + Inventory Controller Upgrade, прижатый к КАССЕ - комп этим
--      ЧИТАЕТ количество монет в кассе (depositAdapterAddress / vaultSide).
--   4) Второй Adapter + Inventory Controller Upgrade, прижатый к СУНДУКУ ВЫДАЧИ -
--      комп этим ЧИТАЕТ, сколько уже выдано (payoutAdapterAddress / payoutSide).
--   5) Itemduct из кассы в сундук выдачи, с серво + редстоун-фильтром
--      ("активен по сигналу") - труба переносит монеты ТОЛЬКО когда комп подаёт
--      редстоун-сигнал через Redstone Card/IO (redstoneSide).
--
-- ЛОГИКА:
--   * Депозит: каждый вызов economy.update() сравнивает текущее число монет в
--     кассе с тем, что было раньше. Рост засчитывается в баланс (труба от
--     вакуумного сундука работает сама, комп просто следит за итогом).
--   * Вывод: economy.withdraw(amount) включает редстоун на трубу выдачи и держит
--     его, пока в сундуке выдачи не появится нужное количество монет (считая по
--     второму адаптеру), затем выключает сигнал. Работает синхронно (блокирует
--     поток на время выдачи) - это нормально для коротких сумм.
--   * Защита: баланс с 0, растёт только от реально подтверждённого прироста в
--     кассе. Вывод не может выдать больше, чем подтверждено физически в выдаче.
--     busy-флаг защищает от параллельных вызовов.
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

    -- Адреса адаптеров (component.proxy). Если nil - берётся первый найденный
    -- инвентори-контроллер (подходит только если он один на компьютере).
    vaultAdapterAddress   = nil,  -- адаптер, прижатый к КАССЕ
    payoutAdapterAddress  = nil,  -- адаптер, прижатый к СУНДУКУ ВЫДАЧИ

    -- Сторона блока (кассы/выдачи) ОТНОСИТЕЛЬНО адаптера, на которой он стоит.
    -- 0=низ,1=верх,2=север,3=юг,4=запад,5=восток
    vaultSide  = 3,
    payoutSide = 3,

    -- Редстоун на трубу выдачи (Redstone Card/IO). side - куда транспозер/комп
    -- должен подавать сигнал (сторона редстоун-компонента).
    redstoneSide = 3,
    redstoneValue = 15,   -- сила сигнала для "открыть" трубу

    withdrawTimeout = 10,  -- сек. макс. ожидания при выводе, чтобы не зависнуть навечно
}

local state = {
    balance = 0,
    totalWagered = 0,
    totalWon = 0,
    lastVaultCount = nil,  -- для отслеживания прироста в кассе между вызовами update()
}

local busy = false
local vaultAdapter = nil
local payoutAdapter = nil
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

-- ===================== АДАПТЕРЫ / РЕДСТОУН =====================

local function resolveInventoryController(address)
    if address then
        local ok, proxy = pcall(component.proxy, address)
        if ok and proxy then return proxy end
        return nil
    end
    if component.isAvailable("inventory_controller") then
        return component.inventory_controller
    end
    return nil
end

local function resolveRedstone()
    if component.isAvailable("redstone") then
        return component.redstone
    end
    return nil
end

local function isCoin(stack)
    if not stack then return false end
    if cfg.coinName and stack.name ~= cfg.coinName then return false end
    if stack.label ~= cfg.coinLabel then return false end
    return true
end

-- Считает монеты через указанный inventory_controller-адаптер на указанной стороне.
local function countCoinsVia(adapter, side)
    if not adapter then return 0 end
    local ok, size = pcall(adapter.getInventorySize, side)
    if not ok or not size then return 0 end
    local total = 0
    for slot = 1, size do
        local okk, stack = pcall(adapter.getStackInSlot, side, slot)
        if okk and stack and isCoin(stack) then
            total = total + (stack.size or 0)
        end
    end
    return total
end

-- ===================== ПУБЛИЧНОЕ API =====================

function economy.setup(options)
    if type(options) == "table" then
        for k, v in pairs(options) do cfg[k] = v end
    end
    vaultAdapter = resolveInventoryController(cfg.vaultAdapterAddress)
    payoutAdapter = resolveInventoryController(cfg.payoutAdapterAddress)
    redstone = resolveRedstone()
    load()

    -- Инициализируем счётчик кассы, чтобы первый update() не засчитал как
    -- депозит то, что уже физически лежало в кассе до запуска программы.
    state.lastVaultCount = countCoinsVia(vaultAdapter, cfg.vaultSide)

    return (vaultAdapter ~= nil) and (payoutAdapter ~= nil) and (redstone ~= nil)
end

function economy.getBalance() return state.balance end
function economy.getTotalWagered() return state.totalWagered end
function economy.getTotalWon() return state.totalWon end
function economy.isBusy() return busy end
function economy.hasHardware()
    return (vaultAdapter ~= nil) and (payoutAdapter ~= nil) and (redstone ~= nil)
end

function economy.coinsInVault() return countCoinsVia(vaultAdapter, cfg.vaultSide) end
function economy.coinsInPayout() return countCoinsVia(payoutAdapter, cfg.payoutSide) end

-- ОБНОВЛЕНИЕ ДЕПОЗИТА: вызывай регулярно (например в главном цикле между событиями).
-- Сравнивает текущее число монет в кассе с предыдущим; рост засчитывает в баланс.
-- Труба сама носит монеты из вакуумного сундука - этот метод просто следит за итогом.
-- Возвращает количество вновь обнаруженных монет (0 если изменений нет).
function economy.update()
    if busy or not vaultAdapter then return 0 end
    local current = countCoinsVia(vaultAdapter, cfg.vaultSide)
    if state.lastVaultCount == nil then
        state.lastVaultCount = current
        return 0
    end

    local delta = current - state.lastVaultCount
    state.lastVaultCount = current

    if delta > 0 then
        state.balance = state.balance + delta * cfg.coinValue
        save()
        return delta
    end
    -- delta < 0 означает что касса уменьшилась (например идёт выдача или кто-то
    -- руками вмешался) - такое снижение НЕ влияет на баланс напрямую здесь,
    -- баланс уже был списан в момент withdraw().
    return 0
end

-- ВЫВОД: включает редстоун на трубу выдачи и ждёт, пока в сундуке выдачи не
-- появится нужное количество монет (считая по payoutAdapter), потом выключает
-- сигнал. Защита: не выдаёт больше, чем позволяет баланс; таймаут на случай
-- если труба/касса не успевают физически передать монеты.
-- Возвращает (выдано_монет, новый_баланс).
function economy.withdraw(amount)
    if busy then return 0, state.balance end
    if not (vaultAdapter and payoutAdapter and redstone) then return 0, state.balance end

    local affordable = math.floor(state.balance / cfg.coinValue)
    local want = math.min(amount or affordable, affordable)
    if want <= 0 then return 0, state.balance end

    busy = true

    local startCount = countCoinsVia(payoutAdapter, cfg.payoutSide)
    local targetCount = startCount + want

    redstone.setOutput(cfg.redstoneSide, cfg.redstoneValue)

    local delivered = 0
    local startTime = computer.uptime()
    while true do
        local now = countCoinsVia(payoutAdapter, cfg.payoutSide)
        delivered = now - startCount
        if delivered >= want then
            delivered = want
            break
        end
        if computer.uptime() - startTime > cfg.withdrawTimeout then
            break  -- не дождались - выдаём столько, сколько реально прошло
        end
        os.sleep(0.2)
    end

    redstone.setOutput(cfg.redstoneSide, 0)

    if delivered > 0 then
        state.balance = state.balance - delivered * cfg.coinValue
        if state.balance < 0 then state.balance = 0 end
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

-- ВЫИГРЫШ: начисляет на баланс (это просто число - физическая выдача происходит
-- позже, отдельным вызовом economy.withdraw(), либо автоматически казино может
-- сразу попытаться выдать выигрыш - см. autoPayout).
function economy.addWin(amount)
    if amount <= 0 then return end
    state.balance = state.balance + amount
    state.totalWon = state.totalWon + amount
    save()
end

-- Можно ли сейчас играть (есть баланс под ставку и не идёт операция с монетами)?
function economy.canPlay(minBet)
    minBet = minBet or 1
    return (not busy) and state.balance >= minBet
end

return economy
