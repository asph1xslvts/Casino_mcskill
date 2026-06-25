-- ===================================================================
-- OpenCasino - слот-машина для OpenComputers
-- Иконки: алмаз (diamond), звезда ада (netherstar), золото (gold), железо (iron)
-- ===================================================================

local component = require("component")
local computer = require("computer")
local term = require("term")
local event = require("event")
local image = require("image")
local fs = require("filesystem")
local keyboard = require("keyboard")
local serialization = require("serialization")

local gpu = component.gpu

-- ===================== НАСТРОЙКИ =====================

local BALANCE_FILE = "/home/casino_balance.dat"
local STARTING_BALANCE = 100

local MIN_BET = 1
local MAX_BET = 10
local BET_STEP_SMALL = 1
local BET_STEP_MED = 5
local BET_STEP_BIG = 10

-- Пути к иконкам - ЗАМЕНИ НА СВОИ ФАЙЛЫ
local ICON_PATHS = {
    diamond    = "/home/icons/diamond.pic",
    netherstar = "/home/icons/netherstar.pic",
    gold       = "/home/icons/gold.pic",
    iron       = "/home/icons/iron.pic",
}

-- Множители за 3 одинаковых предмета (как в таблице на референсе)
local TRIPLE_BONUS = {
    iron       = 10,
    gold       = 25,
    diamond    = 40,
    netherstar = 100,
}

-- Бонусы за частичные совпадения (универсальные, как на референсе)
local EDGE_MATCH_BONUS = 1   -- 2 одинаковых по краям (1-й и 3-й слот)
local ADJACENT_MATCH_BONUS = 2  -- 2 одинаковых рядом (1-2 или 2-3)

-- Веса для случайного выбора (чем выше число, тем чаще выпадает)
local ITEM_WEIGHTS = {
    {id = "iron",       weight = 40},
    {id = "gold",       weight = 30},
    {id = "diamond",    weight = 20},
    {id = "netherstar", weight = 10},
}

-- ===================== БАЛАНС =====================

local balance = STARTING_BALANCE
local currentBet = MIN_BET
local totalWagered = 0
local totalWon = 0

local function loadBalance()
    if fs.exists(BALANCE_FILE) then
        local f = io.open(BALANCE_FILE, "r")
        if f then
            local data = f:read("*a")
            f:close()
            local ok, result = pcall(serialization.unserialize, data)
            if ok and type(result) == "table" then
                balance = result.balance or STARTING_BALANCE
                totalWagered = result.totalWagered or 0
                totalWon = result.totalWon or 0
                return
            end
        end
    end
    balance = STARTING_BALANCE
    totalWagered = 0
    totalWon = 0
end

local function saveBalance()
    local f = io.open(BALANCE_FILE, "w")
    if f then
        f:write(serialization.serialize({
            balance = balance,
            totalWagered = totalWagered,
            totalWon = totalWon,
        }))
        f:close()
    end
end

-- ===================== ИКОНКИ =====================

local loadedIcons = {}

local loadErrors = {}

local function loadIcons()
    for id, path in pairs(ICON_PATHS) do
        if fs.exists(path) then
            local pic, err = image.load(path)
            if pic then
                loadedIcons[id] = pic
            else
                loadErrors[id] = tostring(err)
                io.stderr:write("Не удалось загрузить иконку " .. id .. ": " .. tostring(err) .. "\n")
            end
        else
            loadErrors[id] = "файл не найден: " .. path
            io.stderr:write("Файл иконки не найден: " .. path .. "\n")
        end
    end
end

-- ===================== СЛУЧАЙНЫЙ ВЫБОР ПРЕДМЕТА =====================

local function pickRandomItem()
    local totalWeight = 0
    for _, item in ipairs(ITEM_WEIGHTS) do
        totalWeight = totalWeight + item.weight
    end

    local roll = math.random(1, totalWeight)
    local cumulative = 0
    for _, item in ipairs(ITEM_WEIGHTS) do
        cumulative = cumulative + item.weight
        if roll <= cumulative then
            return item.id
        end
    end

    return ITEM_WEIGHTS[1].id
end

-- ===================== ЛОГИКА ВЫИГРЫША =====================

