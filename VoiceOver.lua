setfenv(1, VoiceOver)

---@class Addon : AceAddon, AceAddon-3.0, AceEvent-3.0, AceTimer-3.0
---@field db VoiceOverConfig|AceDBObject-3.0
Addon = LibStub("AceAddon-3.0"):NewAddon("VoiceOver", "AceEvent-3.0", "AceTimer-3.0")

Addon.OnAddonLoad = {}

---@class VoiceOverConfig
local defaults = {
    profile = {
        SoundQueueUI = {
            LockFrame = false,
            FrameScale = 0.7,
            FrameStrata = "HIGH",
            HidePortrait = false,
            HideFrame = false,
        },
        Audio = {
            GossipFrequency = Enums.GossipFrequency.OncePerQuestNPC,
            SoundChannel = Enums.SoundChannel.Master,
            AutoToggleDialog = Version.IsLegacyVanilla or Version:IsRetailOrAboveLegacyVersion(60100),
            StopAudioOnDisengage = false,
            PlayProgressAt50Percent = true,
            PlayTips = true,
            ResetQuestProgressOnReload = true,
            TipPlayedThisSession = false,
        },
        MinimapButton = {
            LibDBIcon = {}, -- Table used by LibDBIcon to store position (minimapPos), dragging lock (lock) and hidden state (hide)
            Commands = {
                -- References keys from Options.table.args.SlashCommands.args table
                LeftButton = "Options",
                MiddleButton = "PlayPause",
                RightButton = "Clear",
            }
        },
        LegacyWrath = (Version.IsLegacyWrath or Version.IsLegacyBurningCrusade or nil) and {
            PlayOnMusicChannel = {
                Enabled = true,
                Volume = 1,
                FadeOutMusic = 0.5,
            },
            HDModels = false,
        },
        DebugEnabled = false,
    },
    char = {
        IsPaused = false,
        hasSeenGossipForNPC = {},
        RecentQuestTitleToID = Version:IsBelowLegacyVersion(30300) and {},
        QuestProgress = {},
        QuestProgressAudioPlayed = {},
        TipsPlayedForQuest = {}, -- Para seguimiento de consejos reproducidos por misión
        RecentlyPlayedTips = {},
    }
}

local lastGossipOptions
local selectedGossipOption
local currentQuestSoundData
local currentGossipSoundData

local lastUpdateTime = 0
local UPDATE_THROTTLE = 0.5 -- Segundos mínimos entre actualizaciones

