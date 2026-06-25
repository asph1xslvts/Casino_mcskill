-- diag.lua - диагностика транспозера и монет для казино.
-- Запусти на компьютере казино: покажет, что транспозер видит на каждой стороне,
-- и точные label/name предметов (чтобы сверить имя монеты).

local component = require("component")

print("=== ДИАГНОСТИКА ТРАНСПОЗЕРА ===\n")

if not component.isAvailable("transposer") then
    print("ОШИБКА: транспозер не подключён к компьютеру!")
    print("Проверь, что транспозер примыкает к корпусу/кабелю.")
    return
end

local t = component.transposer
local sideNames = {[0]="низ(0)", [1]="верх(1)", [2]="север(2)",
                   [3]="юг(3)", [4]="запад(4)", [5]="восток(5)"}

for side = 0, 5 do
    local ok, size = pcall(t.getInventorySize, side)
    if ok and size and size > 0 then
        print("--- Сторона " .. sideNames[side] .. ": инвентарь на " .. size .. " слотов ---")
        local foundAny = false
        for slot = 1, size do
            local okk, stack = pcall(t.getStackInSlot, side, slot)
            if okk and stack then
                foundAny = true
                print(string.format("  слот %d: x%s", slot, tostring(stack.size)))
                print("    label = [" .. tostring(stack.label) .. "]")
                print("    name  = [" .. tostring(stack.name) .. "]")
            end
        end
        if not foundAny then
            print("  (пусто)")
        end
    else
        print("--- Сторона " .. sideNames[side] .. ": инвентаря нет ---")
    end
    print("")
end

print("=== КОНЕЦ ===")
print("Сравни label монеты выше с coinLabel в настройках.")
print("Запомни номер стороны, где лежат твои монеты (это depositSide).")
