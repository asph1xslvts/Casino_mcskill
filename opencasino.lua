-- ===================================================================
-- CRYSTAL CASINO - слот-машина для OpenComputers (NEON, DoubleBuffering)
-- Тонкие Unicode-рамки, экран логина + основное меню.
-- Иконки: алмаз (diamond), звезда ада (netherstar), золото (gold)
-- ===================================================================

local component = require("component")
local computer = require("computer")
local event = require("event")
local image = require("image")
local fs = require("filesystem")
local buffer = require("doubleBuffering")
local unicode = require("unicode")
local economy = require("economy")

-- ===================== НАСТРОЙКИ =====================

local MIN_BET = 1
local MAX_BET = 10
local BET_STEP_SMALL = 1
local BET_STEP_MED = 5
local BET_STEP_BIG = 10

local START_BALANCE = 1000

local ICON_PATHS = {
    diamond    = "/home/icons/diamond.pic",
    netherstar = "/home/icons/netherstar.pic",
    gold       = "/home/icons/gold.pic",
}

local TRIPLE_BONUS = {
    gold       = 25,
    diamond    = 40,
    netherstar = 100,
}

local EDGE_MATCH_BONUS = 1
local ADJACENT_MATCH_BONUS = 2

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

-- ===================== ПАЛИТРА =====================

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
local COLOR_LOGO        = 0x00F0FF

-- ===================== СОСТОЯНИЕ =====================

-- Текущий игрок сессии (ник того, кто залогинился). Баланс личный, по нику.
local currentPlayer = nil

-- Баланс текущего игрока (из economy, по его нику)
local function getBalance() return economy.getBalance(currentPlayer) end

local currentBet   = MIN_BET
local gameStatus   = nil   -- строка под слотами: "Идёт игра...", выигрыш, проигрыш
local statusColor  = COLOR_TEXT_DIM
local hasHardware  = false -- найдено ли ME-железо
local hwError      = nil   -- текст ошибки железа, если есть

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

local function ulen(s) return unicode.len(s) end

-- ===================== РАМКИ (тонкие Unicode) =====================

local function box(x, y, w, h, color, bg)
    if bg then
        buffer.drawRectangle(x, y, w, h, bg, color, " ")
    end
    buffer.drawText(x, y, color, "┌" .. string.rep("─", w - 2) .. "┐")
    buffer.drawText(x, y + h - 1, color, "└" .. string.rep("─", w - 2) .. "┘")
    for row = y + 1, y + h - 2 do
        buffer.drawText(x, row, color, "│")
        buffer.drawText(x + w - 1, row, color, "│")
    end
end

local function centerText(y, color, text)
    local x = math.floor((screenW - ulen(text)) / 2) + 1
    buffer.drawText(x, y, color, text)
end

-- ===================== ЗАГРУЗКА ИКОНОК =====================

local function loadIcons()
    for id, path in pairs(ICON_PATHS) do
        if fs.exists(path) then
            local pic, err = image.load(path)
            if pic then loadedIcons[id] = pic else loadErrors[id] = tostring(err) end
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
    if a == b or b == c then return ADJACENT_MATCH_BONUS, bet * ADJACENT_MATCH_BONUS end
    if a == c then return EDGE_MATCH_BONUS, bet * EDGE_MATCH_BONUS end
    return 0, 0
end

-- ===================== СЛОТЫ =====================

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
    box(x, SLOT_Y, SLOT_W, SLOT_H, COLOR_SLOT_BORDER, nil)
end

local function drawSlots(reels)
    for i, x in ipairs(slotPositions) do
        drawSlot(x, reels and reels[i])
    end
end

-- ===================== ЭКРАН ЛОГИНА =====================

local loginButton = nil
local withdrawButton = nil