-- reels = {item1, item2, item3}
-- Возвращает (bonusMultiplier, winAmount)
local function calculateWin(reels, bet)
    local a, b, c = reels[1], reels[2], reels[3]

    -- Три одинаковых - самый большой бонус
    if a == b and b == c then
        local bonus = TRIPLE_BONUS[a] or 0
        return bonus, bet * bonus
    end

    -- Два одинаковых рядом (1-2 или 2-3) - бонус x2
    if a == b or b == c then
        return ADJACENT_MATCH_BONUS, bet * ADJACENT_MATCH_BONUS
    end

    -- Два одинаковых по краям (1-3) - бонус x1
    if a == c then
        return EDGE_MATCH_BONUS, bet * EDGE_MATCH_BONUS
    end

    return 0, 0
end

-- ===================== ИНТЕРФЕЙС / ОТРИСОВКА =====================

local screenW, screenH = gpu.getResolution()

-- Цвета в стиле референса (тёмный фон, синие рамки, голубой текст)
local COLOR_BG = 0x000000
local COLOR_BORDER = 0x0000FF
local COLOR_TEXT = 0x55AAFF
local COLOR_TEXT_DIM = 0xAAAAAA
local COLOR_WHITE = 0xFFFFFF
local COLOR_SLOT_BG = 0x1A1A1A
local COLOR_SLOT_BORDER = 0x555555
local COLOR_BUTTON_BG = 0x000033
local COLOR_BUTTON_BORDER = 0x3399FF

-- Координаты слотов (3 в ряд), подбери под разрешение своего экрана
local SLOT_SIZE = 18      -- ширина/высота рамки слота в символах (иконка 16x16 + отступы под рамку)
local PAYOUT_TABLE_END_Y = 19  -- последняя строка таблицы выплат (8 строк начиная с y=8, плюс отступы)
local SLOT_Y = PAYOUT_TABLE_END_Y + 2  -- пересчитывается в main() под реальную высоту экрана
local SLOT_GAP = 3
local SLOT_START_X = math.floor(screenW / 2) - math.floor((SLOT_SIZE * 3 + SLOT_GAP * 2) / 2)

local slotPositions = {
    SLOT_START_X,
    SLOT_START_X + SLOT_SIZE + SLOT_GAP,
    SLOT_START_X + (SLOT_SIZE + SLOT_GAP) * 2,
}

-- Кнопки ставок: {label, deltaOrAction, x смещение от центра}
local buttons = {}

local function drawBox(x, y, w, h, borderColor, bgColor)
    gpu.setBackground(bgColor)
    for row = y, y + h - 1 do
        gpu.set(x, row, string.rep(" ", w))
    end

    gpu.setForeground(borderColor)
    gpu.setBackground(COLOR_BG)
    gpu.set(x, y, "┌" .. string.rep("─", w - 2) .. "┐")
    gpu.set(x, y + h - 1, "└" .. string.rep("─", w - 2) .. "┘")
    for row = y + 1, y + h - 2 do
        gpu.set(x, row, "│")
        gpu.set(x + w - 1, row, "│")
    end
end