function Addon:OnInitialize()
    self.db = LibStub("AceDB-3.0"):New("VoiceOverDB", defaults)
    self.db.RegisterCallback(self, "OnProfileChanged", "RefreshConfig")
    self.db.RegisterCallback(self, "OnProfileReset", "RefreshConfig")

    StaticPopupDialogs["VOICEOVER_ERROR"] =
    {
        text = "VoiceOver|n|n%s",
        button1 = OKAY,
        timeout = 0,
        whileDead = 1,
    }

    -- Reiniciar el seguimiento de audios de progreso ya reproducidos cuando se inicia/recarga el addon
    if self.db.profile.Audio.ResetQuestProgressOnReload then
        self.db.char.QuestProgressAudioPlayed = {}
        if self.db.profile.DebugEnabled then
            Debug:Print("¡Reiniciado el seguimiento de progreso de misiones!", "Progress")
        end
    end
    
    -- Ya no reiniciamos TipsPlayedForQuest en cada inicio porque queremos que sea por sesión
    -- En su lugar, marcamos que no se ha reproducido ningún consejo en esta sesión
    self.db.profile.Audio.TipPlayedThisSession = false
    if self.db.profile.DebugEnabled then
        Debug:Print("¡Reiniciado el seguimiento de consejos para esta sesión!", "Tips")
    end
    
    SoundQueueUI:Initialize()
    DataModules:EnumerateAddons()
    Options:Initialize()

    self:RegisterEvent("ADDON_LOADED")
    self:RegisterEvent("QUEST_DETAIL")
    self:RegisterEvent("QUEST_PROGRESS")
    self:RegisterEvent("QUEST_COMPLETE")
    self:RegisterEvent("QUEST_GREETING")
    self:RegisterEvent("QUEST_FINISHED")
    self:RegisterEvent("GOSSIP_SHOW")
    self:RegisterEvent("GOSSIP_CLOSED")

    self:RegisterEvent("QUEST_LOG_UPDATE")

    if select(5, GetAddOnInfo("VoiceOver")) ~= "MISSING" then
        DisableAddOn("VoiceOver")
        if not self.db.profile.SeenDuplicateDialog then
            StaticPopupDialogs["VOICEOVER_DUPLICATE_ADDON"] =
            {
                text = [[VoiceOver|n|nTo fix the quest autoaccept bugs we had to rename the addon folder. If you're seeing this popup, it means the old one wasn't automatically removed.|n|nYou can safely delete "VoiceOver" from your Addons folder. "AI_VoiceOver" is the new folder.]],
                button1 = OKAY,
                timeout = 0,
                whileDead = 1,
                OnAccept = function()
                    self.db.profile.SeenDuplicateDialog = true
                end,
            }
            StaticPopup_Show("VOICEOVER_DUPLICATE_ADDON")
        end
    end

    if select(5, GetAddOnInfo("AI_VoiceOver_112")) ~= "MISSING" then
        DisableAddOn("AI_VoiceOver_112")
        if not self.db.profile.SeenDuplicateDialog112 then
            StaticPopupDialogs["VOICEOVER_DUPLICATE_ADDON_112"] =
            {
                text = [[VoiceOver|n|nVoiceOver port for 1.12 has been merged together with other versions and is no longer distributed as a separate addon.|n|nYou can safely delete "AI_VoiceOver_112" from your Addons folder. "AI_VoiceOver" is the new folder.]],
                button1 = OKAY,
                timeout = 0,
                whileDead = 1,
                OnAccept = function()
                    self.db.profile.SeenDuplicateDialog112 = true
                end,
            }
            StaticPopup_Show("VOICEOVER_DUPLICATE_ADDON_112")
        end
    end

    if not DataModules:HasRegisteredModules() then
        StaticPopupDialogs["VOICEOVER_NO_REGISTERED_DATA_MODULES"] =
        {
            text = [[VoiceOver|n|nNo sound packs were found.|n|nUse the "/vo options" command, (or Interface Options in newer clients) and go to the DataModules tab for information on where to download sound packs.]],
            button1 = OKAY,
            timeout = 0,
            whileDead = 1,
        }
        StaticPopup_Show("VOICEOVER_NO_REGISTERED_DATA_MODULES")
    end

    local function MakeAbandonQuestHook(field, getFieldData)
        return function()
            local data = getFieldData()
            local soundsToRemove = {}
            for _, soundData in pairs(SoundQueue.sounds) do
                if Enums.SoundEvent:IsQuestEvent(soundData.event) and soundData[field] == data then
                    table.insert(soundsToRemove, soundData)
                end
            end

            for _, soundData in pairs(soundsToRemove) do
                SoundQueue:RemoveSoundFromQueue(soundData)
            end
        end
    end
    if C_QuestLog and C_QuestLog.AbandonQuest then
        hooksecurefunc(C_QuestLog, "AbandonQuest", MakeAbandonQuestHook("questID", function() return C_QuestLog.GetAbandonQuest() end))
    elseif AbandonQuest then
        hooksecurefunc("AbandonQuest", MakeAbandonQuestHook("questName", function() return GetAbandonQuestName() end))
    end

    if QuestLog_Update then
        hooksecurefunc("QuestLog_Update", function()
            QuestOverlayUI:Update()
        end)
    end

    if C_GossipInfo and C_GossipInfo.SelectOption then
        hooksecurefunc(C_GossipInfo, "SelectOption", function(optionID)
            if lastGossipOptions then
                for _, info in ipairs(lastGossipOptions) do
                    if info.gossipOptionID == optionID then
                        selectedGossipOption = info.name
                        break
                    end
                end
                lastGossipOptions = nil
            end
        end)
    elseif SelectGossipOption then
        hooksecurefunc("SelectGossipOption", function(index)
            if lastGossipOptions then
                selectedGossipOption = lastGossipOptions[1 + (index - 1) * 2]
                lastGossipOptions = nil
            end
        end)
    end
end

function Addon:RefreshConfig()
    SoundQueueUI:RefreshConfig()
end

