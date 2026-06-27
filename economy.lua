-- economy.lua - ekonomika kazino cherez ME-set (moneta kaz)
-- Vydacha: setInterfaceConfiguration + pushItem (s podrobnym debug-logom)

local component = require("component")
local computer  = require("computer")

local economy = {}

-- ===== KONFIG =====
local COIN_NAME  = "IC2:itemCoin"
local COIN_LABEL = "каз"  -- imya nashey monety
local IFACE_SLOT = 1
local DB_SLOT    = 1
local PUSH_DIR   = "up"   -- strochnymi! podtverzhdeno diagnostikoy chto rabotaet
local FILL_DELAY = 2      -- pauza (sek) chtoby set uspela dovezti monety v slot interfeysa
local DEBUG      = true   -- vyvodit podrobnyy log kazhdogo shaga withdraw v konsol

-- ===== SOSTOYANIE =====
local meController, meInterface, database
local balance, totalWagered, totalWon = 0, 0, 0
local knownCoins = 0
local busy = false
local dbReady = false

local function log(...)
    if DEBUG then print("[economy]", ...) end
end

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

    log("setup: meController=" .. tostring(meController.address))
    log("setup: meInterface=" .. tostring(meInterface.address))
    log("setup: database=" .. tostring(database.address))

    pcall(meInterface.setInterfaceConfiguration, IFACE_SLOT)
    dbReady = prepareSample()
    log("setup: dbReady=" .. tostring(dbReady))
    if not dbReady then return false, "Obrazec kaz ne sohranen (polozhi kaz v set)" end

    local got = database.get(DB_SLOT)
    if got then
        log("setup: obrazec v DB -> label=" .. tostring(got.label) .. " name=" .. tostring(got.name) .. " hasTag=" .. tostring(got.hasTag))
    end

    knownCoins = countCoins()
    log("setup: knownCoins=" .. knownCoins)
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

-- ===== VYDACHA (s podrobnym logom kazhdogo shaga) =====
function economy.withdraw(count)
    log("withdraw: vyzov s count=" .. tostring(count))

    if not (meInterface and database) then
        log("withdraw: OTKAZ - meInterface ili database otsutstvuet")
        return 0
    end
    if not count or count <= 0 then
        log("withdraw: OTKAZ - nevalidnyy count")
        return 0
    end
    if busy then
        log("withdraw: OTKAZ - busy=true (predыdushchaya operatsiya ne zavershena)")
        return 0
    end

    busy = true

    local available = countCoins()
    log("withdraw: monet v seti dostupno=" .. available)
    if available <= 0 then
        log("withdraw: OTKAZ - 0 monet v seti")
        busy = false
        return 0
    end

    local target = math.min(count, available)
    if target > 64 then target = 64 end
    log("withdraw: target (skolko hotim vydat)=" .. target)

    -- 1. nastraivaem slot interfeysa
    local ok1, err1 = pcall(meInterface.setInterfaceConfiguration, IFACE_SLOT, database.address, DB_SLOT, target)
    log("withdraw: setInterfaceConfiguration ok=" .. tostring(ok1) .. " err=" .. tostring(err1))

    -- 2. pauza, chtoby set uspela dovezti monety v slot interfeysa
    log("withdraw: zhdem " .. FILL_DELAY .. " sek...")
    os.sleep(FILL_DELAY)

    -- 3. tolkaem v sunduk
    local ok2, moved = pcall(meInterface.pushItem, PUSH_DIR, IFACE_SLOT, target)
    log("withdraw: pushItem ok=" .. tostring(ok2) .. " moved=" .. tostring(moved) .. " (dir=" .. PUSH_DIR .. ", slot=" .. IFACE_SLOT .. ", target=" .. target .. ")")

    if not ok2 or type(moved) ~= "number" then
        log("withdraw: pushItem NE vernul chislo, schitaem moved=0")
        moved = 0
    end

    -- 4. sbros konfiguratsii slota
    local ok3, err3 = pcall(meInterface.setInterfaceConfiguration, IFACE_SLOT)
    log("withdraw: sbros konfiguratsii ok=" .. tostring(ok3) .. " err=" .. tostring(err3))

    local afterNet = countCoins()
    log("withdraw: monet v seti POSLE=" .. afterNet .. " (do bylo " .. available .. ", raznitsa=" .. (available - afterNet) .. ")")

    -- esli pushItem vernul 0, no monety iz seti realno ushli (raznitsa > 0),
    -- doveryaem faktu, a ne vozvratu funktsii (byvayut versii OC gde pushItem
    -- vozvrashchaet ne to chislo, no fizicheski predmet peremeshchaet)
    if moved == 0 and (available - afterNet) > 0 then
        log("withdraw: pushItem vernul 0, no monety FIZICHESKI ushli iz seti -> korrektiruem moved")
        moved = available - afterNet
    end

    knownCoins = afterNet
    if moved > balance then moved = balance end
    balance = balance - moved
    busy = false

    log("withdraw: ITOG moved=" .. moved .. " novyy balance=" .. balance)
    return moved
end

function economy.shutdown()
    if meInterface then pcall(meInterface.setInterfaceConfiguration, IFACE_SLOT) end
end

return economy
