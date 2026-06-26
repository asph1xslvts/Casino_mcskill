-- ===================================================================
-- OpenCasino - слот-машина для OpenComputers (NEON EDITION)
-- Версия без экономики и железа: казино доступно всем, баланс в памяти.
-- Иконки: алмаз (diamond), звезда ада (netherstar), золото (gold)
-- ===================================================================

local component = require("component")
local computer = require("computer")
local event = require("event")
local image = require("image")
local fs = require("filesystem")

local gpu = component.gpu

-- ===================== НАСТРОЙКИ =====================

local MIN_BET = 1
local MAX_BET = 10
local BET_STEP_SMALL = 1
local BET_STEP_MED = 5
local BET_STEP_BIG = 10

-- Стартовый баланс. Хранится только в памяти, сбрасывается при перезапуске.
local START_BALANCE = 1000

-- Пути к иконкам - ЗАМЕНИ НА СВОИ ФАЙЛЫ
local ICON_PATHS = {
    diamond    = "/home/icons/diamond.pic",
    netherstar = "/home/icons/netherstar.pic",
    gold       = "/home/icons/gold.pic",
}

-- Множители за 3 одинаковых предмета
local TRIPLE_BONUS = {
    gold       = 25,
    diamond    = 40,
    netherstar = 100,
}

local EDGE_MATCH_BONUS = 1      -- 2 одинаковых по краям (1-й и 3-й слот)
local ADJACENT_MATCH_BONUS = 2  -- 2 одинаковых рядом (1-2 или 2-3)

-- Веса для случайного выбора (чем выше число, тем чаще выпадает)
local ITEM_WEIGHTS = {
    {id = "gold",       weight = 45},
    {id = "diamond",    weight = 35},
    {id = "netherstar", weight = 20},
}

-- ===================== БАЛАНС (в памяти) =====================

local balance      = START_BALANCE
local totalWagered = 0
local totalWon     = 0
local currentBet   = MIN_BET

local function getBalance()      return balance end
local function getTotalWagered() return totalWagered end
local function getTotalWon()     return totalWon end

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

local function calculateWin(reels, bet)
    local a, b, c = reels[1], reels[2], reels[3]

    if a == b and b == c then
        local bonus = TRIPLE_BONUS[a] or 0
        return bonus, bet * bonus
    end

    if a == b or b == c then
        return ADJACENT_MATCH_BONUS, bet * ADJACENT_MATCH_BONUS
    end

    if a == c then
        return EDGE_MATCH_BONUS, bet * EDGE_MATCH_BONUS
    end

    return 0, 0
end

-- ===================== ПАЛИТРА: НЕОН / КИБЕРПАНК =====================

local COLOR_BG            = 0x0A0A12  -- почти чёрный фон
local COLOR_BORDER        = 0xB026FF  -- электро-фиолет: рамки панелей
local COLOR_TEXT          = 0x00F0FF  -- циан: основной текст
local COLOR_TEXT_DIM      = 0x4DD0E1  -- приглушённый циан: вторичный текст
local COLOR_WHITE         = 0xFFFFFF
local COLOR_TITLE         = 0xFF1E8C  -- маджента: заголовки
local COLOR_MONEY         = 0x39FF14  -- кислотно-зелёный: баланс, выигрыш
local COLOR_BET           = 0xFAFF00  -- неон-жёлтый: ставка
local COLOR_LOSE          = 0xFF003C  -- красный: проигрыш / выход
local COLOR_SLOT_BG       = 0x1A0A24  -- подложка слота: тёмный фиолет, сочетается с фоном
local COLOR_SLOT_BORDER   = 0xFF1E8C  -- маджента: рамка слотов
local COLOR_BUTTON_BG     = 0x0A0A12
local COLOR_BUTTON_BORDER = 0x00F0FF  -- циан: рамки кнопок

-- ===================== ИНТЕРФЕЙС / ОТРИСОВКА =====================

local screenW, screenH = gpu.getResolution()

