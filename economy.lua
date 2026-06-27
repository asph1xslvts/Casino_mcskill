-- economy.lua - ekonomika kazino cherez ME-set (moneta kaz)
-- Vydacha: setInterfaceConfiguration + pushItem UP (proverennaya rabochaya svyazka)

local component = require("component")
local computer  = require("computer")

local economy = {}

-- ===== KONFIG =====
local COIN_NAME  = "IC2:itemCoin"
local COIN_LABEL = "каз"  -- imya nashey monety
local IFACE_SLOT = 1
local DB_SLOT    = 1
local PUSH_DIR   = "up"  -- VAZHNO: strochnymi! "UP" ne rabotal — pushItem tiho ignoriroval nevalidnuyu storonu
local FILL_TIMEOUT = 2  -- pauza (sek) chtoby set uspela dovezti monety v slot interfeysa

-- ===== SOSTOYANIE =====
local meController, meInterface, database
local balance, totalWagered, totalWon = 0, 0, 0
local knownCoins = 0
local busy = false
local dbReady = false

-- ===== CHTENIE SETI =====
local function countCoins()
    if not meController then return 0 end
    local ok, items = pcall(meController.getItemsInNetwork, {name = COIN_NAME})
    if not ok or type(items) ~= "table" then return 0 end
    for _, it in ipairs(items) do
        if it.label == COIN_LABEL then return it.size or 0 end
    end
    return 0
end

-- ===== SOHRANENIE OBRAZCA MONETY V BAZU =====
local function prepareSample()
    if not (meInterface and database) then return false end
    pcall(meInterface.store, {name = COIN_NAME, label = COIN_LABEL}, database.address, DB_SLOT, 1)
    local got
    pcall(function() got = database.get(DB_SLOT) end)
    if got and got.label == COIN_LABEL then return true end
    pcall(database.clear, DB_SLOT)
    pcall(meInterface.store, {name = COIN_NAME}, database.address, DB_SLOT, 1)
    pcall(function() got = database.get(DB_SLOT) end)
    return got ~= nil and got.label == COIN_LABEL
end

-- ===== SETUP =====
function economy.setup()
    meController = component.isAvailable("me_controller") and component.me_controller or nil
    meInterface  = component.isAvailable("me_interface")  and component.me_interface  or nil
    database     = component.isAvailable("database")      and component.database      or nil
    if not meController then return false, "ME Controller ne nayden" end
    if not meInterface  then return false, "ME Interface ne nayden" end
    if not database     then return false, "Database ne naydena" end
    pcall(meInterface.setInterfaceConfiguration, IFACE_SLOT)
    dbReady = prepareSample()
    if not dbReady then return false, "Obrazec kaz ne sohranen (polozhi kaz v set)" end
    knownCoins = countCoins()
    return true
end

-- ===== GETTERY =====
function economy.getBalance()        return balance end
function economy.getTotalWagered()   return totalWagered end
function economy.getTotalWon()       return totalWon end
function economy.isBusy()            return busy end
function economy.getCoinsInNetwork() return countCoins() end

-- ===== VNESENIE =====
function economy.update()
    if busy or not meController then return 0 end
    local cur = countCoins()
    if cur > knownCoins then
        local added = cur - knownCoins
        balance = balance + added
        knownCoins = cur
        return added
    elseif cur < knownCoins then
        knownCoins = cur
    end
    return 0
end

-- ===== STAVKA / VYIGRYSH =====
function economy.bet(amount)
    if busy or amount <= 0 or balance < amount then return false end
    balance = balance - amount
    totalWagered = totalWagered + amount
    return true
end

function economy.addWin(amount)
    if amount and amount > 0 then
        balance = balance + amount
        totalWon = totalWon + amount
    end
end

-- ===== VYDACHA =====
-- VAZHNO: ranshe zdes byla proverka cherez getStackInSlot(), no etot metod
-- u tvoego me_interface vsegda vozvrashchal nil (podtverzhdeno diagnostikoy),
-- poetomu inSlot vsegda byl 0 i toPush vsegda byl 0 -> moved vsegda 0.
-- Teper prosto zhdem fixed FILL_TIMEOUT (sety dostatochno dlya nebolshih
-- kolichestv) i tolkaem napryamuyu na "target", doveryaya setInterfaceConfiguration.
function economy.withdraw(count)
    if not (meInterface and database) then return 0 end
    if not count or count <= 0 then return 0 end
    busy = true

    local available = countCoins()
    if available <= 0 then busy = false; return 0 end
    local target = math.min(count, available)
    if target > 64 then target = 64 end

    -- 1. nastraivaem slot na rovno "target" shtuk
    meInterface.setInterfaceConfiguration(IFACE_SLOT, database.address, DB_SLOT, target)

    -- 2. pauza, chtoby set uspela dovezti monety v slot interfeysa
    os.sleep(FILL_TIMEOUT)

    -- 3. tolkaem v sunduk sverhu rovno "target" (pushItem sam vozvratit
    --    realnoe peremeschennoe kolichestvo, esli v slote bylo menshe)
    local moved = meInterface.pushItem(PUSH_DIR, IFACE_SLOT, target)
    if type(moved) ~= "number" then moved = 0 end

    -- 4. sbros konfiguratsii slota
    meInterface.setInterfaceConfiguration(IFACE_SLOT)

    knownCoins = countCoins()
    if moved > balance then moved = balance end
    balance = balance - moved
    busy = false
    return moved
end

function economy.shutdown()
    if meInterface then pcall(meInterface.setInterfaceConfiguration, IFACE_SLOT) end
end

return economy