function Addon:ADDON_LOADED(event, addon)
    addon = addon or arg1 -- Thanks, Ace3v...
    local hook = self.OnAddonLoad[addon]
    if hook then
        hook()
    end
end

local function GossipSoundDataAdded(soundData)
    Utils:CreateNPCModelFrame(soundData)

    -- Save current gossip sound data for dialog/frame sync option
    currentGossipSoundData = soundData
end

local function QuestSoundDataAdded(soundData)
    Utils:CreateNPCModelFrame(soundData)

    -- Save current quest sound data for dialog/frame sync option
    currentQuestSoundData = soundData
end

local GetTitleText = GetTitleText -- Store original function before EQL3 (Extended Quest Log 3) overrides it and starts prepending quest level
function Addon:QUEST_DETAIL()
    local questID = GetQuestID()
    local questTitle = GetTitleText()
    local questText = GetQuestText()
    local guid = Utils:GetNPCGUID()
    local targetName = Utils:GetNPCName()

    if not questID or questID == 0 then
        return
    end

    -- Can happen if the player interacted with an NPC while having main menu or options opened
    if not guid and not targetName then
        return
    end

    if Addon.db.char.RecentQuestTitleToID and questID ~= 0 then
        Addon.db.char.RecentQuestTitleToID[questTitle] = questID
    end

    local type = guid and Utils:GetGUIDType(guid)
    if type == Enums.GUID.Item then
        -- Allow quests started from items to have VO, book icon will be displayed for them
    elseif not type or not Enums.GUID:CanHaveID(type) then
        -- If the quest is started by something that we cannot extract the ID of (e.g. Player, when sharing a quest) - try to fallback to a questgiver from a module's database
        local id
        type, id = DataModules:GetQuestLogQuestGiverTypeAndID(questID)
        guid = id and Enums.GUID:CanHaveID(type) and Utils:MakeGUID(type, id) or guid
        targetName = id and DataModules:GetObjectName(type, id) or targetName or "Unknown Name"
    end

    -- print("QUEST_DETAIL", questID, questTitle);
    ---@type SoundData
    local soundData = {
        event = Enums.SoundEvent.QuestAccept,
        questID = questID,
        name = targetName,
        title = questTitle,
        text = questText,
        unitGUID = guid,
        unitIsObjectOrItem = Utils:IsNPCObjectOrItem(),
        addedCallback = QuestSoundDataAdded,
    }
    SoundQueue:AddSoundToQueue(soundData)
end

function Addon:QUEST_PROGRESS()
    local questID = GetQuestID()
    local questTitle = GetTitleText()
    local questText = GetProgressText()
    local guid = Utils:GetNPCGUID()
    local targetName = Utils:GetNPCName()

    if not questID or questID == 0 then
        return
    end

    -- Can happen if the player interacted with an NPC while having main menu or options opened
    if not guid and not targetName then
        return
    end

    if Addon.db.char.RecentQuestTitleToID and questID ~= 0 then
        Addon.db.char.RecentQuestTitleToID[questTitle] = questID
    end

    -- Verificar si ya se ha reproducido el audio de progreso para esta misión
    if self.db.char.QuestProgressAudioPlayed[questID] then
        if self.db.profile.DebugEnabled then
            Debug:Print(format("Audio de progreso para [%s] ya reproducido anteriormente", questTitle), "Progress")
        end
        return
    end

    -- print("QUEST_PROGRESS", questID, questTitle);
    ---@type SoundData
    local soundData = {
        event = Enums.SoundEvent.QuestProgress,
        questID = questID,
        name = targetName,
        title = questTitle,
        text = questText,
        unitGUID = guid,
        unitIsObjectOrItem = Utils:IsNPCObjectOrItem(),
        addedCallback = QuestSoundDataAdded,
    }
    SoundQueue:AddSoundToQueue(soundData)
    
    -- Marca esta misión como reproducida para no volver a reproducirla
    self.db.char.QuestProgressAudioPlayed[questID] = true
    
    if self.db.profile.DebugEnabled then
        Debug:Print(format("¡Audio de progreso reproducido por NPC! - Misión [%s] marcada como reproducida", questTitle), "Progress")
    end
end

