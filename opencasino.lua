-- ===================================================================
-- OpenCasino - слот-машина для OpenComputers (NEON, DoubleBuffering)
-- Вся отрисовка через библиотеку doubleBuffering (IgorTimofeev) -
-- один буфер, один drawChanges() за кадр => плавная анимация без рваных иконок.
-- Иконки: алмаз (diamond), звезда ада (netherstar), золото (gold)
-- ===================================================================

local component = require("component")
local computer = require("computer")
local event = require("event")
local image = require("image")
local fs = require("filesystem")
local buffer = require("doubleBuffering")
local unicode = require("unicode")

-- ===================== НАСТРОЙКИ =====================

local MIN_BET = 1
local MAX_BET = 10
local BET_STEP_SMALL = 1
local BET_STEP_MED = 5
local BET_STEP_BIG = 10

local START_BALANCE = 1000   -- стартовый баланс в памяти (сброс при перезапуске)

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

local EDGE_MATCH_BONUS = 1      -- 2 одинаковых по краям
local ADJACENT_MATCH_BONUS = 2  -- 2 одинаковых рядом

local ITEM_WEIGHTS = {
    {id = "gold",       weight = 45},
    {id = "diamond",    weight = 35},
    {id = "netherstar", weight = 20},
}

local TRIPLE_BONUS_ORDER = {
    {id = "gold",       label = "золота"},
    {id = "diamond",    label = "алмаза"},
    {id = "netherstar", label = "звезды ада"},
}

-- ===================== ПАЛИТРА: НЕОН =====================

local COLOR_BG          = 0x0A0A12
local COLOR_BORDER      = 0xB026FF
local COLOR_TEXT        = 0x00F0FF
local COLOR_TEXT_DIM    = 0x4DD0E1
local COLOR_WHITE       = 0xFFFFFF
local COLOR_TITLE       = 0xFF1E8C
local COLOR_MONEY       = 0x39FF14
local COLOR_BET         = 0xFAFF00
local COLOR_LOSE        = 0xFF003C
local COLOR_SLOT_BG     = 0x1A0A24
local COLOR_SLOT_BORDER = 0xFF1E8C
local COLOR_BTN_BG      = 0x140A1E
local COLOR_BTN_BORDER  = 0x00F0FF

-- ===================== СОСТОЯНИЕ =====================

local balance      = START_BALANCE
local totalWagered = 0
local totalWon     = 0
local currentBet   = MIN_BET
local gameStatus   = "Готов к игре"
local resultText   = nil

local loadedIcons = {}
local loadErrors = {}

local screenW, screenH = buffer.getResolution()

local SLOT_W = 20
local SLOT_H = 12
local SLOT_GAP = 4
local SLOT_Y = 22
local SLOT_START_X = 1
local slotPositions = {}

local buttons = {}

local function ulen(s)
    return unicode.len(s)
end

-- ===================== ЗАГРУЗКА ИКОНОК =====================

local function loadIcons()
    for id, path in pairs(ICON_PATHS) do
        if fs.exists(path) then
            local pic, err = image.load(path)
            if pic then
                loadedIcons[id] = pic
            else
                loadErrors[id] = tostring(err)
            end
        else
            loadErrors[id] = "файл не найден: " .. path
        end
    end
end

-- ===================== ВЫБОР / ВЫИГРЫШ =====================

local function pickRandomItem()
    local total = 0
    for _, it in ipairs(ITEM_WEIGHTS) do total = total + it.weight end
    local roll = math.random(1, total)
    local cum = 0
    for _, it in ipairs(ITEM_WEIGHTS) do
        cum = cum + it.weight
        if roll <= cum then return it.id end
    end
    return ITEM_WEIGHTS[1].id
end

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

-- ===================== ОТРИСОВКА В БУФЕР =====================

local function centerText(y, color, text)
    local x = math.floor((screenW - ulen(text)) / 2) + 1
    buffer.drawText(x, y, color, text)
end

local function drawFrame(x, y, w, h, borderColor, bgColor)
    buffer.drawRectangle(x, y, w, h, bgColor, borderColor, " ")
    buffer.drawText(x, y, borderColor, "+" .. string.rep("=", w - 2) .. "+")
    buffer.drawText(x, y + h - 1, borderColor, "+" .. string.rep("=", w - 2) .. "+")
    for row = y + 1, y + h - 2 do
        buffer.drawText(x, row, borderColor, "|")
        buffer.drawText(x + w - 1, row, borderColor, "|")
    end
end

