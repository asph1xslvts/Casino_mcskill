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

-- === СЕКРЕТНЫЙ ВЫХОД В КОНСОЛЬ (для админа) ===
-- Чтобы выйти в консоль: на ЭКРАНЕ ЛОГИНА кликни по правому нижнему углу
-- (где написано "автор") нужное число раз подряд. Игроки не знают.
local ADMIN_EXIT_CLICKS = 5      -- сколько раз кликнуть по углу для выхода
local ADMIN_NICK = "st1amz"      -- кому разрешён выход (твой ник)


-- ===================================================================
-- ===================================================================
-- ИКОНКИ КАЗИНО (9 штук) - впиши свои id/path/label.
-- weight и triple УЖЕ настроены под RTP ~87% (казино в плюсе на 13%).
-- НЕ меняй weight и triple - они просчитаны математически!
-- Порядок: сверху самые ЧАСТЫЕ/дешёвые, снизу самые РЕДКИЕ/дорогие (джекпот).
--
-- Для каждой иконки замени:
--   id    - короткое латинское имя (например "gold")
--   path  - путь к .pic файлу
--   label - название в родит. падеже для "три ..." (например "золота")
-- ===================================================================
local ICONS = {
    {id = "gold",       path = "/home/icons/gold.pic",       label = "золота",     weight = 28, triple = 10},
    {id = "diamond",    path = "/home/icons/diamond.pic",    label = "алмаза",     weight = 20, triple = 15},
    {id = "netherstar", path = "/home/icons/nether_star.pic", label = "звезды ада", weight = 15, triple = 25},
    {id = "icon4",      path = "/home/icons/crystal_ingot.pic",      label = "кристалл",    weight = 11, triple = 40},
    {id = "icon5",      path = "/home/icons/emerald.pic",      label = "изумруд",    weight = 8,  triple = 75},
    {id = "icon6",      path = "/home/icons/iron_ingot.pic",      label = "железо",    weight = 6,  triple = 120},
    {id = "icon7",      path = "/home/icons/ruby.pic",      label = "рубин",    weight = 5,  triple = 200},
    {id = "icon8",      path = "/home/icons/nitor.pic",      label = "нитор",    weight = 4,  triple = 350},
    {id = "icon9",      path = "/home/icons/ender_eye.pic",      label = "око эндера",    weight = 3,  triple = 750},
}

