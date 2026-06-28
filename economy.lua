-- economy.lua - ekonomika kazino, lichnye balansy po niku, sohranenie v fail
-- Vydacha: setInterfaceConfiguration + pushItem UP (rabochaya svyazka)

local component = require("component")

local economy = {}

-- ===== KONFIG =====
local COIN_NAME    = "IC2:itemCoin"
local COIN_LABEL   = "каз"
local IFACE_SLOT   = 1
local DB_SLOT      = 1
local PUSH_DIR     = "UP"
local BALANCE_FILE = "/home/balances.dat"

-- ===== ZHELEZO =====
local meController, meInterface, database
local knownCoins = 0
local busy = false
local dbReady = false

-- ===== BALANSY PO NIKU =====
local balances = {}     -- balances[nick] = chislo monet

-- ----- sohranenie/zagruzka balansov -----
local function saveBalances()
    local f = io.open(BALANCE_FILE, "w")
    if not f then return end
    for nick, val in pairs(balances) do
        if val and val > 0 then
            f:write(nick .. "=" .. tostring(val) .. "\n")
        end
    end
    f:close()
end

local function loadBalances()
    balances = {}
    local f = io.open(BALANCE_FILE, "r")
    if not f then return end
    for line in f:lines() do
        local nick, val = line:match("^(.-)=(%d+)%s*$")
        if nick and val then
            balances[nick] = tonumber(val)
        end
    end
    f:close()
end

local function getBal(nick)
    if not nick then return 0 end
    return tonumber(balances[nick]) or 0
end

local function setBal(nick, val)
    if not nick then return end
    balances[nick] = tonumber(val) or 0
    saveBalances()
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

-- ===== OBRAZEC MONETY V BAZU =====
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
    loadBalances()
    knownCoins = countCoins()
    return true
end

-- ===== GETTERY =====
function economy.getBalance(nick)    return getBal(nick) end
function economy.isBusy()            return busy end
function economy.getCoinsInNetwork() return countCoins() end

-- ===== SESSIYA =====
-- Vyzyvat pri vhode igroka. Sinhroniziruet schetchik: vsyo chto bylo DO vhoda
-- ne schitaetsya depozitom.
function economy.startSession()
    knownCoins = countCoins()
end

-- ===== VNESENIE (tolko poka igrok zaloginen) =====
function economy.update(nick)
    if busy or not meController then return 0 end
    if not nick then
        knownCoins = countCoins()   -- vne sessii: sinhron, nichego ne nachislyaem
        return 0
    end
    local cur = countCoins()
    if cur > knownCoins then
        local added = cur - knownCoins
        knownCoins = cur
        setBal(nick, getBal(nick) + added)
        return added
    elseif cur < knownCoins then
        knownCoins = cur
    end
    return 0
end

-- ===== STAVKA / VYIGRYSH (po niku) =====
function economy.bet(nick, amount)
    amount = tonumber(amount) or 0
    if busy or not nick or amount <= 0 then return false end
    if getBal(nick) < amount then return false end
    setBal(nick, getBal(nick) - amount)
    return true
end

function economy.addWin(nick, amount)
    amount = tonumber(amount) or 0
    if nick and amount > 0 then
        setBal(nick, getBal(nick) + amount)
    end
end

-- ===== VYDACHA (spisyvaet s balansa nika, vydaet monety v sunduk) =====
function economy.withdraw(nick, count)
    count = tonumber(count) or 0
    if not (meInterface and database) then return 0 end
    if not nick or count <= 0 then return 0 end
    if getBal(nick) < count then count = getBal(nick) end  -- ne bolshe chem na balanse
    if count <= 0 then return 0 end

    busy = true
    local available = countCoins()
    if available <= 0 then busy = false; return 0 end
    local target = math.min(count, available)
    if target > 64 then target = 64 end

    meInterface.setInterfaceConfiguration(IFACE_SLOT, database.address, DB_SLOT, target)
    os.sleep(2)
    local moved = meInterface.pushItem(PUSH_DIR, IFACE_SLOT, target)
    if type(moved) ~= "number" then moved = 0 end
    meInterface.setInterfaceConfiguration(IFACE_SLOT)

    knownCoins = countCoins()
    if moved > getBal(nick) then moved = getBal(nick) end
    setBal(nick, getBal(nick) - moved)
    busy = false
    return moved
end

function economy.shutdown()
    if meInterface then pcall(meInterface.setInterfaceConfiguration, IFACE_SLOT) end
    saveBalances()
end

return economy
