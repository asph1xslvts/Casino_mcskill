-- ===================================================================
-- economy.lua - модуль экономики для казино OpenComputers (упрощённая AE2-версия)
--
--     local economy = require("economy")
--     economy.setup({ ... })
--     economy.update()   -- вызывать регулярно в главном цикле игры
--
-- СХЕМА ЖЕЛЕЗА (то, что реально нужно):
--   1) Вакуумный сундук (Ender IO): игрок БРОСАЕТ монеты рядом, всасываются.
--   2) Itemduct с серво: вакуумный сундук -> ME Interface (подключённый к
--      ME-сети). Труба сама постоянно закидывает монеты в интерфейс, AE2
--      утаскивает их в сеть. Это работает САМО, без участия компьютера.
--   3) ME Interface (любой в сети, например тот же или другой) стоит РЯДОМ С
--      КОРПУСОМ КОМПЬЮТЕРА - подключён и к OC (виден как component.me_interface),
--      и к той же ME-сети. Через него комп ТОЛЬКО ЧИТАЕТ, сколько монет в сети.
--
-- ЛОГИКА (всё, что делает этот модуль):
--   * economy.update() сравнивает текущее количество монет в сети с тем, что
--     было при прошлом вызове. Если выросло - разница засчитывается в баланс
--     игрока. Это и есть "монета попала в сеть = засчитано как внесённая".
--   * economy.bet()/addWin() - обычная работа с балансом (ставка/выигрыш),
--     никак не трогает физические монеты.
--   * Выдача выигрыша обратно игроку в этой версии модуля НЕ реализована -
--     баланс просто хранится как число. Если нужно физически выдавать монеты,
--     это добавим отдельным шагом, когда решим как именно.
-- ===================================================================

local component = require("component")
local fs = require("filesystem")
local serialization = require("serialization")

local economy = {}

-- ===================== КОНФИГ =====================

local cfg = {
    balanceFile = "/home/casino_balance.dat",
    coinLabel   = "Монета казино",   -- ТОЧНОЕ имя монеты (label стека)
    coinName    = nil,                -- доп. сверка по тех. id (name), необязательно
    coinValue   = 1,                  -- 1 монета = столько единиц баланса

    meInterfaceAddress = nil,  -- адрес ME Interface у компьютера (nil = единственный)
}

local state = {
    balance = 0,
    totalWagered = 0,
    totalWon = 0,
    lastNetworkCount = nil,  -- для отслеживания прироста монет в сети между update()
}

local busy = false
local meInterface = nil

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

-- ===================== AE2 / ME INTERFACE (ЧТЕНИЕ) =====================

local function resolveMeInterface()
    if cfg.meInterfaceAddress then
        local ok, proxy = pcall(component.proxy, cfg.meInterfaceAddress)
        if ok and proxy then return proxy end
        return nil
    end
    if component.isAvailable("me_interface") then
        return component.me_interface
    end
    return nil
end

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

-- ВЫИГРЫШ: начисляет на баланс. Физическая выдача монет - НЕ часть этого
-- модуля пока; баланс просто растёт как число.
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
