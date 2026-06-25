-- diag2.lua - углублённая диагностика транспозера

local component = require("component")

print("=== ДИАГНОСТИКА 2 ===\n")

-- Сколько транспозеров вообще видит компьютер?
local count = 0
for addr, ctype in component.list() do
    if ctype == "transposer" then
        count = count + 1
        print("Транспозер #" .. count .. ": " .. addr)
    end
end
print("Всего транспозеров: " .. count .. "\n")

if count == 0 then
    print("Компьютер НЕ видит ни одного транспозера!")
    print("Значит транспозер не подключён к корпусу/кабелю.")
    return
end

local t = component.transposer

-- Покажем все методы, которые есть у транспозера (чтобы убедиться что это он)
print("Методы транспозера:")
for k, v in pairs(t) do
    print("  " .. tostring(k))
end
print("")

-- Пробуем getInventoryName на каждой стороне (показывает имя блока-инвентаря)
print("Имена инвентарей по сторонам:")
for side = 0, 5 do
    local ok, name = pcall(t.getInventoryName, side)
    if ok then
        print("  сторона " .. side .. ": " .. tostring(name))
    else
        print("  сторона " .. side .. ": ОШИБКА " .. tostring(name))
    end
end
print("")

-- Заодно проверим количество жидкостных танков (другой метод) для контроля живости
print("getInventorySize по сторонам:")
for side = 0, 5 do
    local ok, size = pcall(t.getInventorySize, side)
    print("  сторона " .. side .. ": ok=" .. tostring(ok) .. " size=" .. tostring(size))
end

print("\n=== КОНЕЦ ===")