local function renderLogin()
    buffer.clear(COLOR_BG)
    box(1, 1, screenW, screenH, COLOR_BORDER, COLOR_BG)

    -- Название по центру (крупный акцент: две строки)
    local midY = math.floor(screenH / 2) - 4
    centerText(midY,     COLOR_LOGO,  "C R Y S T A L")
    centerText(midY + 2, COLOR_TITLE, "C A S I N O")

    -- Кнопка "Залогиниться" по центру
    local btnText = "Залогиниться"
    local bw = ulen(btnText) + 8
    local bx = math.floor((screenW - bw) / 2) + 1
    local by = midY + 6
    box(bx, by, bw, 3, COLOR_BET, COLOR_BTN_BG)
    buffer.drawText(bx + math.floor((bw - ulen(btnText)) / 2), by + 1, COLOR_BET, btnText)
    loginButton = {x1 = bx, y1 = by, x2 = bx + bw - 1, y2 = by + 2}

    -- автор справа снизу
    local author = "автор: st1amz"
    buffer.drawText(screenW - ulen(author) - 2, screenH - 2, COLOR_TEXT_DIM, author)

    buffer.drawChanges()
end

-- ===================== ОСНОВНОЕ МЕНЮ =====================

local function drawHeader()
    buffer.clear(COLOR_BG)
    box(1, 1, screenW, 3, COLOR_BORDER, COLOR_BG)
    centerText(2, COLOR_TITLE, "CRYSTAL CASINO")
end

local function drawSidebar()
    local x = 2
    box(x, 5, 24, 7, COLOR_BORDER, COLOR_BG)
    buffer.drawText(x + 2, 6, COLOR_TEXT_DIM, "Игрок:")
    buffer.drawText(x + 2, 7, COLOR_TEXT, currentPlayer and tostring(currentPlayer) or "---")
    buffer.drawText(x + 2, 9, COLOR_TEXT_DIM, "Играй на свой страх")
    buffer.drawText(x + 2, 10, COLOR_BET,     "и риск. Удачи!")

    -- баланс отдельной панелью
    box(x, 13, 24, 5, COLOR_BORDER, COLOR_BG)
    buffer.drawText(x + 2, 14, COLOR_TEXT, "Баланс:")
    buffer.drawText(x + 2, 15, COLOR_MONEY, "[ " .. getBalance() .. " каз ]")
    if not hasHardware then
        buffer.drawText(x + 2, 17, COLOR_LOSE, "ME не найден!")
    end

    -- кнопка Вывести
    box(x, 19, 24, 3, COLOR_BTN_BORDER, COLOR_BTN_BG)
    buffer.drawText(x + 8, 20, COLOR_WHITE, "Вывести")
    withdrawButton = {x1 = x, y1 = 19, x2 = x + 23, y2 = 21}
end

local function drawPayoutTable()
    local y = 6
    centerText(y, COLOR_TEXT_DIM, "Выигрыш = ставка * на бонус"); y = y + 2
    centerText(y, COLOR_TEXT_DIM, "2 одинаковых по краям = x" .. EDGE_MATCH_BONUS); y = y + 1
    centerText(y, COLOR_TEXT_DIM, "2 одинаковых рядом = x" .. ADJACENT_MATCH_BONUS); y = y + 2
    for _, it in ipairs(TRIPLE_BONUS_ORDER) do
        centerText(y, COLOR_MONEY, "Три " .. it.label .. " = x" .. (TRIPLE_BONUS[it.id] or 0)); y = y + 1
    end
end