-- --- из таблицы ICONS автоматически собираются нужные структуры ---
local ICON_PATHS = {}
local TRIPLE_BONUS = {}
local ITEM_WEIGHTS = {}
local TRIPLE_BONUS_ORDER = {}
for _, ic in ipairs(ICONS) do
    ICON_PATHS[ic.id] = ic.path
    TRIPLE_BONUS[ic.id] = ic.triple
    ITEM_WEIGHTS[#ITEM_WEIGHTS + 1] = {id = ic.id, weight = ic.weight}
    TRIPLE_BONUS_ORDER[#TRIPLE_BONUS_ORDER + 1] = {id = ic.id, label = ic.label}
end

-- Выплаты за пары (под RTP ~87%). НЕ менять без пересчёта математики!
-- Пара рядом (2 одинаковых подряд) = возврат ставки x1.
-- Пара по краям = без выплаты (иначе казино уходит в минус).
local EDGE_MATCH_BONUS = 0
local ADJACENT_MATCH_BONUS = 1

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
    -- пара по краям (a==c) не оплачивается - казино в плюсе
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
    -- панель игрока (строки 5-9)
    box(x, 5, 24, 5, COLOR_BORDER, COLOR_BG)
    buffer.drawText(x + 2, 6, COLOR_TEXT_DIM, "Игрок:")
    buffer.drawText(x + 2, 7, COLOR_TEXT, currentPlayer and tostring(currentPlayer) or "---")

    -- предупреждение: страх и риск красным, Удачи жёлтым (отдельная строка)
    box(x, 10, 24, 5, COLOR_BORDER, COLOR_BG)
    buffer.drawText(x + 2, 11, COLOR_LOSE, "Играй на свой")
    buffer.drawText(x + 2, 12, COLOR_LOSE, "страх и риск.")
    buffer.drawText(x + 2, 13, COLOR_BET,  "Удачи!")

    -- баланс
    buffer.drawText(x + 2, 16, COLOR_TEXT_DIM, "Баланс:")
    box(x, 17, 24, 3, COLOR_BORDER, COLOR_BG)
    buffer.drawText(x + 2, 18, COLOR_MONEY, getBalance() .. " каз")

    if not hasHardware then
        buffer.drawText(x + 2, 21, COLOR_LOSE, "ME не найден!")
    end

    -- кнопка Вывести
    box(x, 22, 24, 3, COLOR_BTN_BORDER, COLOR_BTN_BG)
    buffer.drawText(x + 8, 23, COLOR_WHITE, "Вывести")
    withdrawButton = {x1 = x, y1 = 22, x2 = x + 23, y2 = 24}
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

-- Ввод суммы вывода: поле + кнопки ОК/Отмена (клик мышью или клавиатура).
-- Возвращает число (сумма) или nil (отмена).
local function askWithdrawAmount()
    local entered = ""
    local warn = nil   -- предупреждение (например "недостаточно баланса")
    local okBtn, cancelBtn = nil, nil

    local function drawPrompt()
        local bw, bh = 44, 13
        local bx = math.floor((screenW - bw) / 2) + 1
        local by = math.floor((screenH - bh) / 2) - 2   -- чуть выше центра, чтобы не лезть на слоты
        -- сплошная заливка фона окна (чтобы слоты под ним не просвечивали)
        buffer.drawRectangle(bx, by, bw, bh, COLOR_BG, COLOR_BG, " ")
        box(bx, by, bw, bh, COLOR_BET, COLOR_BG)
        centerText(by + 2, COLOR_TEXT, "Сколько вывести?")
        centerText(by + 3, COLOR_TEXT_DIM, "На балансе: " .. getBalance() .. " каз")
        centerText(by + 5, COLOR_MONEY, "> " .. entered .. "_")
        if warn then
            centerText(by + 7, COLOR_LOSE, warn)
        end

        -- кнопки ОК и Отмена внизу окна, с отступом от нижней рамки
        local okText, cancelText = " ОК ", "Отмена"
        local okW, cancelW = ulen(okText) + 2, ulen(cancelText) + 2
        local gap = 6
        local totalW = okW + cancelW + gap
        local startX = bx + math.floor((bw - totalW) / 2)
        local btnY = by + bh - 4   -- на 1 выше нижней рамки

        box(startX, btnY, okW, 3, COLOR_MONEY, COLOR_BTN_BG)
        buffer.drawText(startX + 1, btnY + 1, COLOR_MONEY, okText)
        okBtn = {x1 = startX, y1 = btnY, x2 = startX + okW - 1, y2 = btnY + 2}

        local cx = startX + okW + gap
        box(cx, btnY, cancelW, 3, COLOR_LOSE, COLOR_BTN_BG)
        buffer.drawText(cx + 1, btnY + 1, COLOR_LOSE, cancelText)
        cancelBtn = {x1 = cx, y1 = btnY, x2 = cx + cancelW - 1, y2 = btnY + 2}

        buffer.drawChanges()
    end

    -- проверка введённой суммы; возвращает число или nil + ставит warn
    local function tryConfirm()
        local n = tonumber(entered)
        if not n or n <= 0 then
            warn = "Введите сумму больше 0"
            drawPrompt()
            return nil, false
        end
        if n > getBalance() then
            warn = "Недостаточно баланса!"
            drawPrompt()
            return nil, false
        end
        return n, true
    end

    drawPrompt()
    while true do
        local ev = {event.pull()}
        local name = ev[1]
        if name == "key_down" then
            local char = ev[3]
            local code = ev[4]
            if code == 28 then        -- Enter = подтвердить
                local n, ok = tryConfirm()
                if ok then return n end
            elseif code == 1 then     -- Esc = отмена
                return nil
            elseif code == 14 then    -- Backspace
                entered = entered:sub(1, -2)
                warn = nil
                drawPrompt()
            elseif char >= 48 and char <= 57 then  -- цифры
                if #entered < 9 then
                    entered = entered .. string.char(char)
                    warn = nil
                    drawPrompt()
                end
            end
        elseif name == "touch" then
            local x, y = ev[3], ev[4]
            if okBtn and x >= okBtn.x1 and x <= okBtn.x2 and y >= okBtn.y1 and y <= okBtn.y2 then
                local n, ok = tryConfirm()
                if ok then return n end
            elseif cancelBtn and x >= cancelBtn.x1 and x <= cancelBtn.x2 and y >= cancelBtn.y1 and y <= cancelBtn.y2 then
                return nil
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
        render(lastReels)   -- отмена
        return
    end
    -- сумма уже проверена в окне (не больше баланса), но подстрахуемся
    if amount > getBalance() then amount = getBalance() end

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
    local cornerClicks = 0   -- счётчик кликов по углу для админ-выхода
    while true do
        -- 6-й параметр touch = ник кликнувшего
        local ev, _, x, y, _, nick = event.pull("touch")
        if ev == "touch" then
            -- проверка секретного угла (правый нижний): админ-выход в консоль
            if x >= screenW - 14 and y >= screenH - 2 then
                if nick == ADMIN_NICK then
                    cornerClicks = cornerClicks + 1
                    if cornerClicks >= ADMIN_EXIT_CLICKS then
                        return "admin_exit"   -- сигнал выхода в консоль
                    end
                end
            elseif loginButton and x >= loginButton.x1 and x <= loginButton.x2
                   and y >= loginButton.y1 and y <= loginButton.y2 then
                currentPlayer = nick or "Игрок"
                economy.startSession()
                return
            else
                cornerClicks = 0   -- клик мимо угла - сброс счётчика
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
    -- родное максимальное разрешение экрана (чёткая картинка без растяжения)
    local maxW, maxH = gpu.maxResolution()
    buffer.setResolution(maxW, maxH)
    screenW, screenH = buffer.getResolution()

    -- инициализация экономики (ME-сеть, балансы)
    local ok, err = economy.setup()
    hasHardware = ok
    if not ok then hwError = err end

    -- слоты по центру; SLOT_Y под высоту экрана 50
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
        local res = loginLoop()   -- экран логина (ждёт нажатия "Залогиниться")
        if res == "admin_exit" then
            return "admin_exit"   -- админ запросил выход в консоль
        end
        gameLoop()    -- основное меню (по минуте простоя выходит обратно)
    end
end

-- ===================== ЗАЩИЩЁННЫЙ ЗАПУСК =====================
-- Казино не отпускает в консоль: при любом падении или выходе - автоперезапуск.
-- Исключение: админ-выход (5 кликов по правому нижнему углу на логине).

while true do
    local ok, res = pcall(main)
    -- очистка экрана
    pcall(function()
        local gpu = component.gpu
        gpu.setBackground(0x000000)
        gpu.setForeground(0xFFFFFF)
        local w, h = gpu.getResolution()
        gpu.fill(1, 1, w, h, " ")
    end)
    -- админ запросил выход - выходим в консоль (НЕ перезапускаем)
    if ok and res == "admin_exit" then
        print("Админ-выход. Казино остановлено.")
        break
    end
    -- иначе (падение или обычный выход) - перезапускаем казино
    os.sleep(0.5)
end