local SLOT_W = 20            
local SLOT_H = 12            
local PAYOUT_TABLE_END_Y = 17
local SLOT_Y = PAYOUT_TABLE_END_Y + 4
local SLOT_GAP = 4
local SLOT_START_X = math.floor(screenW / 2) - math.floor((SLOT_W * 3 + SLOT_GAP * 2) / 2)

local slotPositions = {
    SLOT_START_X,
    SLOT_START_X + SLOT_W + SLOT_GAP,
    SLOT_START_X + (SLOT_W + SLOT_GAP) * 2,
}

local buttons = {}

local function drawBox(x, y, w, h, borderColor, bgColor)
    gpu.setBackground(bgColor)
    for row = y, y + h - 1 do
        gpu.set(x, row, string.rep(" ", w))
    end

    gpu.setForeground(borderColor)
    gpu.setBackground(COLOR_BG)
    gpu.set(x, y, "+" .. string.rep("=", w - 2) .. "+")
    gpu.set(x, y + h - 1, "+" .. string.rep("=", w - 2) .. "+")
    for row = y + 1, y + h - 2 do
        gpu.set(x, row, "|")
        gpu.set(x + w - 1, row, "|")
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
    centerText("/// OPEN CASINO ///", 2, COLOR_TITLE)

    centerText("[ Инфа о выигрышах ]", 5, COLOR_TEXT)
    centerText("Выигрыш = ставка * на бонус", 6, COLOR_TEXT_DIM)
end

local TRIPLE_BONUS_ORDER = {
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
        centerText("Три " .. item.label .. " - Бонус = x" .. bonus, y, COLOR_MONEY)
        y = y + 1
    end

    y = y + 1
    centerText("Минимальная ставка: " .. MIN_BET .. "$", y, COLOR_TEXT)
    y = y + 1
    centerText("Максимальная ставка: " .. MAX_BET .. "$", y, COLOR_TEXT)
end

local function clearSlotInterior(x)
    gpu.setBackground(COLOR_SLOT_BG)
    -- Используем эффективный gpu.fill для очистки внутренностей слота одной операцией
    gpu.fill(x + 1, SLOT_Y + 1, SLOT_W - 2, SLOT_H - 2, " ")
end

local function drawSlotFrame(x)
    gpu.setForeground(COLOR_SLOT_BORDER)
    gpu.setBackground(COLOR_BG)
    gpu.set(x, SLOT_Y, "+" .. string.rep("=", SLOT_W - 2) .. "+")
    gpu.set(x, SLOT_Y + SLOT_H - 1, "+" .. string.rep("=", SLOT_W - 2) .. "+")
    for row = SLOT_Y + 1, SLOT_Y + SLOT_H - 2 do
        gpu.set(x, row, "|")
        gpu.set(x + SLOT_W - 1, row, "|")
    end
end

-- ИСПРАВЛЕНО: Чистая отрисовка без наложений и без обрезания картинок
local function drawIconCentered(x, itemId)
    clearSlotInterior(x) -- Чистим внутренность перед выводом, чтобы иконки не наслаивались
    local pic = itemId and loadedIcons[itemId]
    if pic then
        local picW, picH = image.getWidth(pic), image.getHeight(pic)
        local drawX = x + math.floor((SLOT_W - picW) / 2)
        local drawY = SLOT_Y + math.floor((SLOT_H - math.ceil(picH / 2)) / 2)
        image.draw(drawX, drawY, pic)
    end
    drawSlotFrame(x)
end

-- ===================== ДВОЙНАЯ БУФЕРИЗАЦИЯ ДЛЯ АНИМАЦИИ =====================

local iconBuffers = {}
local compositeBuffer = nil
local compositeX0 = nil
local compositeW = 0
local compositeH = 0
local buffersReady = false

local function bakeIconBuffer(itemId)
    if not gpu.allocateBuffer then return nil end
    local innerW = SLOT_W - 2
    local innerH = SLOT_H - 2
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
            local drawY = 1 + math.floor((innerH - math.ceil(picH / 2)) / 2)
            image.draw(drawX, drawY, pic)
        end
    end)
    pcall(gpu.setActiveBuffer, prev)
    if not drawOk then
        pcall(gpu.freeBuffer, buf)
        return nil
    end
    return buf