local function drawStatusLine()
    if gameStatus then
        centerText(SLOT_Y + SLOT_H + 2, statusColor, gameStatus)
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
        box(x, y, w, 3, borderCol, COLOR_BTN_BG)
        buffer.drawText(x + math.floor((w - ulen(b.text)) / 2), y + 1, textCol, b.text)
        buttons[#buttons + 1] = {x1 = x, y1 = y, x2 = x + w - 1, y2 = y + 2, delta = b.delta, action = b.action}
        x = x + w + 1
    end
end

local function render(reels)
    drawHeader()
    drawSidebar()
    drawPayoutTable()
    drawSlots(reels)
    drawStatusLine()
    drawButtons()
    buffer.drawChanges()
end

local function renderSlotsOnly(reels)
    drawSlots(reels)
    -- статус под слотами перерисовываем тоже (фон уже на месте)
    buffer.drawRectangle(2, SLOT_Y + SLOT_H + 2, screenW - 2, 1, COLOR_BG, COLOR_WHITE, " ")
    drawStatusLine()
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
    -- ставка списывается с личного баланса игрока
    if not economy.bet(currentPlayer, currentBet) then
        gameStatus = "Мало средств!"
        statusColor = COLOR_LOSE
        render(lastReels)
        os.sleep(1)
        gameStatus = nil
        render(lastReels)
        return
    end

    gameStatus = "Идёт игра..."
    statusColor = COLOR_BET
    render(lastReels)

    local reels = {pickRandomItem(), pickRandomItem(), pickRandomItem()}
    animateSpin(reels)

    local bonus, win = calculateWin(reels, currentBet)
    if win > 0 then
        economy.addWin(currentPlayer, win)
        gameStatus = "ВЫИГРЫШ: " .. win .. " каз (x" .. bonus .. ")"
        statusColor = COLOR_MONEY
    else
        gameStatus = "Не повезло. Попробуй ещё раз!"
        statusColor = COLOR_LOSE
    end
    lastReels = reels
    render(reels)
end

local function changeBet(delta)
    currentBet = currentBet + delta
    if currentBet < MIN_BET then currentBet = MIN_BET end
    if currentBet > MAX_BET then currentBet = MAX_BET end
    render(lastReels)
end

-- ===================== ЦИКЛЫ =====================

local function findButtonAt(x, y)
    for _, b in ipairs(buttons) do
        if x >= b.x1 and x <= b.x2 and y >= b.y1 and y <= b.y2 then return b end
    end
    return nil
end

-- Ввод суммы вывода: показывает поле, игрок набирает цифры на клавиатуре.
-- Enter - подтвердить, Backspace - стереть, Esc - отмена. Возвращает число или nil.
local function askWithdrawAmount()
    local entered = ""
    local function drawPrompt()
        local bw, bh = 40, 7
        local bx = math.floor((screenW - bw) / 2) + 1
        local by = math.floor((screenH - bh) / 2)
        box(bx, by, bw, bh, COLOR_BET, COLOR_BG)
        centerText(by + 1, COLOR_TEXT, "Сколько вывести? (макс " .. getBalance() .. ")")
        centerText(by + 3, COLOR_MONEY, "> " .. entered .. "_")
        centerText(by + 5, COLOR_TEXT_DIM, "Enter - ок, Esc - отмена")
        buffer.drawChanges()
    end
    drawPrompt()
    while true do
        local ev = {event.pull()}
        local name = ev[1]
        if name == "key_down" then
            local char = ev[3]   -- код символа
            local code = ev[4]   -- код клавиши
            if code == 28 then        -- Enter
                local n = tonumber(entered)
                return n
            elseif code == 1 then     -- Esc
                return nil
            elseif code == 14 then    -- Backspace
                entered = entered:sub(1, -2)
                drawPrompt()
            elseif char >= 48 and char <= 57 then  -- цифры 0-9
                if #entered < 9 then
                    entered = entered .. string.char(char)
                    drawPrompt()
                end
            end
        end
    end
end

-- Обработка нажатия "Вывести". clickerNick - ник того, кто кликнул.
local function handleWithdraw(clickerNick)
    -- защита: вывести может только сам игрок сессии (свой баланс)
    if clickerNick ~= currentPlayer then
        gameStatus = "Доступ запрещён: это не ваш баланс"
        statusColor = COLOR_LOSE
        render(lastReels)
        os.sleep(2)
        gameStatus = nil
        render(lastReels)
        return
    end

    if getBalance() <= 0 then
        gameStatus = "Баланс пуст"
        statusColor = COLOR_LOSE
        render(lastReels)
        os.sleep(1.5)
        gameStatus = nil
        render(lastReels)
        return
    end

    local amount = askWithdrawAmount()
    if not amount or amount <= 0 then
        render(lastReels)   -- отмена - просто перерисовать
        return
    end
    if amount > getBalance() then
        amount = getBalance()
    end

    gameStatus = "Выдаю " .. amount .. " каз..."
    statusColor = COLOR_BET
    render(lastReels)

    local given = economy.withdraw(currentPlayer, amount)
    if given > 0 then
        gameStatus = "Выдано " .. given .. " каз в сундук!"
        statusColor = COLOR_MONEY
    else
        gameStatus = "Не удалось выдать (нет монет в сети?)"
        statusColor = COLOR_LOSE
    end
    render(lastReels)
    os.sleep(2)
    gameStatus = nil
    render(lastReels)
end

local function loginLoop()
    gameStatus = nil   -- убрать висящий статус с прошлой сессии
    currentPlayer = nil
    renderLogin()
    while true do
        -- 6-й параметр touch = ник кликнувшего
        local ev, _, x, y, _, nick = event.pull("touch")
        if ev == "touch" and loginButton then
            if x >= loginButton.x1 and x <= loginButton.x2 and y >= loginButton.y1 and y <= loginButton.y2 then
                currentPlayer = nick or "Игрок"   -- запомнили, кто вошёл
                return
            end
        end
    end
end

local IDLE_TIMEOUT = 60   -- секунд бездействия до возврата на экран логина

local function gameLoop()
    render(lastReels)
    if next(loadErrors) then
        local y = SLOT_Y + SLOT_H + 4
        for id, err in pairs(loadErrors) do
            centerText(y, COLOR_LOSE, "Ошибка иконки '" .. id .. "': " .. err)
            y = y + 1
        end
        buffer.drawChanges()
    end
    local lastActivity = computer.uptime()
    local lastDepositCheck = computer.uptime()
    while true do
        -- ждём касание не дольше, чем осталось до таймаута
        local remaining = IDLE_TIMEOUT - (computer.uptime() - lastActivity)
        if remaining <= 0 then
            economy.shutdown()   -- сохранить балансы при выходе
            return   -- минута без действий -> назад на логин
        end
        -- проверяем внесение монет не реже раза в секунду (короткий таймаут ожидания)
        local waitTime = remaining
        if waitTime > 1 then waitTime = 1 end

        local ev, _, x, y, _, nick = event.pull(waitTime, "touch")
        if ev == "touch" then
            lastActivity = computer.uptime()
            -- кнопка Вывести (в сайдбаре)
            if withdrawButton and x >= withdrawButton.x1 and x <= withdrawButton.x2
               and y >= withdrawButton.y1 and y <= withdrawButton.y2 then
                handleWithdraw(nick)
                lastActivity = computer.uptime()
            else
                local b = findButtonAt(x, y)
                if b then
                    if b.action == "spin" then doSpin()
                    elseif b.delta then changeBet(b.delta) end
                    lastActivity = computer.uptime()
                end
            end
        end

        -- проверка внесённых монет (зачисляем текущему игроку)
        if hasHardware and (computer.uptime() - lastDepositCheck) >= 1 then
            lastDepositCheck = computer.uptime()
            local added = economy.update(currentPlayer)
            if added > 0 then
                gameStatus = "Внесено: +" .. added .. " каз"
                statusColor = COLOR_MONEY
                render(lastReels)
            end
        end
    end
end

local function main()
    loadIcons()
    local gpu = component.gpu
    local maxW, maxH = gpu.maxResolution()
    buffer.setResolution(maxW, maxH)
    screenW, screenH = buffer.getResolution()

    -- инициализация экономики (ME-сеть, балансы)
    local ok, err = economy.setup()
    hasHardware = ok
    if not ok then hwError = err end

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

    while true do
        loginLoop()   -- экран логина (ждёт нажатия "Залогиниться")
        gameLoop()    -- основное меню (по минуте простоя выходит обратно)
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
