-- ===================================================================
-- economy.lua - общий модуль экономики для казино OpenComputers
-- Используется всеми играми (слоты, рулетка, блекджек). Каждая игра/компьютер
-- подключает его и имеет СВОЙ локальный баланс и свои сундуки.
--
--     local economy = require("economy")
--     economy.setup({ ... })
--
-- СХЕМА ЖЕЛЕЗА (3 инвентаря на сторонах одного транспозера):
--   1) depositSide  - вакуумный сундук (Ender IO): игрок БРОСАЕТ монеты рядом,
--                     они всасываются сюда. Транспозер считает и забирает их.
--   2) vaultSide    - закрытая касса (буфер): сюда транспозер кладёт внесённые
--                     монеты. У игрока НЕТ доступа руками. Отсюда берутся выплаты.
--   3) payoutSide   - сундук выдачи: комп САМ кладёт сюда монеты при выводе,
--                     игрок забирает руками.
--
-- ЗАЩИТА:
--   * Баланс начинается с 0 и растёт только от реально перемещённых монет.
--   * Внесение засчитывает только то, что физически переехало (по факту transferItem).
--   * Вывод: комп сам перекладывает из кассы в выдачу не больше min(баланс, касса).
--     Игрок не может забрать больше или дважды - баланс списывается по факту.
--   * busy-флаг блокирует игру/вывод/внесение во время перемещения монет (анти-дюп).
--   * Монета опознаётся по label (и опц. name) - мусор не засчитывается.
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

    depositSide = 1,   -- вакуумный сундук (вход)
    vaultSide   = 3,   -- закрытая касса (буфер)
    payoutSide  = 0,   -- сундук выдачи (выход)

    transposerAddress = nil,  -- адрес конкретного транспозера (если их несколько)
}

local state = {
    balance = 0,
    totalWagered = 0,
    totalWon = 0,
}

local busy = false
local transposer = nil

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

-- ===================== ТРАНСПОЗЕР / МОНЕТЫ =====================

local function resolveTransposer()
    if cfg.transposerAddress then
        local ok, proxy = pcall(component.proxy, cfg.transposerAddress)
        if ok and proxy then return proxy end
    end
    if component.isAvailable("transposer") then
        return component.transposer
    end
    return nil
end

local function isCoin(stack)
    if not stack then return false end
    if cfg.coinName and stack.name ~= cfg.coinName then return false end
    if stack.label ~= cfg.coinLabel then return false end
    return true
end

-- Сколько монет лежит на указанной стороне.
local function countCoins(side)
    if not transposer then return 0 end
    local ok, size = pcall(transposer.getInventorySize, side)
    if not ok or not size then return 0 end
    local total = 0
    for slot = 1, size do
        local okk, stack = pcall(transposer.getStackInSlot, side, slot)
        if okk and stack and isCoin(stack) then
            total = total + (stack.size or 0)
        end
    end
    return total
end

-- Переносит ДО maxCount монет со стороны fromSide на сторону toSide.
-- Возвращает фактически перенесённое количество.
local function moveCoins(fromSide, toSide, maxCount)
    if not transposer then return 0 end
    if maxCount <= 0 then return 0 end
    local ok, size = pcall(transposer.getInventorySize, fromSide)
    if not ok or not size then return 0 end

    local movedTotal = 0
    for slot = 1, size do
        if movedTotal >= maxCount then break end
        local okk, stack = pcall(transposer.getStackInSlot, fromSide, slot)
        if okk and stack and isCoin(stack) then
            local want = math.min(stack.size or 0, maxCount - movedTotal)
            if want > 0 then
                local okm, m = pcall(transposer.transferItem, fromSide, toSide, want, slot)
                if okm and type(m) == "number" then
                    movedTotal = movedTotal + m
                end
            end
        end
    end
    return movedTotal
end

-- ===================== ПУБЛИЧНОЕ API =====================

function economy.setup(options)
    if type(options) == "table" then
        for k, v in pairs(options) do cfg[k] = v end
    end
    transposer = resolveTransposer()
    load()
    return transposer ~= nil
end

function economy.getBalance() return state.balance end
function economy.getTotalWagered() return state.totalWagered end
function economy.getTotalWon() return state.totalWon end
function economy.isBusy() return busy end
function economy.hasTransposer() return transposer ~= nil end

-- Монет в вакуумном сундуке прямо сейчас (ждут внесения).
function economy.coinsInDeposit() return countCoins(cfg.depositSide) end
-- Монет в кассе (доступно для выплат).
function economy.coinsInVault() return countCoins(cfg.vaultSide) end
-- Монет в выдаче (ждут, пока игрок заберёт).
function economy.coinsInPayout() return countCoins(cfg.payoutSide) end

-- ВНЕСЕНИЕ: переносит все монеты из вакуумного сундука в кассу, баланс += перенесено.
-- Возвращает (внесено_монет, новый_баланс).
function economy.deposit()
    if busy or not transposer then return 0, state.balance end
    busy = true

    local available = countCoins(cfg.depositSide)
    local moved = 0
    if available > 0 then
        moved = moveCoins(cfg.depositSide, cfg.vaultSide, available)
    end
    if moved > 0 then
        state.balance = state.balance + moved * cfg.coinValue
        save()
    end

    busy = false
    return moved, state.balance
end

-- ВЫВОД: комп сам перекладывает из кассы в выдачу min(баланс, касса) монет и
-- списывает баланс по факту перенесённого. Игрок забирает монеты из выдачи.
-- requestCoins (необязательно) - ограничить вывод этим числом монет.
-- Возвращает (выведено_монет, новый_баланс).
function economy.withdraw(requestCoins)
    if busy or not transposer then return 0, state.balance end
    busy = true

    local affordable = math.floor(state.balance / cfg.coinValue)
    local inVault = countCoins(cfg.vaultSide)
    local want = math.min(affordable, inVault)
    if requestCoins and requestCoins > 0 then
        want = math.min(want, requestCoins)
    end

    local moved = 0
    if want > 0 then
        moved = moveCoins(cfg.vaultSide, cfg.payoutSide, want)
    end
    if moved > 0 then
        state.balance = state.balance - moved * cfg.coinValue
        if state.balance < 0 then state.balance = 0 end
        save()
    end

    busy = false
    return moved, state.balance
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

-- ВЫИГРЫШ: начисляет на баланс.
function economy.addWin(amount)
    if amount <= 0 then return end
    state.balance = state.balance + amount
    state.totalWon = state.totalWon + amount
    save()
end

-- Можно ли сейчас играть (есть баланс под ставку и не идёт перемещение монет)?
function economy.canPlay(minBet)
    minBet = minBet or 1
    return (not busy) and state.balance >= minBet
end

return economy
