-- ===================================================================
-- economy.lua - экономика казино через ME-сеть (IC2 монета "каз")
-- Чтение баланса: me_controller, фильтр name="IC2:itemCoin", label="каз"
-- Выдача: редстоун на сторону 0 (низ) -> ME Export Bus -> сундук выдачи
-- ===================================================================

local component = require("component")
local computer  = require("computer")

local economy = {}

-- ===================== КОНФИГ (подставлено под твою сеть) =====================

local COIN_NAME  = "IC2:itemCoin"  -- технический id монеты
local COIN_LABEL = "каз"           -- отображаемое имя именно нашей монеты
local REDSTONE_SIDE = 0            -- 0 = низ, куда идёт сигнал на export bus

-- Предохранитель выдачи: максимум секунд ждать, пока шина вытолкнет монеты.
-- Если за это время не вышло нужное число (мало монет / шина медленная) - стоп.
local WITHDRAW_TIMEOUT = 15
-- Как часто опрашивать сеть во время выдачи (сек)
local WITHDRAW_POLL = 0.2

-- ===================== СОСТОЯНИЕ =====================

local meController = nil
local redstone     = nil

local balance       = 0     -- внутренний баланс игрока (в монетах)
local totalWagered  = 0
local totalWon      = 0
local knownCoins    = 0     -- сколько "каз" было в сети при прошлой проверке
local busy          = false -- идёт выдача - не считать внесения в этот момент

-- ===================== ВСПОМОГАТЕЛЬНОЕ =====================

-- Сколько монет "каз" сейчас физически в ME-сети
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

-- ===================== ИНИЦИАЛИЗАЦИЯ =====================

-- Возвращает true если железо найдено (контроллер + редстоун)
function economy.setup()
    meController = component.isAvailable("me_controller") and component.me_controller or nil
    redstone     = component.isAvailable("redstone") and component.redstone or nil

    if not meController then
        return false, "ME Controller не найден (проверь адаптер у контроллера)"
    end
    if not redstone then
        return false, "Redstone компонент не найден (нужна Redstone Card)"
    end

    -- на старте: всё, что уже лежит в сети, считаем "известным" -
    -- баланс начинается с нуля, существующие монеты не зачисляем как новый депозит
    knownCoins = countCoinsInNetwork()
    -- редстоун выключен на старте
    pcall(redstone.setOutput, REDSTONE_SIDE, 0)
    return true
end

-- ===================== ГЕТТЕРЫ =====================

function economy.getBalance()      return balance end
function economy.getTotalWagered() return totalWagered end
function economy.getTotalWon()     return totalWon end
function economy.isBusy()          return busy end
function economy.getCoinsInNetwork() return countCoinsInNetwork() end

-- ===================== ВНЕСЕНИЕ =====================

-- Вызывать периодически (раз в ~секунду) из главного цикла.
-- Смотрит, не появилось ли в сети новых монет (игрок бросил в вакуумный сундук).
-- Возвращает число НОВЫХ зачисленных монет (0 если ничего).
function economy.update()
    if busy then return 0 end
    if not meController then return 0 end

    local current = countCoinsInNetwork()
    if current > knownCoins then
        local added = current - knownCoins
        balance = balance + added
        knownCoins = current
        return added
    elseif current < knownCoins then
        -- монет стало меньше без нашей выдачи (например, кто-то вынул вручную) -
        -- просто синхронизируемся, баланс не трогаем
        knownCoins = current
    end
    return 0
end

-- ===================== СТАВКА =====================

-- Снять ставку с баланса. true если успешно, false если не хватает.
function economy.bet(amount)
    if busy then return false end
    if amount <= 0 then return false end
    if balance < amount then return false end
    balance = balance - amount
    totalWagered = totalWagered + amount
    return true
end

-- ===================== ВЫИГРЫШ (только начисление на баланс) =====================

function economy.addWin(amount)
    if amount and amount > 0 then
        balance = balance + amount
        totalWon = totalWon + amount
    end
end

-- ===================== ФИЗИЧЕСКАЯ ВЫДАЧА МОНЕТ =====================

-- Выдать count монет "каз" в сундук выдачи через редстоун + export bus.
-- Возвращает сколько монет реально выдано.
function economy.withdraw(count)
    if not meController or not redstone then return 0 end
    if not count or count <= 0 then return 0 end

    busy = true

    local before = countCoinsInNetwork()
    if before <= 0 then
        busy = false
        return 0
    end

    -- не пытаемся выдать больше, чем есть в сети
    local target = math.min(count, before)

    -- включаем шину: export bus начинает выталкивать "каз" в сундук
    pcall(redstone.setOutput, REDSTONE_SIDE, 15)

    local startTime = computer.uptime()
    local delivered = 0

    while delivered < target do
        local now = countCoinsInNetwork()
        delivered = before - now
        if delivered >= target then break end
        if computer.uptime() - startTime > WITHDRAW_TIMEOUT then
            break  -- предохранитель: шина не успела / монет не хватает
        end
        os.sleep(WITHDRAW_POLL)
    end

    -- выключаем шину
    pcall(redstone.setOutput, REDSTONE_SIDE, 0)

    -- обновляем "известное" количество - то, что осталось в сети
    knownCoins = countCoinsInNetwork()

    -- списываем выданное с баланса (выдаём только то, что реально ушло)
    if delivered > balance then delivered = balance end
    balance = balance - delivered

    busy = false
    return delivered
end

-- ===================== ВЫХОД =====================

-- На всякий случай выключить редстоун (вызывать при завершении программы)
function economy.shutdown()
    if redstone then pcall(redstone.setOutput, REDSTONE_SIDE, 0) end
end

return economy