function Addon:QUEST_COMPLETE()
    local questID = GetQuestID()
    local questTitle = GetTitleText()
    local questText = GetRewardText()
    local guid = Utils:GetNPCGUID()
    local targetName = Utils:GetNPCName()

    if not questID or questID == 0 then
        return
    end

    -- Can happen if the player interacted with an NPC while having main menu or options opened
    if not guid and not targetName then
        return
    end

    if Addon.db.char.RecentQuestTitleToID and questID ~= 0 then
        Addon.db.char.RecentQuestTitleToID[questTitle] = questID
    end

    -- Quest ID = 0, try to obtain the real one
    local type
    if guid then
        type = Utils:GetGUIDType(guid)
        if type == Enums.GUID.Item then
            -- Allow quests started from items to have VO, book icon will be displayed for them
        elseif not type or not Enums.GUID:CanHaveID(type) then
            -- If the quest is started by something that we cannot extract the ID of (e.g. Player, when sharing a quest) - try to fallback to a questgiver from a module's database
            local id
            type, id = DataModules:GetQuestLogQuestGiverTypeAndID(questID)
            guid = id and Enums.GUID:CanHaveID(type) and Utils:MakeGUID(type, id) or guid
            targetName = id and DataModules:GetObjectName(type, id) or targetName or "Unknown Name"
        end
    else
        -- No guid, try to get quest giver info from modules
        type, id = DataModules:GetQuestLogQuestGiverTypeAndID(questID)
        if type and id then
            guid = Enums.GUID:CanHaveID(type) and Utils:MakeGUID(type, id) or nil
            targetName = DataModules:GetObjectName(type, id) or targetName or "Unknown Name"
        end
    end

    -- print("QUEST_COMPLETE", questID, questTitle);
    ---@type SoundData
    local soundData = {
        event = Enums.SoundEvent.QuestComplete,
        questID = questID,
        name = targetName,
        title = questTitle,
        text = questText,
        unitGUID = guid,
        unitIsObjectOrItem = Utils:IsNPCObjectOrItem(),
        addedCallback = QuestSoundDataAdded,
    }
    SoundQueue:AddSoundToQueue(soundData)
    
    -- Ya no se reproducen los consejos al completar misiones
    -- Se reproducirán al alcanzar el 70% de progreso
end

function Addon:ShouldPlayGossip(guid, text)
    local npcKey = guid or "unknown"

    local gossipSeenForNPC = self.db.char.hasSeenGossipForNPC[npcKey]

    if self.db.profile.Audio.GossipFrequency == Enums.GossipFrequency.OncePerQuestNPC then
        local numActiveQuests = GetNumGossipActiveQuests()
        local numAvailableQuests = GetNumGossipAvailableQuests()
        local npcHasQuests = (numActiveQuests > 0 or numAvailableQuests > 0)
        if npcHasQuests and gossipSeenForNPC then
            return
        end
    elseif self.db.profile.Audio.GossipFrequency == Enums.GossipFrequency.OncePerNPC then
        if gossipSeenForNPC then
            return
        end
    elseif self.db.profile.Audio.GossipFrequency == Enums.GossipFrequency.Never then
        return
    end

    return true, npcKey
end

function Addon:QUEST_GREETING()
    local guid = Utils:GetNPCGUID()
    local targetName = Utils:GetNPCName()
    local greetingText = GetGreetingText()

    -- Can happen if the player interacted with an NPC while having main menu or options opened
    if not guid and not targetName then
        return
    end

    local play, npcKey = self:ShouldPlayGossip(guid, greetingText)
    if not play then
        return
    end

    -- Play the gossip sound
    ---@type SoundData
    local soundData = {
        event = Enums.SoundEvent.QuestGreeting,
        name = targetName,
        text = greetingText,
        unitGUID = guid,
        unitIsObjectOrItem = Utils:IsNPCObjectOrItem(),
        addedCallback = GossipSoundDataAdded,
        startCallback = function()
            self.db.char.hasSeenGossipForNPC[npcKey] = true
        end
    }
    SoundQueue:AddSoundToQueue(soundData)
end