local function centerText(text, y, color)
    local x = math.floor((screenW - #text) / 2) + 1
    gpu.setForeground(color or COLOR_TEXT)
    gpu.setBackground(COLOR_BG)
    gpu.set(x, y, text)
end

local function drawHeader()
    gpu.setBackground(COLOR_BG)
    gpu.fill(1, 1, screenW, screenH, " ")

    drawBox(1, 1, screenW, 3, COLOR_BORDER, COLOR_BG)
    centerText("OpenCasino", 2, COLOR_WHITE)

    centerText("Инфа о выигрышах:", 5, COLOR_TEXT)
    centerText("Выигрыш = ставка * на бонус", 6, COLOR_TEXT_DIM)
end

-- Порядок и подписи предметов для таблицы триплетов (по возрастанию бонуса, как на референсе)
local TRIPLE_BONUS_ORDER = {
    {id = "iron",       label = "железа"},
    {id = "gold",       label = "золота"},
    {id = "diamond",    label = "алмаза"},
    {id = "netherstar", label = "звезды ада"},
}

local function drawPayoutTable()
    local y = 8

    centerText("Если 2 одинаковых предмета по краям - Бонус = x" .. EDGE_MATCH_BONUS, y, COLOR_TEXT_DIM)
    y = y + 1
    centerText("Если 2 одинаковых предмета рядом - Бонус = x" .. ADJACENT_MATCH_BONUS, y, COLOR_TEXT_DIM)
    y = y + 2

    for _, item in ipairs(TRIPLE_BONUS_ORDER) do
        local bonus = TRIPLE_BONUS[item.id] or 0
        centerText("Три " .. item.label .. " - Бонус = x" .. bonus, y, COLOR_TEXT_DIM)
        y = y + 1
    end

    y = y + 1
    centerText("Минимальная ставка: " .. MIN_BET .. "$", y, COLOR_TEXT)
    y = y + 1
    centerText("Максимальная ставка: " .. MAX_BET .. "$", y, COLOR_TEXT)
end

local function clearSlotInterior(x)
    gpu.setBackground(COLOR_SLOT_BG)
    for row = SLOT_Y + 1, SLOT_Y + SLOT_SIZE - 2 do
        gpu.set(x + 1, row, string.rep(" ", SLOT_SIZE - 2))
    end
end

local function drawSlotFrame(x)
    gpu.setForeground(COLOR_SLOT_BORDER)
    gpu.setBackground(COLOR_BG)
    gpu.set(x, SLOT_Y, "┌" .. string.rep("─", SLOT_SIZE - 2) .. "┐")
    gpu.set(x, SLOT_Y + SLOT_SIZE - 1, "└" .. string.rep("─", SLOT_SIZE - 2) .. "┘")
    for row = SLOT_Y + 1, SLOT_Y + SLOT_SIZE - 2 do
        gpu.set(x, row, "│")
        gpu.set(x + SLOT_SIZE - 1, row, "│")
    end
end

-- Рисует предмет точно по центру слота (целиком, без скролла/обрезки),
-- РИСУЯ напрямую на экран. Используется для статичного отображения вне анимации.
local function drawIconCentered(x, itemId)
    clearSlotInterior(x)
    local pic = itemId and loadedIcons[itemId]
    if pic then
        local picW, picH = image.getWidth(pic), image.getHeight(pic)
        local drawX = x + math.floor((SLOT_SIZE - picW) / 2)
        local drawY = SLOT_Y + math.floor((SLOT_SIZE - picH) / 2)
        image.draw(drawX, drawY, pic)
    end
    drawSlotFrame(x)
end

-- ===================== ДВОЙНАЯ БУФЕРИЗАЦИЯ ДЛЯ АНИМАЦИИ =====================
-- Баг "обрезанной иконки" во время спина возникает потому, что drawIconCentered
-- стирает слот и затем рисует иконку В ДВА ОТДЕЛЬНЫХ ШАГА прямо на экране. При
-- быстрой смене кадров следующий кадр начинает рисоваться раньше, чем GPU успел
-- дорисовать предыдущий - на экране остаётся полупустая иконка.
--
-- Решение: один раз "запекаем" каждый предмет (на фоне слота, целиком) в отдельный
-- невидимый видеобуфер. Во время анимации просто МГНОВЕННО копируем готовый буфер
-- в слот одним вызовом gpu.bitblt - промежуточного "пустого" состояния на экране
-- не возникает в принципе. Если буферы не поддерживаются - откатываемся на прямую
-- отрисовку (drawIconCentered).

local iconBuffers = {}   -- iconBuffers[itemId] = индекс видеобуфера
local buffersReady = false

-- Готовит буфер для одного предмета: фон слота + иконка по центру (без внешней рамки,
-- рамка статична и рисуется один раз на экране отдельно).
local function bakeIconBuffer(itemId)
    if not gpu.allocateBuffer then return nil end
    local innerW = SLOT_SIZE - 2
    local innerH = SLOT_SIZE - 2
    local ok, buf = pcall(gpu.allocateBuffer, innerW, innerH)
    if not ok or not buf then return nil end

    local prev = (gpu.getActiveBuffer and gpu.getActiveBuffer()) or 0
    local drawOk = pcall(function()
        gpu.setActiveBuffer(buf)
        gpu.setBackground(COLOR_SLOT_BG)
        gpu.fill(1, 1, innerW, innerH, " ")
        local pic = loadedIcons[itemId]
        if pic then
            local picW, picH = image.getWidth(pic), image.getHeight(pic)
            local drawX = 1 + math.floor((innerW - picW) / 2)
            local drawY = 1 + math.floor((innerH - picH) / 2)
            image.draw(drawX, drawY, pic)
        end
    end)
    -- Всегда возвращаем активным экранный буфер, даже если что-то пошло не так
    pcall(gpu.setActiveBuffer, prev)
    if not drawOk then
        pcall(gpu.freeBuffer, buf)
        return nil
    end
    return buf
end

local function initIconBuffers()
    iconBuffers = {}
    buffersReady = false
    if not gpu.allocateBuffer then return false end
    for id, _ in pairs(loadedIcons) do
        local buf = bakeIconBuffer(id)
        if buf then
            iconBuffers[id] = buf
        else
            return false  -- не получилось - откатываемся целиком
        end
    end
    buffersReady = true
    return true
end

-- Мгновенно показывает предмет в слоте: копирует готовый буфер в внутреннюю
-- область слота. Если буферов нет - рисует напрямую (с возможным мерцанием).
local function blitIcon(x, itemId)
    if buffersReady and iconBuffers[itemId] then
        local ok = pcall(gpu.bitblt, 0, x + 1, SLOT_Y + 1, SLOT_SIZE - 2, SLOT_SIZE - 2, iconBuffers[itemId], 1, 1)
        if not ok then
            drawIconCentered(x, itemId)
        end
    else
        drawIconCentered(x, itemId)
    end
end

-- Статичная отрисовка (предмет по центру слота) - используется когда не идёт анимация
local function drawSlots(reels)
    for i, x in ipairs(slotPositions) do
        gpu.setBackground(COLOR_SLOT_BG)
        for row = SLOT_Y, SLOT_Y + SLOT_SIZE - 1 do
            gpu.set(x, row, string.rep(" ", SLOT_SIZE))
        end
        local itemId = reels and reels[i]
        drawIconCentered(x, itemId)
    end
end

local gameStatus = "Готов к игре"

local function drawSidebar()
    local x = 2
    local boxH = SLOT_SIZE + SLOT_Y - 4
    drawBox(x, 4, 24, boxH, COLOR_BORDER, COLOR_BG)

    gpu.setForeground(COLOR_TEXT)
    gpu.setBackground(COLOR_BG)
    gpu.set(x + 1, 5, "Общая инфа:")
    gpu.setForeground(COLOR_TEXT_DIM)
    gpu.set(x + 1, 7, "Вы играете на свой")
    gpu.set(x + 1, 8, "страх и риск")
    gpu.set(x + 1, 9, "Эмы не возвращаются")

    gpu.setForeground(COLOR_TEXT)
    gpu.set(x + 1, 11, "Всего истрачено:")
    gpu.setForeground(COLOR_WHITE)
    gpu.set(x + 1, 12, tostring(totalWagered) .. " эм.")

    gpu.setForeground(COLOR_TEXT)
    gpu.set(x + 1, 14, "Всего выиграно:")
    gpu.setForeground(COLOR_WHITE)
    gpu.set(x + 1, 15, tostring(totalWon) .. " эм.")

    gpu.setForeground(COLOR_TEXT)
    gpu.set(x + 1, 18, "Ваш баланс:")
    gpu.setForeground(COLOR_WHITE)
    gpu.set(x + 1, 19, "[ " .. string.format("%.2f", balance) .. " ]")

    gpu.setForeground(COLOR_TEXT_DIM)
    gpu.set(x + 1, boxH + 2, gameStatus)
end

local function drawSpinLine()
    local y = screenH - 4
    centerText("Крутим на " .. currentBet .. "$", y, COLOR_WHITE)
end

local function drawButtons()
    buttons = {}

    local labels = {
        {text = "-10$", delta = -BET_STEP_BIG},
        {text = "-5$",  delta = -BET_STEP_MED},
        {text = "-1$",  delta = -BET_STEP_SMALL},
        {text = "Ставка " .. currentBet .. "$", action = "spin"},
        {text = "+1$",  delta = BET_STEP_SMALL},
        {text = "+5$",  delta = BET_STEP_MED},
        {text = "+10$", delta = BET_STEP_BIG},
    }

    local totalWidth = 0
    local widths = {}
    for _, btn in ipairs(labels) do
        local w = #btn.text + 4
        table.insert(widths, w)
        totalWidth = totalWidth + w + 1
    end
    totalWidth = totalWidth - 1

    local startX = math.floor((screenW - totalWidth) / 2) + 1
    local y = screenH - 3

    local x = startX
    for i, btn in ipairs(labels) do
        local w = widths[i]
        drawBox(x, y, w, 3, COLOR_BUTTON_BORDER, COLOR_BUTTON_BG)
        gpu.setForeground(COLOR_WHITE)
        gpu.setBackground(COLOR_BUTTON_BG)
        local textX = x + math.floor((w - #btn.text) / 2)
        gpu.set(textX, y + 1, btn.text)

        table.insert(buttons, {
            x1 = x, y1 = y, x2 = x + w - 1, y2 = y + 2,
            delta = btn.delta, action = btn.action,
        })

        x = x + w + 1
    end
end

local function fullRedraw(reels)
    drawHeader()
    drawPayoutTable()
    drawSidebar()
    drawSlots(reels)
    drawSpinLine()
    drawButtons()
end

-- ===================== АНИМАЦИЯ ПРОКРУТКИ =====================

-- Механика по референс-видео: НЕТ вертикального скролла/ленты - анимация это
-- быстрая синхронная смена целой иконки на месте. Все ещё не остановленные
-- барабаны показывают ОДНУ И ТУ ЖЕ случайную иконку одновременно, она меняется
-- каждые SWAP_INTERVAL секунд. Барабаны останавливаются по очереди слева-направо:
-- сначала 1-й замирает на своём финальном предмете, затем 2-й и 3-й продолжают
-- мигать синхронно вдвоём, потом 2-й тоже замирает, и 3-й мигает один до конца.

local TOTAL_SPIN_TIME = 2.5    -- секунды на всю анимацию
local REEL_STOP_STAGGER = 0.7  -- сек. задержка остановки между барабанами (1->2->3)
local SWAP_INTERVAL = 0.1      -- сек. между сменами иконки во время прокрутки

local function animateSpin(finalReels)
    -- Время остановки каждого барабана (1-й раньше, 3-й позже, по очереди слева-направо)
    local reelStopTime = {}
    for i = 1, 3 do
        reelStopTime[i] = TOTAL_SPIN_TIME - REEL_STOP_STAGGER * (3 - i)
    end

    local startTime = computer.uptime()
    local finished = {false, false, false}
    local sharedItem = pickRandomItem()

    while not (finished[1] and finished[2] and finished[3]) do
        local now = computer.uptime() - startTime
        sharedItem = pickRandomItem()

        for i, x in ipairs(slotPositions) do
            if not finished[i] then
                if now >= reelStopTime[i] then
                    finished[i] = true
                    blitIcon(x, finalReels[i])   -- остановка на финальном предмете
                else
                    blitIcon(x, sharedItem)        -- продолжает крутиться
                end
            end
        end

        os.sleep(SWAP_INTERVAL)
    end
end

-- ===================== ОБРАБОТКА СТАВКИ =====================

local lastReels = {"iron", "iron", "iron"}

local function getFirstLoadedIconId()
    for id, _ in pairs(ICON_PATHS) do
        if loadedIcons[id] then
            return id
        end
    end
    return nil
end

local function doSpin()
    if balance < currentBet then
        gameStatus = "Недостаточно средств!"
        fullRedraw(lastReels)
        os.sleep(1)
        gameStatus = "Готов к игре"
        fullRedraw(lastReels)
        return
    end

    balance = balance - currentBet
    totalWagered = totalWagered + currentBet
    gameStatus = "Идёт игра..."
    drawSidebar()

    local reels = {pickRandomItem(), pickRandomItem(), pickRandomItem()}

    animateSpin(reels)

    local bonus, winAmount = calculateWin(reels, currentBet)

    balance = balance + winAmount
    totalWon = totalWon + winAmount
    lastReels = reels

    saveBalance()

    gameStatus = "Готов к игре"
    fullRedraw(reels)

    if winAmount > 0 then
        centerText("Выигрыш: " .. winAmount .. " эм. (x" .. bonus .. ")", screenH - 5, 0x55FF55)
    else
        centerText("Не повезло. Попробуй ещё раз!", screenH - 5, COLOR_TEXT_DIM)
    end
end

local function changeBet(delta)
    currentBet = currentBet + delta
    if currentBet < MIN_BET then currentBet = MIN_BET end
    if currentBet > MAX_BET then currentBet = MAX_BET end
    fullRedraw(lastReels)
end

-- ===================== ГЛАВНЫЙ ЦИКЛ =====================

local function findButtonAt(x, y)
    for _, btn in ipairs(buttons) do
        if x >= btn.x1 and x <= btn.x2 and y >= btn.y1 and y <= btn.y2 then
            return btn
        end
    end
    return nil
end

local function main()
    loadBalance()
    loadIcons()

    local maxW, maxH = gpu.maxResolution()
    gpu.setResolution(maxW, maxH)
    screenW, screenH = gpu.getResolution()

    -- Доступная высота под слоты: от конца таблицы выплат до начала зоны кнопок (низ экрана)
    local buttonsTopY = screenH - 4   -- drawSpinLine на screenH-4, кнопки чуть ниже
    local availableForSlots = buttonsTopY - (PAYOUT_TABLE_END_Y + 2)
    SLOT_Y = PAYOUT_TABLE_END_Y + 2
    if availableForSlots < SLOT_SIZE then
        io.stderr:write("Внимание: экран слишком маленький (" .. screenW .. "x" .. screenH ..
            ") для полной раскладки. Нужен экран минимум 45 строк высотой (Tier 3 GPU + многоблочный экран). Иконки будут уменьшены.\n")
        SLOT_SIZE = math.max(8, availableForSlots)
    end

    -- Пересчитываем позиции слотов и кнопок под реальное разрешение
    SLOT_START_X = math.floor(screenW / 2) - math.floor((SLOT_SIZE * 3 + SLOT_GAP * 2) / 2)
    slotPositions = {
        SLOT_START_X,
        SLOT_START_X + SLOT_SIZE + SLOT_GAP,
        SLOT_START_X + (SLOT_SIZE + SLOT_GAP) * 2,
    }

    -- Запекаем иконки в видеобуферы для мгновенной отрисовки во время анимации
    -- (устраняет баг обрезанных иконок при быстрой смене кадров).
    if not initIconBuffers() then
        io.stderr:write("Внимание: видеобуферы недоступны - анимация рисуется напрямую " ..
            "(возможно лёгкое мерцание иконок при спине).\n")
    end

    -- Если какая-то из иконок не загрузилась - подстрахуемся реально загруженной
    if not loadedIcons[lastReels[1]] then
        local fallback = getFirstLoadedIconId()
        if fallback then
            lastReels = {fallback, fallback, fallback}
        end
    end

    fullRedraw(lastReels)

    if next(loadErrors) then
        local y = SLOT_Y + SLOT_SIZE + 1
        for id, errMsg in pairs(loadErrors) do
            centerText("Ошибка иконки '" .. id .. "': " .. errMsg, y, 0xFF5555)
            y = y + 1
        end
    end

    while true do
        local eventName, _, x, y = event.pull("touch")

        if eventName == "touch" then
            local btn = findButtonAt(x, y)
            if btn then
                if btn.action == "spin" then
                    doSpin()
                elseif btn.delta then
                    changeBet(btn.delta)
                end
            end
        end

        -- Выход по Ctrl+C / клавише выхода обрабатывается стандартным прерыванием OpenOS
    end
end

local ok, err = pcall(main)
if not ok then
    saveBalance()
    io.stderr:write("Casino crashed: " .. tostring(err) .. "\n")
end
