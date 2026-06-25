-- diag_ae2.lua - диагностика ME Interface для казино.
-- Покажет: виден ли me_interface компьютеру, и что реально возвращает
-- getItemsInNetwork() - все предметы сети с их label/name/size.

local component = require("component")

print("=== ДИАГНОСТИКА AE2 ===\n")

local count = 0
for addr, ctype in component.list() do
    if ctype == "me_interface" then
        count = count + 1
        print("ME Interface #" .. count .. ": " .. addr)
    end
end
print("Всего me_interface компонентов: " .. count .. "\n")

if count == 0 then
    print("ОШИБКА: компьютер НЕ видит ни одного ME Interface!")
    print("Проверь, что интерфейс физически примыкает к корпусу/кабелю OC.")
    return
end

local mi = component.me_interface

local ok, items = pcall(mi.getItemsInNetwork)
if not ok then
    print("ОШИБКА при вызове getItemsInNetwork: " .. tostring(items))
    return
end

if not items then
    print("getItemsInNetwork вернул nil!")
    return
end

print("getItemsInNetwork вернул " .. #items .. " разных предметов:\n")
for i, item in ipairs(items) do
    print("--- предмет " .. i .. " ---")
    print("  label = [" .. tostring(item.label) .. "]")
    print("  name  = [" .. tostring(item.name) .. "]")
    print("  size  = " .. tostring(item.size))
    print("")
end

if #items == 0 then
    print("Список пуст - либо сеть пуста, либо метод не видит твою монету по")
    print("какой-то причине (например AE2 хранит её по-другому).")
end

print("=== КОНЕЦ ===")
print("Сравни 'label' монеты выше с coinLabel в настройках экономики.")