function Addon:GOSSIP_SHOW()
    local guid = Utils:GetNPCGUID()
    local targetName = Utils:GetNPCName()
    local gossipText = GetGossipText()

    -- Can happen if the player interacted with an NPC while having main menu or options opened
    if not guid and not targetName then
        return
    end

    local play, npcKey = self:ShouldPlayGossip(guid, gossipText)
    if not play then
        return
    end

    -- Play the gossip sound
    ---@type SoundData
    local soundData = {
        event = Enums.SoundEvent.Gossip,
        name = targetName,
        title = selectedGossipOption and format([["%s"]], selectedGossipOption),
        text = gossipText,
        unitGUID = guid,
        unitIsObjectOrItem = Utils:IsNPCObjectOrItem(),
        addedCallback = GossipSoundDataAdded,
        startCallback = function()
            self.db.char.hasSeenGossipForNPC[npcKey] = true
        end
    }
    SoundQueue:AddSoundToQueue(soundData)

    selectedGossipOption = nil
    lastGossipOptions = nil
    if C_GossipInfo and C_GossipInfo.GetOptions then
        lastGossipOptions = C_GossipInfo.GetOptions()
    elseif GetGossipOptions then
        lastGossipOptions = { GetGossipOptions() }
    end
end

function Addon:QUEST_FINISHED()
    if Addon.db.profile.Audio.StopAudioOnDisengage and currentQuestSoundData then
        SoundQueue:RemoveSoundFromQueue(currentQuestSoundData)
    end
    currentQuestSoundData = nil
end

function Addon:GOSSIP_CLOSED()
    if Addon.db.profile.Audio.StopAudioOnDisengage and currentGossipSoundData then
        SoundQueue:RemoveSoundFromQueue(currentGossipSoundData)
    end
    currentGossipSoundData = nil

    selectedGossipOption = nil
end

function Addon:GetQuestProgress(questID)
    local numObjectives = GetNumQuestLeaderBoards()
    if numObjectives == 0 then return 0 end
    
    local completedObjectives = 0
    local totalProgress = 0
    local maxProgress = 0
    
    for i = 1, numObjectives do
        local text, objType, finished = GetQuestLogLeaderBoard(i)
        
        if finished then
            completedObjectives = completedObjectives + 1
        end
        
        -- Intenta extraer números de progreso de diferentes formatos
        if text and (type(text) == "string") then
            -- Intenta patrones en orden de prioridad
            local current, total
            
            -- Patrón 1: "5/10"
            current, total = string.match(text, "(%d+)/(%d+)")
            
            -- Patrón 2: "asesinados: 3/12"
            if not current or not total then
                current, total = string.match(text, ": (%d+)/(%d+)")
            end
            
            -- Patrón 3: extraer los dos primeros números del texto sin usar tablas
            if not current or not total then
                local num1, num2
                
                -- Buscar todos los números en el texto
                for num in string.gmatch(text, "%d+") do
                    if not num1 then
                        num1 = tonumber(num)
                    elseif not num2 then
                        num2 = tonumber(num)
                        break -- Salir después de encontrar el segundo número
                    end
                end
                
                if num1 and num2 then
                    current, total = num1, num2
                end
            end
            
            -- Si se encontraron los valores, usarlos para el cálculo
            if current and total then
                current, total = tonumber(current), tonumber(total)
                if current and total and total > 0 then
                    totalProgress = totalProgress + current
                    maxProgress = maxProgress + total
                end
            end
        end
    end
    
    -- Si tenemos información detallada de progreso, úsala
    if maxProgress > 0 then
        local percent = (totalProgress / maxProgress) * 100
        return percent
    end
    
    -- De lo contrario, usa el conteo de objetivos completados
    local percent = (completedObjectives / numObjectives) * 100
    return percent
end