local function drawSlot(x, itemId)
    buffer.drawRectangle(x + 1, SLOT_Y + 1, SLOT_W - 2, SLOT_H - 2, COLOR_SLOT_BG, COLOR_WHITE, " ")
    local pic = itemId and loadedIcons[itemId]
    if pic then
        local pw = image.getWidth(pic)
        local ph = image.getHeight(pic)
        local ix = x + 1 + math.floor((SLOT_W - 2 - pw) / 2)
        local iy = SLOT_Y + 1 + math.floor((SLOT_H - 2 - ph) / 2)
        buffer.drawImage(ix, iy, pic)
    end
    buffer.drawText(x, SLOT_Y, COLOR_SLOT_BORDER, "+" .. string.rep("=", SLOT_W - 2) .. "+")
    buffer.drawText(x, SLOT_Y + SLOT_H - 1, COLOR_SLOT_BORDER, "+" .. string.rep("=", SLOT_W - 2) .. "+")
    for row = SLOT_Y + 1, SLOT_Y + SLOT_H - 2 do
        buffer.drawText(x, row, COLOR_SLOT_BORDER, "|")
        buffer.drawText(x + SLOT_W - 1, row, COLOR_SLOT_BORDER, "|")
    end
end

-- ===================== КАДР =====================

local function drawHeader()
    buffer.clear(COLOR_BG)
    drawFrame(1, 1, screenW, 3, COLOR_BORDER, COLOR_BG)
    centerText(2, COLOR_TITLE, "/// OPEN CASINO ///")
    centerText(5, COLOR_TEXT, "[ Инфа о выигрышах ]")
    centerText(6, COLOR_TEXT_DIM, "Выигрыш = ставка * на бонус")
end

local function drawPayoutTable()
    local y = 8
    centerText(y, COLOR_TEXT_DIM, "Если 2 одинаковых предмета по краям - Бонус = x" .. EDGE_MATCH_BONUS); y = y + 1
    centerText(y, COLOR_TEXT_DIM, "Если 2 одинаковых предмета рядом - Бонус = x" .. ADJACENT_MATCH_BONUS); y = y + 2
    for _, it in ipairs(TRIPLE_BONUS_ORDER) do
        centerText(y, COLOR_MONEY, "Три " .. it.label .. " - Бонус = x" .. (TRIPLE_BONUS[it.id] or 0)); y = y + 1
    end
    y = y + 1
    centerText(y, COLOR_TEXT, "Минимальная ставка: " .. MIN_BET .. "$"); y = y + 1
    centerText(y, COLOR_TEXT, "Максимальная ставка: " .. MAX_BET .. "$")
end

local function drawSidebar()
    local x = 2
    drawFrame(x, 4, 24, 20, COLOR_BORDER, COLOR_BG)
    buffer.drawText(x + 1, 5, COLOR_TITLE, "[ Общая инфа ]")
    buffer.drawText(x + 1, 7, COLOR_TEXT_DIM, "Вы играете на свой")
    buffer.drawText(x + 1, 8, COLOR_TEXT_DIM, "страх и риск")
    buffer.drawText(x + 1, 9, COLOR_TEXT_DIM, "Удачи!")
    buffer.drawText(x + 1, 11, COLOR_TEXT, "Всего истрачено:")
    buffer.drawText(x + 1, 12, COLOR_WHITE, tostring(totalWagered) .. " $")
    buffer.drawText(x + 1, 14, COLOR_TEXT, "Всего выиграно:")
    buffer.drawText(x + 1, 15, COLOR_WHITE, tostring(totalWon) .. " $")
    buffer.drawText(x + 1, 18, COLOR_TEXT, "Ваш баланс:")
    buffer.drawText(x + 1, 19, COLOR_MONEY, "[ " .. string.format("%.2f", balance) .. " ]")
    buffer.drawText(x + 1, 22, COLOR_TEXT_DIM, gameStatus)
end

local function drawSlots(reels)
    for i, x in ipairs(slotPositions) do
        drawSlot(x, reels and reels[i])
    end
end