end

local function initIconBuffers()
    iconBuffers = {}
    compositeBuffer = nil
    buffersReady = false
    if not gpu.allocateBuffer then return false end

    for id, _ in pairs(loadedIcons) do
        local buf = bakeIconBuffer(id)
        if buf then
            iconBuffers[id] = buf
        else
            return false
        end
    end

    compositeX0 = slotPositions[1] + 1
    local rightInnerEnd = slotPositions[3] + 1 + (SLOT_W - 2) - 1
    compositeW = rightInnerEnd - compositeX0 + 1
    compositeH = SLOT_H - 2
    local ok, cbuf = pcall(gpu.allocateBuffer, compositeW, compositeH)
    if not ok or not cbuf then
        return false
    end
    compositeBuffer = cbuf

    buffersReady = true
    return true
end

local function blitFrame(items)
    if not (buffersReady and compositeBuffer) then
        for i, x in ipairs(slotPositions) do
            drawIconCentered(x, items[i])
        end
        return
    end

    local ok = pcall(function()
        for i = 1, 3 do
            local src = iconBuffers[items[i]]
            if src then
                local destX = (slotPositions[i] + 1) - compositeX0 + 1
                gpu.bitblt(compositeBuffer, destX, 1, SLOT_W - 2, SLOT_H - 2, src, 1, 1)
            end
        end
        gpu.bitblt(0, compositeX0, SLOT_Y + 1, compositeW, compositeH, compositeBuffer, 1, 1)
    end)

    if not ok then
        for i, x in ipairs(slotPositions) do
            drawIconCentered(x, items[i])
        end
    end
end

local function drawSlots(reels)
    for i, x in ipairs(slotPositions) do
        gpu.setBackground(COLOR_SLOT_BG)
        for row = SLOT_Y, SLOT_Y + SLOT_H - 1 do
            gpu.set(x, row, string.rep(" ", SLOT_W))
        end
        local itemId = reels and reels[i]
        drawIconCentered(x, itemId)
    end
end

local gameStatus = "Готов к игре"

local function drawSidebar()
    local x = 2
    local boxH = 20
    drawBox(x, 4, 24, boxH, COLOR_BORDER, COLOR_BG)

    gpu.setForeground(COLOR_TITLE)
    gpu.setBackground(COLOR_BG)
    gpu.set(x + 1, 5, "[ Общая инфа ]")
    gpu.setForeground(COLOR_TEXT_DIM)
    gpu.set(x + 1, 7, "Вы играете на свой")
    gpu.set(x + 1, 8, "страх и риск")
    gpu.set(x + 1, 9, "Удачи!")

    gpu.setForeground(COLOR_TEXT)
    gpu.set(x + 1, 11, "Всего истрачено:")
    gpu.setForeground(COLOR_WHITE)
    gpu.set(x + 1, 12, tostring(getTotalWagered()) .. " $")

    gpu.setForeground(COLOR_TEXT)
    gpu.set(x + 1, 14, "Всего выиграно:")
    gpu.setForeground(COLOR_WHITE)
    gpu.set(x + 1, 15, tostring(getTotalWon()) .. " $")

    gpu.setForeground(COLOR_TEXT)
    gpu.set(x + 1, 18, "Ваш баланс:")
    gpu.setForeground(COLOR_MONEY)
    gpu.set(x + 1, 19, "[ " .. string.format("%.2f", getBalance()) .. " ]")

    gpu.setForeground(COLOR_TEXT_DIM)
    gpu.set(x + 1, boxH + 2, gameStatus)
end

local function drawSpinLine()
    local y = SLOT_Y + SLOT_H + 1
    centerText("Крутим на " .. currentBet .. "$", y, COLOR_BET)
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
        local borderCol = btn.action == "spin" and COLOR_BET or COLOR_BUTTON_BORDER
        local textCol   = btn.action == "spin" and COLOR_BET or COLOR_WHITE
        drawBox(x, y, w, 3, borderCol, COLOR_BUTTON_BG)
        gpu.setForeground(textCol)
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

