setfenv(1, VoiceOver)

local CURRENT_MODULE_VERSION = 1
local FORCE_ENABLE_DISABLED_MODULES = true
local LOAD_ALL_MODULES = true

---@class DataModuleMetadata
---@field AddonName string Addon name
---@field LoadOnDemand boolean Whether the module can be dynamically loaded (TOC ##LoadOnDemand)
---@field ModuleVersion number Module's data format version (TOC ##X-VoiceOver-DataModule-Version, must be CURRENT_MODULE_VERSION to be loaded)
---@field ModulePriority number Module's priority (TOC ##X-VoiceOver-DataModule-Priority, larger number = higher priority)
---@field ContentVersion? string Module's content version (TOC ##Version)
---@field Title string Module's title (TOC ##Title or addon name if missing)
---@field Maps number[] Map IDs in which the module should load (TOC ##X-VoiceOver-DataModule-Maps)

---@class DataModule
---@field METADATA DataModuleMetadata
---@field GetSoundPath fun(self: DataModule, fileName: string, event: SoundEvent): string Function implemented in the module that returns the sound path for the desired voiceover
---@field GossipLookupByNPCID table<number, table<string, string>> Maps Creature ID and fuzzy-searchable gossip text to gossip text hash
---@field GossipLookupByNPCName table<string, table<string, string>> Maps Creature name and fuzzy-searchable gossip text to gossip text hash
---@field GossipLookupByObjectID table<number, table<string, string>> Maps GameObject ID and fuzzy-searchable gossip text to gossip text hash
---@field GossipLookupByObjectName table<string, table<string, string>> Maps GameObject name and fuzzy-searchable gossip text to gossip text hash
---@field QuestIDLookup table<QuestIDLookupSource, table<string, number|table<string, number|table<string, number>>>> Maps quest title to quest ID or (if there is ambiguity) maps quest title and quest giver name to quest ID or (if there is ambiguity) maps quest title and quest giver name and fuzzy-searchable quest text to quest ID
---@field NPCIDLookupByQuestID table<number, number> Maps Quest ID to quest giver Creature ID
---@field ObjectIDLookupByQuestID table<number, number> Maps Quest ID to quest giver GameObject ID
---@field ItemIDLookupByQuestID table<number, number> Maps Quest ID to quest giver Item ID
---@field NPCNameLookupByNPCID table<number, string> Maps Creature ID to Creature name
---@field ObjectNameLookupByObjectID table<number, string> Maps GameObject ID to GameObject name
---@field ItemNameLookupByItemID table<number, string> Maps Item ID to Item name
---@field SoundLengthLookupByFileName table<string, number> Maps sound filenames to their duration in seconds

---@class AvailableDataModule
---@field AddonName string Addon name
---@field Title string Module's title (TOC ##Title)
---@field ContentVersion string Module's content version (TOC ##Version)
---@field RelevantAboveVersion? number Interface number above which (inclusive) it makes sense to show this module as available to download or update
---@field RelevantBelowVersion? number Interface number below which (exclusive) it makes sense to show this module as available to download or update
---@field URL string URL where the module can be downloaded

DataModules =
{
    --- Store the modules present in Interface\AddOns folder, whether they're loaded or not
    ---@type table<string, DataModuleMetadata>
    presentModules = {},

    --- Stores present modules with a consistent ordering (which key-value hashmaps don't provide) to avoid bugs that can only be reproduced randomly
    ---@type DataModuleMetadata[]
    presentModulesOrdered = {},

    --- Stores the modules that were already loaded and registered
    ---@type table<string, DataModule>
    registeredModules = {},

    --- Stores registered modules with a consistent ordering (which key-value hashmaps don't provide) to avoid bugs that can only be reproduced randomly
    ---@type DataModule[]
    registeredModulesOrdered = {}, -- To have a consistent ordering of modules (which key-value hashmaps don't provide) to avoid bugs that can only be reproduced randomly

    --- Stores modules known to exist to present the player with information on how to download or update them
    ---@type AvailableDataModule[]
    availableModules = {
        {
            AddonName = "AI_VoiceOverData_Vanilla",
            Title = "VoiceOver Data - Vanilla",
            ContentVersion = "0.1",
            RelevantAboveVersion = 0,
            URL = "https://www.curseforge.com/wow/addons/voiceover-sounds-vanilla",
        },
    },
}

---@param a DataModule|DataModuleMetadata
---@param b DataModule|DataModuleMetadata
local function SortModules(a, b)
    a = a.METADATA or a
    b = b.METADATA or b
    if a.ModulePriority ~= b.ModulePriority then
        return a.ModulePriority > b.ModulePriority
    end
    return a.AddonName < b.AddonName
end

---@param name string Addon name
---@param module DataModule Module data table
function DataModules:Register(name, module)
    assert(not self.registeredModules[name], format([[Module "%s" already registered]], name))

    local metadata = assert(self.presentModules[name],
        format([[Module "%s" attempted to register but wasn't detected during addon enumeration]], name))
    local moduleVersion = assert(tonumber(GetAddOnMetadata(name, "X-VoiceOver-DataModule-Version")),
        format([[Module "%s" is missing data format version]], name))

    -- Ideally if module format would ever change - there should be fallbacks in place to handle outdated formats
    assert(moduleVersion == CURRENT_MODULE_VERSION,
        format([[Module "%s" contains outdated data format (version %d, expected %d)]], name, moduleVersion,
            CURRENT_MODULE_VERSION))

    module.METADATA = metadata

    self.registeredModules[name] = module
    table.insert(self.registeredModulesOrdered, module)

    -- Order the modules by priority (higher first) then by name (case-sensitive alphabetical)
    -- Modules with higher priority will be iterated through first, so one can create a module with "overrides" for data in other modules by simply giving it a higher priority
    table.sort(self.registeredModulesOrdered, SortModules)
end

function DataModules:HasRegisteredModules()
    return next(self.registeredModules) ~= nil
end

function DataModules:GetModule(name)
    return self.registeredModules[name]
end

function DataModules:GetModules()
    return ipairs(self.registeredModulesOrdered)
end

function DataModules:GetPresentModule(name)
    return self.presentModules[name]
end

function DataModules:GetPresentModules()
    return ipairs(self.presentModulesOrdered)
end

function DataModules:GetAvailableModules()
    return ipairs(self.availableModules)
end

function DataModules:EnumerateAddons()
    local playerName = UnitName("player")
    for i = 1, GetNumAddOns() do
        local moduleVersion = tonumber(GetAddOnMetadata(i, "X-VoiceOver-DataModule-Version"))
        if moduleVersion and (FORCE_ENABLE_DISABLED_MODULES or GetAddOnEnableState(playerName, i) ~= 0) then
            local name = GetAddOnInfo(i)
            local mapsString = GetAddOnMetadata(i, "X-VoiceOver-DataModule-Maps")
            local maps = {}
            if mapsString then
                for _, mapString in ipairs({ strsplit(",", mapsString) }) do
                    local map = tonumber(mapString)
                    if map then
                        maps[map] = true
                    end
                end
            end
            ---@type DataModuleMetadata
            local module =
            {
                AddonName = name,
                LoadOnDemand = IsAddOnLoadOnDemand(name),
                ModuleVersion = moduleVersion,
                ModulePriority = tonumber(GetAddOnMetadata(name, "X-VoiceOver-DataModule-Priority")) or 0,
                ContentVersion = GetAddOnMetadata(name, "Version"),
                Title = GetAddOnMetadata(name, "Title") or name,
                Maps = maps,
            }
            self.presentModules[name] = module
            table.insert(self.presentModulesOrdered, module)

            -- Maybe in the future we can load modules based on the map the player is in (select(8, GetInstanceInfo())), but for now - just load everything
            if LOAD_ALL_MODULES and IsAddOnLoadOnDemand(name) then
                DataModules:LoadModule(module)
            end
        end
    end

    table.sort(self.presentModulesOrdered, SortModules)
    for order, module in self:GetPresentModules() do
        Options:AddDataModule(module, order)
    end

    for order, module in self:GetAvailableModules() do
        local min = module.RelevantAboveVersion
        local max = module.RelevantBelowVersion
        if (not min or Version.Interface >= min) and (not max or Version.Interface < max) then
            local present = self.presentModules[module.AddonName]
            local update = present and present.ContentVersion ~= module.ContentVersion
            if not present or update then
                Options:AddAvailableDataModule(module, order, update)
            end
        end
    end
end

-- We deliberately use a high ##Interface version in TOC to ensure that all clients will load it.
-- Otherwise pre-classic-rerelease clients will refuse to load addons with version < 20000.
-- Here we temporarily enable "Load out of date AddOns" to load the module, and restore the user's setting afterwards.
-- These cvars can be nil, so have to store the fact of them being changed in a separate variable.
local prev_checkAddonVersion, changed_checkAddonVersion
local prev_lastAddonVersion, changed_lastAddonVersion -- Added in 5.x
local addonWasDisabled = {}
local function EnableOutOfDate(addon)
    if not changed_checkAddonVersion then
        prev_checkAddonVersion = GetCVar("checkAddonVersion")
        SetCVar("checkAddonVersion", 0)
        changed_checkAddonVersion = true
    end
    if not changed_lastAddonVersion and Version:IsRetailOrAboveLegacyVersion(50000) then
        prev_lastAddonVersion = GetCVar("lastAddonVersion")
        SetCVar("lastAddonVersion", Version.Interface)
        changed_lastAddonVersion = true
    end

    addonWasDisabled[addon] = GetAddOnEnableState(UnitName("player"), addon) == 0
    if FORCE_ENABLE_DISABLED_MODULES and addonWasDisabled[addon] then
        EnableAddOn(addon)
    end
end
local function RestoreOutOfDate(addon)
    if changed_checkAddonVersion then
        SetCVar("checkAddonVersion", prev_checkAddonVersion)
        changed_checkAddonVersion = nil
    end
    if changed_lastAddonVersion and Version:IsRetailOrAboveLegacyVersion(50000) then
        SetCVar("lastAddonVersion", prev_lastAddonVersion)
        changed_lastAddonVersion = nil
    end

    if FORCE_ENABLE_DISABLED_MODULES and addonWasDisabled[addon] then
        DisableAddOn(addon)
    end
    addonWasDisabled[addon] = nil
end

---@param module DataModuleMetadata
function DataModules:LoadModule(module)
    if not module.LoadOnDemand or self:GetModule(module.AddonName) or IsAddOnLoaded(module.AddonName) then
        return false
    end

    EnableOutOfDate(module.AddonName)
    local loaded, reason = LoadAddOn(module.AddonName)
    RestoreOutOfDate(module.AddonName)
    return loaded, reason
end

function DataModules:GetModuleAddOnInfo(module)
    EnableOutOfDate(module.AddonName)
    local name, title, notes, loadable, reason = GetAddOnInfo(module.AddonName)
    RestoreOutOfDate(module.AddonName)
    return name, title, notes, loadable, reason
end

local function replaceDoubleQuotes(text)
    return string.gsub(text, '"', "'")
end

---@param soundData SoundData
---@return string|nil hash
function DataModules:GetNPCGossipTextHash(soundData)
    local table, npc
    if soundData.unitGUID then
        local type = Utils:GetGUIDType(soundData.unitGUID)
        if Enums.GUID:IsCreature(type) then
            table = "GossipLookupByNPCID"
        elseif type == Enums.GUID.GameObject then
            table = "GossipLookupByObjectID"
        else
            return
        end
        npc = Utils:GetIDFromGUID(soundData.unitGUID)
    else
        table = soundData.unitIsObjectOrItem and "GossipLookupByObjectName" or "GossipLookupByNPCName"
        npc = replaceDoubleQuotes(soundData.name)
    end
    local text = soundData.text

    local text_entries = {}

    for _, module in self:GetModules() do
        local data = module[table]
        if data then
            local npc_gossip_table = data[npc]
            if npc_gossip_table then
                for text, hash in pairs(npc_gossip_table) do
                    text_entries[text] = text_entries[text] or
                        hash -- Respect module priority, don't overwrite the entry if there is already one
                end
            end
        end
    end

    local best_result = FuzzySearchBestKeys(text, text_entries)
    return best_result and best_result.value
end

local function getFirstNWords(text, n)
    local firstNWords = {}
    local count = 0

    for word in string.gmatch(text, "%S+") do
        count = count + 1
        table.insert(firstNWords, word)
        if count >= n then
            break
        end
    end

    return table.concat(firstNWords, " ")
end

local function getLastNWords(text, n)
    local lastNWords = {}
    local count = 0

    for word in string.gmatch(text, "%S+") do
        table.insert(lastNWords, word)
        count = count + 1
    end

    local startIndex = math.max(1, count - n + 1)
    local endIndex = count

    return table.concat(lastNWords, " ", startIndex, endIndex)
end

---@alias QuestIDLookupSource "accept"|"progress"|"complete"

---@param source QuestIDLookupSource
---@param title string
---@param npcName string
---@param text string
---@return number questID
function DataModules:GetQuestID(source, title, npcName, text)
    local cleanedTitle = replaceDoubleQuotes(title)
    local cleanedNPCName = replaceDoubleQuotes(npcName)
    local cleanedText = replaceDoubleQuotes(getFirstNWords(text, 15)) ..
        " " .. replaceDoubleQuotes(getLastNWords(text, 15))
    local text_entries_mode3 = {} -- Modo 3: Título → NPC → Texto → ID
    local text_entries_mode4 = {} -- Modo 4: Título → "Modo4" → Texto → ID

    for _, module in self:GetModules() do
        local data = module.QuestIDLookup
        if data and data[source] and data[source][cleanedTitle] then
            local titleLookup = data[source][cleanedTitle]
            
            -- Verificar Modo 4: Título → "Modo4" → Texto → ID (más preciso)
            if type(titleLookup) == "table" and titleLookup["Modo4"] and type(titleLookup["Modo4"]) == "table" then
                -- Hemos encontrado una estructura de Modo4 explícita
                for textKey, ID in pairs(titleLookup["Modo4"]) do
                    text_entries_mode4[textKey] = text_entries_mode4[textKey] or ID -- Respetamos prioridad
                end
            end
            
            -- Verificar otros modos (puede coexistir con Modo4 en caso de formato mixto)
            if type(titleLookup) == "number" then
                -- Modo 1: Título → ID
                text_entries_mode3["__mode1_result__"] = text_entries_mode3["__mode1_result__"] or titleLookup
            elseif type(titleLookup) == "table" then
                -- Comprobar otros iniciadores (no "Modo4")
                for key, value in pairs(titleLookup) do
                    if key ~= "Modo4" then
                        -- Posible Modo 2: Título → NPC → ID
                        if key == cleanedNPCName then
                            if type(value) == "number" then
                                -- Modo 2 exacto: Título → NPC → ID
                                text_entries_mode3["__mode2_result__"] = text_entries_mode3["__mode2_result__"] or value
                            elseif type(value) == "table" then
                                -- Modo 3: Título → NPC → Texto → ID
                                for textKey, ID in pairs(value) do
                                    text_entries_mode3[textKey] = text_entries_mode3[textKey] or ID
                                end
                            end
                        elseif type(value) == "table" then
                            -- Explorar otras entradas de NPC para Modo 3
                            for textKey, ID in pairs(value) do
                                -- Guardar con prioridad más baja (NPCs que no coinciden)
                                text_entries_mode3["__low_priority_" .. textKey] = text_entries_mode3["__low_priority_" .. textKey] or ID
                            end
                        end
                    end
                end
            end
        end
    end

    -- Prioridad: Modo 4 > Modo 3 > Modo 2 > Modo 1
    
    -- Intentar Modo 4: Título → "Modo4" → Texto → ID (más preciso)
    if next(text_entries_mode4) then
        local best_result = FuzzySearchBestKeys(cleanedText, text_entries_mode4)
        if best_result and best_result.value then
            if self.db and self.db.profile and self.db.profile.DebugEnabled then
                Debug:Print(format("Encontrado ID %d para misión '%s' usando Modo 4 (coincidencia con texto)", 
                    best_result.value, cleanedTitle), "DataModules")
            end
            return best_result.value
        end
    end
    
    -- Intentar Modo 3: Título → NPC → Texto → ID
    local best_result = FuzzySearchBestKeys(cleanedText, text_entries_mode3)
    if best_result and best_result.value then
        -- No considerar claves especiales como parte de la búsqueda difusa de texto
        if best_result.text ~= "__mode2_result__" and best_result.text ~= "__mode1_result__" and 
           not string.find(best_result.text, "^__low_priority_") then
            if self.db and self.db.profile and self.db.profile.DebugEnabled then
                Debug:Print(format("Encontrado ID %d para misión '%s' usando Modo 3 (NPC + texto)", 
                    best_result.value, cleanedTitle), "DataModules")
            end
            return best_result.value
        end
    end
    
    -- Intentar Modo 2: Título → NPC → ID
    if text_entries_mode3["__mode2_result__"] then
        if self.db and self.db.profile and self.db.profile.DebugEnabled then
            Debug:Print(format("Encontrado ID %d para misión '%s' usando Modo 2 (NPC exacto)", 
                text_entries_mode3["__mode2_result__"], cleanedTitle), "DataModules")
        end
        return text_entries_mode3["__mode2_result__"]
    end
    
    -- Intentar Modo 1: Título → ID (menos preciso)
    if text_entries_mode3["__mode1_result__"] then
        if self.db and self.db.profile and self.db.profile.DebugEnabled then
            Debug:Print(format("Encontrado ID %d para misión '%s' usando Modo 1 (solo título)", 
                text_entries_mode3["__mode1_result__"], cleanedTitle), "DataModules")
        end
        return text_entries_mode3["__mode1_result__"]
    end
    
    -- Si llegamos aquí, buscar en entradas de baja prioridad (NPC no coincidente)
    for key, value in pairs(text_entries_mode3) do
        if string.find(key, "^__low_priority_") then
            local textKey = string.sub(key, 15) -- Quitar el prefijo "__low_priority_"
            local lowPriorityEntries = {[textKey] = value}
            local result = FuzzySearchBestKeys(cleanedText, lowPriorityEntries)
            if result and result.value then
                if self.db and self.db.profile and self.db.profile.DebugEnabled then
                    Debug:Print(format("Encontrado ID %d para misión '%s' usando búsqueda de baja prioridad", 
                        result.value, cleanedTitle), "DataModules")
                end
                return result.value
            end
        end
    end
    
    -- No se encontró coincidencia
    return nil
end

---@param questID number
---@return GUID|nil type `Enums.GUID` type of the quest giver
---@return number|nil id ID of the quest giver
function DataModules:GetQuestLogQuestGiverTypeAndID(questID)
    for _, module in self:GetModules() do
        -- Verificar que el módulo existe
        if not module then 
            if self.db and self.db.profile and self.db.profile.DebugEnabled then
                Debug:Print("Módulo nulo encontrado en GetQuestLogQuestGiverTypeAndID", "DataModules")
            end
            return 
        end
        
        local data = module.NPCIDLookupByQuestID
        if data then
            local npcID = data[questID]
            if npcID then
                -- Verificar si es una tabla con "start" y "end"
                if type(npcID) == "table" and (npcID["start"] or npcID["end"]) then
                    -- Usamos el NPC de "end" para audio de progreso y "start" para el resto
                    local completeQuestID = GetQuestID and GetQuestID() or 0
                    -- Si estamos completando una misión, usamos el NPC de "end"
                    if completeQuestID == questID and npcID["end"] then
                        return Enums.GUID.Creature, npcID["end"]
                    -- De lo contrario, usamos el NPC de "start"
                    elseif npcID["start"] then
                        return Enums.GUID.Creature, npcID["start"]
                    end
                else
                    -- Formato tradicional, solo un ID de NPC
                    return Enums.GUID.Creature, npcID
                end
            end
        end

        data = module.ObjectIDLookupByQuestID
        if data then
            local objectID = data[questID]
            if objectID then
                return Enums.GUID.GameObject, objectID
            end
        end

        data = module.ItemIDLookupByQuestID
        if data then
            local itemID = data[questID]
            if itemID then
                return Enums.GUID.Item, itemID
            end
        end
    end
end

---@param type GUID `Enums.GUID` type of the desired object
---@param id number ID of the desired object
---@return string|nil name
function DataModules:GetObjectName(type, id)
    local table
    if Enums.GUID:IsCreature(type) then
        table = "NPCNameLookupByNPCID"
    elseif type == Enums.GUID.GameObject then
        table = "ObjectNameLookupByObjectID"
    elseif type == Enums.GUID.Item then
        table = "ItemNameLookupByItemID"
    else
        return
    end

    for _, module in self:GetModules() do
        local data = module[table]
        if data then
            local npcName = data[id]
            if npcName then
                return npcName
            end
        end
    end
end

---@type table<SoundEvent, fun(soundData: SoundData): string|nil>
local getFileNameForEvent =
{
    [Enums.SoundEvent.QuestAccept]   = function(soundData) return format("%d-%s", soundData.questID, "accept") end,
    [Enums.SoundEvent.QuestProgress] = function(soundData) return format("%d-%s", soundData.questID, "progress") end,
    [Enums.SoundEvent.QuestComplete] = function(soundData) return format("%d-%s", soundData.questID, "complete") end,
    [Enums.SoundEvent.QuestGreeting] = function(soundData) return DataModules:GetNPCGossipTextHash(soundData) end,
    [Enums.SoundEvent.Gossip]        = function(soundData) return DataModules:GetNPCGossipTextHash(soundData) end,
    [Enums.SoundEvent.Tip]           = function(soundData) return string.match(soundData.filePath, "([^\\]+)$") end, -- Extraer solo el nombre del archivo
}
setmetatable(getFileNameForEvent,
    {
        __index = function(self, event)
            error(format([[Unhandled VoiceOver sound event %d "%s"]], event,
                Enums.SoundEvent:GetName(event) or "???"))
        end
    })

---@param soundData SoundData
---@return boolean found Whether the sound is found and can be played
function DataModules:PrepareSound(soundData)
    soundData.fileName = getFileNameForEvent[soundData.event](soundData)

    if soundData.fileName == nil then
        return false
    end

    for _, module in self:GetModules() do
        local data = module.SoundLengthLookupByFileName
        if data then
            local playerGenderedFileName = DataModules:AddPlayerGenderToFilename(soundData.fileName)
            local length = data[playerGenderedFileName]
            if length then
                soundData.fileName = playerGenderedFileName
            else
                length = data[soundData.fileName]
            end
            if length then
                soundData.filePath = format([[Interface\AddOns\%s\%s]], module.METADATA.AddonName,
                    module.GetSoundPath and module:GetSoundPath(soundData.fileName, soundData.event) or
                    soundData.fileName)
                soundData.length = length
                soundData.module = module
                return true
            end
        end
    end

    return false
end

function DataModules:AddPlayerGenderToFilename(fileName)
    local playerGender = UnitSex("player")

    if playerGender == 2 then     -- male
        return "m-" .. fileName
    elseif playerGender == 3 then -- female
        return "f-" .. fileName
    else                          -- unknown or error
        return fileName
    end
end