function Addon:QUEST_LOG_UPDATE()
    if not self.db.profile.Audio.PlayProgressAt50Percent then 
        return 
    end
    
    -- Evitar múltiples actualizaciones en corto tiempo
    local currentTime = GetTime()
    if currentTime - lastUpdateTime < UPDATE_THROTTLE then
        return
    end
    lastUpdateTime = currentTime
    
    -- Guarda el índice de misión actual para restaurarlo después
    local currentQuestLogSelection = GetQuestLogSelection()
    
    -- Chequea todas las misiones en el registro
    local numEntries, numQuests = GetNumQuestLogEntries()
    for i = 1, numEntries do
        local title, level, suggestedGroup, isHeader, isCollapsed, isComplete, frequency, questID = GetQuestLogTitle(i)
        if not isHeader and questID and not isComplete then
            -- Selecciona la misión para obtener sus objetivos
            SelectQuestLogEntry(i)
            
            -- Calcula el progreso actual
            local progress = self:GetQuestProgress(questID)
            local lastProgress = self.db.char.QuestProgress[questID] or 0
            
            -- Solo mostrar información si el progreso ha cambiado
            if math.abs(progress - lastProgress) > 0.1 then
                -- Log simplificado solo si el debug está activado
                if self.db.profile.DebugEnabled then
                    -- Colorea el porcentaje según su valor
                    local colorCode = "|cFF00FF00" -- Verde por defecto
                    if progress < 35 then
                        colorCode = "|cFFFF6600" -- Naranja para bajo progreso
                    elseif progress < 75 then 
                        colorCode = "|cFFFFFF00" -- Amarillo para progreso medio
                    end
                    
                    Debug:Print(format("Misión [%s] - Progreso: %s%.1f%%|r", 
                        title, colorCode, progress), "Progress")
                end
                
                -- Si alcanza o supera el 50% y no se ha reproducido el audio para esta misión
                if progress >= 50 and lastProgress < 50 and not self.db.char.QuestProgressAudioPlayed[questID] then
                    -- Log cuando se detecta el umbral del 50%
                    if self.db.profile.DebugEnabled then
                        Debug:Print(Utils:ColorizeText(format("¡REPRODUCIENDO AUDIO DE PROGRESO POR 50%%! - Misión [%s]", title), "|cFF00FF00"), "Progress")
                    end
                    
                    -- Obtiene el título y el texto de la misión
                    local questText = GetQuestLogQuestText()
                    
                    -- Obtiene información del NPC que dio la misión
                    local type, id = DataModules:GetQuestLogQuestGiverTypeAndID(questID)
                    local npcName = id and DataModules:GetObjectName(type, id) or title
                    local npcGUID = id and Enums.GUID:CanHaveID(type) and Utils:MakeGUID(type, id) or nil
                    
                    -- Crea los datos de sonido y añade a la cola
                    ---@type SoundData
                    local soundData = {
                        event = Enums.SoundEvent.QuestProgress,
                        questID = questID,
                        name = npcName,
                        title = title,
                        text = questText or "",
                        unitGUID = npcGUID,
                        unitIsObjectOrItem = type == Enums.GUID.GameObject or type == Enums.GUID.Item,
                        addedCallback = QuestSoundDataAdded,
                    }
                    SoundQueue:AddSoundToQueue(soundData)
                    
                    -- Marca esta misión como reproducida para no volver a reproducirla
                    self.db.char.QuestProgressAudioPlayed[questID] = true
                elseif self.db.char.QuestProgressAudioPlayed[questID] and progress >= 50 and self.db.profile.DebugEnabled then
                    -- Muestra mensaje informativo cuando la misión ya ha reproducido su audio previamente
                    Debug:Print(format("Audio de progreso para [%s] ya reproducido anteriormente", title), "Progress")
                end
                
                -- NUEVA LÓGICA: Reproducir consejos para misiones con progreso entre 70-100%
                if progress >= 70 and not self.db.profile.Audio.TipPlayedThisSession and self.db.profile.Audio.PlayTips then
                    if progress > lastProgress or lastProgress < 70 then
                        -- Reproducir consejo si el progreso aumentó o si acaba de pasar el umbral del 70%
                        if self.db.profile.DebugEnabled then
                            Debug:Print(Utils:ColorizeText(format("¡Reproduciendo consejo para misión con progreso %.1f%%! - Misión [%s]", progress, title), "|cFF00AAFF"), "Tips")
                        end
                        
                        self:PlayRandomTip()
                        
                        -- Marcar que ya se reprodujo un consejo en esta sesión
                        self.db.profile.Audio.TipPlayedThisSession = true
                    end
                end
                
                -- Guarda el progreso actual para la próxima verificación
                self.db.char.QuestProgress[questID] = progress
            end
        end
    end
    
    -- Restaura la selección original
    SelectQuestLogEntry(currentQuestLogSelection)
end