local function drawSpinLine()
    centerText(SLOT_Y + SLOT_H + 1, COLOR_BET, "Крутим на " .. currentBet .. "$")
    if resultText then
        centerText(SLOT_Y + SLOT_H + 3, resultText.color, resultText.text)
    end
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
    local widths, totalWidth = {}, 0
    for _, b in ipairs(labels) do
        local w = ulen(b.text) + 4
        widths[#widths + 1] = w
        totalWidth = totalWidth + w + 1
    end
    totalWidth = totalWidth - 1
    local x = math.floor((screenW - totalWidth) / 2) + 1
    local y = screenH - 3
    for i, b in ipairs(labels) do
        local w = widths[i]
        local borderCol = b.action == "spin" and COLOR_BET or COLOR_BTN_BORDER
        local textCol   = b.action == "spin" and COLOR_BET or COLOR_WHITE
        drawFrame(x, y, w, 3, borderCol, COLOR_BTN_BG)
        local tx = x + math.floor((w - ulen(b.text)) / 2)
        buffer.drawText(tx, y + 1, textCol, b.text)
        buttons[#buttons + 1] = {x1 = x, y1 = y, x2 = x + w - 1, y2 = y + 2, delta = b.delta, action = b.action}
        x = x + w + 1
    end
end

local function render(reels)
    drawHeader()
    drawPayoutTable()
    drawSidebar()
    drawSlots(reels)
    drawSpinLine()
    drawButtons()
    buffer.drawChanges()
end

local function renderSlotsOnly(reels)
    drawSlots(reels)
    buffer.drawChanges()
end

-- ===================== АНИМАЦИЯ =====================

local TOTAL_SPIN_TIME   = 8.0
local REEL_STOP_STAGGER = 1.6
local SWAP_START = 0.05
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
            renderSlotsOnly(frame)
            nextSwap = now + swapInterval
        end

        os.sleep(0)
    end

    renderSlotsOnly(finalReels)
end

-- ===================== ИГРА =====================

local lastReels = {"gold", "gold", "gold"}

local function getFirstLoadedIconId()
    for id in pairs(ICON_PATHS) do
        if loadedIcons[id] then return id end
    end
    return nil
end

local function doSpin()
    if balance < currentBet then
        gameStatus = "Мало средств!"
        resultText = nil
        render(lastReels)
        os.sleep(1)
        gameStatus = "Готов к игре"
        render(lastReels)
        return
    end

    balance = balance - currentBet
    totalWagered = totalWagered + currentBet
    gameStatus = "Идёт игра..."
    resultText = nil
    render(lastReels)

    local reels = {pickRandomItem(), pickRandomItem(), pickRandomItem()}
    animateSpin(reels)

    local bonus, win = calculateWin(reels, currentBet)
    if win > 0 then
        balance = balance + win
        totalWon = totalWon + win
        resultText = {text = "ВЫИГРЫШ: " .. win .. " $ (x" .. bonus .. ")", color = COLOR_MONEY}
    else
        resultText = {text = "Не повезло. Попробуй ещё раз!", color = COLOR_LOSE}
    end
    lastReels = reels
    gameStatus = "Готов к игре"
    render(reels)
end

local function changeBet(delta)
    currentBet = currentBet + delta
    if currentBet < MIN_BET then currentBet = MIN_BET end
    if currentBet > MAX_BET then currentBet = MAX_BET end
    render(lastReels)
end

-- ===================== ГЛАВНЫЙ ЦИКЛ =====================

local function findButtonAt(x, y)
    for _, b in ipairs(buttons) do
        if x >= b.x1 and x <= b.x2 and y >= b.y1 and y <= b.y2 then return b end
    end
    return nil
end

local function main()
    loadIcons()

    local gpu = component.gpu
    local maxW, maxH = gpu.maxResolution()
    buffer.setResolution(maxW, maxH)
    screenW, screenH = buffer.getResolution()

    SLOT_Y = 22
    SLOT_START_X = math.floor(screenW / 2) - math.floor((SLOT_W * 3 + SLOT_GAP * 2) / 2)
    slotPositions = {
        SLOT_START_X,
        SLOT_START_X + SLOT_W + SLOT_GAP,
        SLOT_START_X + (SLOT_W + SLOT_GAP) * 2,
    }

    if not loadedIcons[lastReels[1]] then
        local fb = getFirstLoadedIconId()
        if fb then lastReels = {fb, fb, fb} end
    end

    render(lastReels)

    if next(loadErrors) then
        local y = SLOT_Y + SLOT_H + 5
        for id, err in pairs(loadErrors) do
            centerText(y, COLOR_LOSE, "Ошибка иконки '" .. id .. "': " .. err)
            y = y + 1
        end
        buffer.drawChanges()
    end

    while true do
        local ev, _, x, y = event.pull("touch")
        if ev == "touch" then
            local b = findButtonAt(x, y)
            if b then
                if b.action == "spin" then
                    doSpin()
                elseif b.delta then
                    changeBet(b.delta)
                end
            end
        end
    end
end

local ok, err = pcall(main)
if not ok then
    pcall(function()
        local gpu = component.gpu
        gpu.setBackground(0x000000)
        gpu.setForeground(0xFFFFFF)
        local w, h = gpu.getResolution()
        gpu.fill(1, 1, w, h, " ")
    end)
    io.stderr:write("Casino crashed: " .. tostring(err) .. "\n")
end
