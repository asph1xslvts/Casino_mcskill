-- ===================================================================
-- testeco.lua - тест экономики казино БЕЗ интерфейса.
-- Проверяет: чтение монет в сети, детект внесения, выдачу.
-- Управление: цифры в консоли.
-- ===================================================================

local economy = require("economy")
local term = require("term")
local event = require("event")

print("=== ТЕСТ ЭКОНОМИКИ ===")
local ok, err = economy.setup()
if not ok then
    print("ОШИБКА setup: " .. tostring(err))
    return
end
print("setup OK. Железо найдено.")
print("Монет 'каз' в сети сейчас: " .. economy.getCoinsInNetwork())
print("Стартовый баланс: " .. economy.getBalance())
print("")
print("--- КОМАНДЫ ---")
print("  d  - проверить депозит (брось монеты в вакуумный сундук, потом нажми d)")
print("  b  - снять ставку 1 (тест списания)")
print("  w5 - выдать 5 монет в сундук выдачи (тест редстоуна/шины)")
print("  s  - показать статус (баланс, монеты в сети)")
print("  q  - выход")
print("")

local function status()
    print("  баланс=" .. economy.getBalance()
        .. "  монет в сети=" .. economy.getCoinsInNetwork()
        .. "  ставок=" .. economy.getTotalWagered()
        .. "  выиграно=" .. economy.getTotalWon())
end

while true do
    io.write("> ")
    local cmd = io.read()
    if not cmd then break end
    cmd = cmd:gsub("%s+", "")

    if cmd == "q" then
        break

    elseif cmd == "d" then
        local added = economy.update()
        if added > 0 then
            print("  ВНЕСЕНО: +" .. added .. " монет. Баланс: " .. economy.getBalance())
        else
            print("  новых монет не обнаружено")
        end

    elseif cmd == "b" then
        if economy.bet(1) then
            print("  ставка 1 снята. Баланс: " .. economy.getBalance())
        else
            print("  не хватает баланса для ставки")
        end

    elseif cmd == "s" then
        status()

    elseif cmd:sub(1,1) == "w" then
        local n = tonumber(cmd:sub(2))
        if n and n > 0 then
            print("  выдаю " .. n .. " монет... (включаю редстоун)")
            local delivered = economy.withdraw(n)
            print("  ВЫДАНО: " .. delivered .. " монет в сундук. Баланс: " .. economy.getBalance())
        else
            print("  формат: w5 (выдать 5)")
        end

    else
        print("  неизвестная команда")
    end
end

economy.shutdown()
print("тест завершён, редстоун выключен")