local TOTAL_SPIN_TIME = 2.4
local REEL_STOP_STAGGER = 0.6
local SWAP_START = 0.06      
local SWAP_END   = 0.18       

local function animateSpin(finalReels)
    local reelStopTime = {}
    for i = 1, 3 do
        reelStopTime[i] = TOTAL_SPIN_TIME - REEL_STOP_STAGGER * (3 - i)
    end

    local startTime = computer.uptime()
    local finished = {false, false, false}
    local frame = {pickRandomItem(), pickRandomItem(), pickRandomItem()}
    local nextSwap = 0          

    while not (finished[1] and finished[2] and finished[3]) do
        local now = computer.uptime() - startTime

        local progress = now / TOTAL_SPIN_TIME
        if progress > 1 then progress = 1 end
        local swapInterval = SWAP_START + (SWAP_END - SWAP_START) * progress

        if now >= nextSwap then
            for i = 1, 3 do
                if now >= reelStopTime[i] then
                    finished[i] = true
                    frame[i] = finalReels[i]
                else
                    frame[i] = pickRandomItem()   
                end
            end
            blitFrame(frame)
            nextSwap = now + swapInterval
        end

        os.sleep(0.02)
    end

    blitFrame(finalReels)
end

-- ===================== ОБРАБОТКА СТАВКИ =====================

local lastReels = {"gold", "gold", "gold"}

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
        gameStatus = "Мало средств!"
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

    if winAmount > 0 then
        balance = balance + winAmount
        totalWon = totalWon + winAmount
    end
    lastReels = reels

    gameStatus = "Готов к игре"
    fullRedraw(reels)

    if winAmount > 0 then
        centerText("ВЫИГРЫШ: " .. winAmount .. " $ (x" .. bonus .. ")", SLOT_Y + SLOT_H + 3, COLOR_MONEY)
    else
        centerText("Не повезло. Попробуй ещё раз!", SLOT_Y + SLOT_H + 3, COLOR_LOSE)
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
    loadIcons()

    local maxW, maxH = gpu.maxResolution()
    gpu.setResolution(maxW, maxH)
    screenW, screenH = gpu.getResolution()

    local buttonsTopY = screenH - 4
    local availableForSlots = buttonsTopY - (PAYOUT_TABLE_END_Y + 2)
    SLOT_Y = PAYOUT_TABLE_END_Y + 4
    if availableForSlots < SLOT_H then
        io.stderr:write("Внимание: экран маленький (" .. screenW .. "x" .. screenH ..
            "). Нужен экран минимум 40 строк (Tier 3 GPU + многоблочный экран).\n")
        SLOT_H = math.max(8, availableForSlots)
    end

    SLOT_START_X = math.floor(screenW / 2) - math.floor((SLOT_W * 3 + SLOT_GAP * 2) / 2)
    slotPositions = {
        SLOT_START_X,
        SLOT_START_X + SLOT_W + SLOT_GAP,
        SLOT_START_X + (SLOT_W + SLOT_GAP) * 2,
    }

    if not initIconBuffers() then
        io.stderr:write("Внимание: видеобуферы недоступны - анимация рисуется напрямую.\n")
    end

    if not loadedIcons[lastReels[1]] then
        local fallback = getFirstLoadedIconId()
        if fallback then
            lastReels = {fallback, fallback, fallback}
        end
    end

    fullRedraw(lastReels)

    if next(loadErrors) then
        local y = SLOT_Y + SLOT_H + 5
        for id, errMsg in pairs(loadErrors) do
            centerText("Ошибка иконки '" .. id .. "': " .. errMsg, y, COLOR_LOSE)
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
    end
end

local ok, err = pcall(main)
if not ok then
    io.stderr:write("Casino crashed: " .. tostring(err) .. "\n")
end