-- Función para listar archivos MP3 en la carpeta de consejos
function Addon:GetTipFiles()
    local tipFiles = {}
    local tipsPath = "Interface\\AddOns\\AI_VoiceOverData_Turtle\\generated\\sounds\\tips"
    
    -- Si podemos usar C_FileSystem (WoW Retail)
    if C_FileSystem and C_FileSystem.GetDirectoryFiles then
        local files = C_FileSystem.GetDirectoryFiles(tipsPath)
        for _, file in ipairs(files) do
            if string.match(file, "%.mp3$") then
                table.insert(tipFiles, file)
            end
        end
    else
        -- Solo añadimos el archivo que sabemos que existe
        table.insert(tipFiles, "tip1.mp3")
        table.insert(tipFiles, "tip2.mp3")
        table.insert(tipFiles, "tip3.mp3")
        table.insert(tipFiles, "tip4.mp3")
        table.insert(tipFiles, "tip5.mp3")
        table.insert(tipFiles, "tip6.mp3")
        table.insert(tipFiles, "tip7.mp3")
        table.insert(tipFiles, "tip8.mp3")
        table.insert(tipFiles, "tip9.mp3")
        table.insert(tipFiles, "tip10.mp3")
    end
    
    if self.db.profile.DebugEnabled then
        Debug:Print(format("Encontrados %d archivos de consejos", table.getn(tipFiles)), "Tips")
    end
    
    return tipFiles
end

-- Función para reproducir un consejo aleatorio
function Addon:PlayRandomTip()
    local tipFiles = self:GetTipFiles()
    if table.getn(tipFiles) == 0 then
        if self.db.profile.DebugEnabled then
            Debug:Print("No se encontraron archivos de consejos", "Tips")
        end
        return
    end
    
    -- Filtra consejos que ya se reprodujeron recientemente
    local availableTips = {}
    for _, tipFile in ipairs(tipFiles) do
        local isRecent = false
        for _, recentTip in ipairs(self.db.char.RecentlyPlayedTips) do
            if tipFile == recentTip then
                isRecent = true
                break
            end
        end
        
        if not isRecent then
            table.insert(availableTips, tipFile)
        end
    end
    
    -- Si todos los consejos son recientes, usar todos
    if table.getn(availableTips) == 0 then
        availableTips = tipFiles
    end
    
    -- Seleccionar un consejo aleatorio
    local randomIndex = math.random(1, table.getn(availableTips))
    local selectedTip = availableTips[randomIndex]
    
    -- Actualizar la lista de consejos recientes (mantener los últimos 5)
    table.insert(self.db.char.RecentlyPlayedTips, 1, selectedTip)
    if table.getn(self.db.char.RecentlyPlayedTips) > 5 then
        table.remove(self.db.char.RecentlyPlayedTips)
    end
    
    if self.db.profile.DebugEnabled then
        Debug:Print(Utils:ColorizeText(format("¡Reproduciendo consejo! (%s)", selectedTip), "|cFF00AAFF"), "Tips")
    end
    
    -- Crear los datos para la cola (usando tipo Tip que se manejará de forma especial)
    local tipPath = "Interface\\AddOns\\AI_VoiceOverData_Turtle\\generated\\sounds\\tips\\" .. selectedTip
    
    -- Tabla de duraciones para cada archivo de tip
    local tipDurations = {
        ["tip1.mp3"] = 5,
        ["tip2.mp3"] = 7,
        ["tip3.mp3"] = 5,
        ["tip4.mp3"] = 7,
        ["tip5.mp3"] = 7,
        ["tip6.mp3"] = 9,
        ["tip7.mp3"] = 10,
        ["tip8.mp3"] = 9,
        ["tip9.mp3"] = 12,
        ["tip10.mp3"] = 6
    }
    
    ---@type SoundData
    local soundData = {
        event = Enums.SoundEvent.Tip,
        name = "Consejo VoiceOver",
        title = "Consejo",
        filePath = tipPath,
        length = tipDurations[selectedTip] or 7, -- Usar 7 segundos como valor predeterminado
        addedCallback = function(data)
            if SoundQueueUI and SoundQueueUI.frame and SoundQueueUI.frame.portrait and 
               SoundQueueUI.frame.portrait.book then
                SoundQueueUI.frame.portrait.book:Show()
            end
        end
    }
    
    -- Añadir a la cola de sonidos (ahora manejará el tipo Tip correctamente)
    SoundQueue:AddSoundToQueue(soundData)
end
