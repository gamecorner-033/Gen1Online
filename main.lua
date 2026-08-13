-- zip test2

return function(mod)
  print("[Gen1Online] Initializing Gen1Online Asynchronous Threaded 60FPS MMO Mod...")

  local function loadLocal(mod, relative)
    local source = assert(mod:read(relative), "missing " .. relative)
    local chunk, err = load(source, "@" .. (mod.path or "mod") .. "/" .. relative)
    assert(chunk, err)
    return chunk()
  end

  local Quests = loadLocal(mod, "quests/init.lua")(loadLocal, mod)
  local NPCs = loadLocal(mod, "npcs/init.lua")(loadLocal, mod)
  local Doubles = loadLocal(mod, "doubles/init.lua")(loadLocal, mod)

  local Game = require("src.core.Game")
  local Input = require("src.core.Input")
  local OverworldState = require("src.world.OverworldController")
  local BattleState = require("src.battle.BattleState")
  local LinkBattle = require("src.link.LinkBattle")
  local Protocol = require("src.link.Protocol")
  local Party = require("src.pokemon.Party")
  local Boxes = require("src.pokemon.Boxes")
  local Collision = require("src.world.Collision")
  local Font = require("src.render.Font")
  local Menu = require("src.ui.Menu")
  local TextBox = require("src.render.TextBox")
  local Net = require("src.link.Net")
  local CodeEntry = require("src.link.CodeEntry")
  local NPC = require("src.world.NPC")
  local SpriteRenderer = require("src.render.SpriteRenderer")
  local Pokemon = require("src.pokemon.Pokemon")
  local Json = require("src.link.Json")
  local Strings = pcall(require, "src.core.Strings") and require("src.core.Strings") or function(s) return s end

  -- Socket HTTP/HTTPS modules for 24/7 GTS REST Server & Cloudflare Tunnel
  local hasSocketHttp, http = pcall(require, "socket.http")
  if not hasSocketHttp then http = nil end

  local hasHttps, https = pcall(require, "ssl.https")
  if not hasHttps then https = nil end

  local hasLtn12, ltn12 = pcall(require, "ltn12")
  if not hasLtn12 then ltn12 = nil end

  -- Cloudflare Tunnel URL
  local GTS_SERVER_URL = "https://headers-today-vacation-specifications.trycloudflare.com"
  _G.GTS_SERVER_URL = GTS_SERVER_URL
  local isGtsServerConnected = false -- Explicit manual connection required via menu

  -- Lock Game Speed strictly to 1X whenever online and connected to the server to prevent desyncs
  local origLogicSpeed = Game.logicSpeed
  if origLogicSpeed ~= nil then
    Game.logicSpeed = function(self)
      if isGtsServerConnected then
        return 1
      end
      return origLogicSpeed(self)
    end
  end
  -- Universal Overworld / World accessor for Gen 1 (overworld) and Gen 2 (world)
  local function getWorld(g)
    g = g or Game
    if not g then return nil end
    return g.world or g.overworld
  end

  -- Crosswalk data tables for Human-Readable Flag Translation & Bi-Directional Sync
  local EVENT_NAME_TO_ID = {}
  local EVENT_ID_TO_NAME = {}
  local ENGINE_NAME_TO_ID = {}
  local ENGINE_ID_TO_NAME = {}

  do
    -- Load Gen 2 Flag Names
    local okGold, GoldFlags = pcall(require, "tests.drivers.gold.flag_names")
    if okGold and GoldFlags then
      if GoldFlags.events then
        for name, id in pairs(GoldFlags.events) do
          EVENT_NAME_TO_ID[name] = id
          EVENT_ID_TO_NAME[id] = name
        end
      end
      if GoldFlags.engine then
        for name, id in pairs(GoldFlags.engine) do
          ENGINE_NAME_TO_ID[name] = id
          ENGINE_ID_TO_NAME[id] = name
        end
      end
    end

    -- Load Gen 1 Flag Names
    local okG1, G1Flags = pcall(require, "src.save_convert.data.event_flags")
    if okG1 and G1Flags and G1Flags.byBit then
      for id, name in pairs(G1Flags.byBit) do
        if not EVENT_NAME_TO_ID[name] then
          EVENT_NAME_TO_ID[name] = id
        end
        if not EVENT_ID_TO_NAME[id] then
          EVENT_ID_TO_NAME[id] = name
        end
      end
    end
  end

  -- Comprehensive Flag & Map Progression Synchronization Function
  local function syncSaveFlags(save, worldObj)
    if not save or type(save) ~= "table" then return end

    save.flags = save.flags or {}
    save.engineFlags = save.engineFlags or {}
    save.events = save.events or {}
    save.eventFlags = save.eventFlags or {}
    save.mapScenes = save.mapScenes or {}
    save.scriptMem = save.scriptMem or {}

    worldObj = worldObj or (Game and (Game.world or Game.overworld)) or (mod and mod.world)

    -- 1. Bi-directional sync for mapScenes and scriptMem between live World & Save
    if worldObj then
      if worldObj.events and worldObj.events.serialize then
        pcall(function() save.events = worldObj.events:serialize() end)
      end
      if worldObj.engineFlags then
        pcall(function() save.engineFlags = worldObj:engineFlags() end)
      end

      -- Sync mapScenes from live World to save, and back
      if worldObj.mapScenes and type(worldObj.mapScenes) == "table" then
        for mId, scId in pairs(worldObj.mapScenes) do
          save.mapScenes[mId] = tonumber(scId) or 0
        end
      end
      for mId, scId in pairs(save.mapScenes) do
        if worldObj.mapScenes then
          worldObj.mapScenes[mId] = tonumber(scId) or 0
        end
      end

      -- Sync scriptMem from live World to save, and back
      if worldObj.scriptMem and type(worldObj.scriptMem) == "table" then
        for k, v in pairs(worldObj.scriptMem) do
          save.scriptMem[k] = v
        end
      end
      for k, v in pairs(save.scriptMem) do
        if worldObj.scriptMem then
          worldObj.scriptMem[k] = v
        end
      end
    end

    -- 2. Translate save.events bitfield table -> save.eventFlags and save.flags
    if type(save.events) == "table" then
      for byte, row_val in pairs(save.events) do
        local bNum = tonumber(byte)
        local rNum = tonumber(row_val)
        if bNum and rNum then
          for bitn = 0, 7 do
            local mask = 2 ^ bitn
            if math.floor(rNum / mask) % 2 == 1 then
              local fId = bNum * 8 + bitn
              save.eventFlags[fId] = true
              local fName = EVENT_ID_TO_NAME[fId]
              if fName then save.flags[fName] = true end
            end
          end
        end
      end
    end

    -- 3. Translate human-readable string save.flags -> save.events bitfield table
    for name, val in pairs(save.flags) do
      if val == true then
        local fId = EVENT_NAME_TO_ID[name]
        if fId then
          save.eventFlags[fId] = true
          local byte = math.floor(fId / 8)
          local bitn = fId % 8
          local mask = 2 ^ bitn
          local curRow = save.events[byte] or 0
          if math.floor(curRow / mask) % 2 == 0 then
            save.events[byte] = curRow + mask
          end
        end
      end
    end

    -- 4. Translate engineFlags <-> string names
    for eId, eVal in pairs(save.engineFlags) do
      if eVal == true then
        local eName = ENGINE_ID_TO_NAME[eId]
        if eName then save.flags[eName] = true end
      end
    end
    for name, val in pairs(save.flags) do
      if val == true and name:sub(1, 7) == "ENGINE_" then
        local eId = ENGINE_NAME_TO_ID[name]
        if eId then save.engineFlags[eId] = true end
      end
    end

    -- 5. Restore synced events & engineFlags back into live World if present
    if worldObj then
      if worldObj.events and worldObj.events.restore then
        pcall(function() worldObj.events:restore(save.events) end)
      end
      if worldObj.setEngineFlag and type(save.engineFlags) == "table" then
        for eId, eVal in pairs(save.engineFlags) do
          if eVal == true then
            pcall(function() worldObj:setEngineFlag(eId, true) end)
          end
        end
      end
    end

    -- 6. Generate human-readable array of completed flag names for backup file
    local completedNames = {}
    for name, val in pairs(save.flags) do
      if val == true then
        table.insert(completedNames, name)
      end
    end
    table.sort(completedNames)
    save.completedFlagNames = completedNames
  end

  -- Wrap Flags module so flag operations on online saves are safe & persisted
  do
    local okFlags, FlagsMod = pcall(require, "src.script.Flags")
    if okFlags and FlagsMod then
      local origSet = FlagsMod.set
      local origClear = FlagsMod.clear
      local origGet = FlagsMod.get

      FlagsMod.set = function(save, name)
        if save then
          save.flags = save.flags or {}
          save.flags[name] = true
          local fId = EVENT_NAME_TO_ID[name]
          if fId then
            save.eventFlags = save.eventFlags or {}
            save.eventFlags[fId] = true
          end
        end
        if origSet then origSet(save, name) end
        if Game and Game.save then syncSaveFlags(Game.save, Game.world) end
        if isGtsServerConnected and Game and Game.save then
          if performForcedSave then performForcedSave(Game) end
        end
      end

      FlagsMod.clear = function(save, name)
        if save then
          save.flags = save.flags or {}
          save.flags[name] = nil
          local fId = EVENT_NAME_TO_ID[name]
          if fId then
            save.eventFlags = save.eventFlags or {}
            save.eventFlags[fId] = nil
          end
        end
        if origClear then origClear(save, name) end
        if Game and Game.save then syncSaveFlags(Game.save, Game.world) end
        if isGtsServerConnected and Game and Game.save then
          if performForcedSave then performForcedSave(Game) end
        end
      end

      FlagsMod.get = function(save, name)
        if not save then return false end
        save.flags = save.flags or {}
        if origGet then return origGet(save, name) end
        return save.flags[name] == true
      end
    end

    -- Hook Gen 2 Events.set
    local okEv, EventsMod = pcall(require, "src.world.gen2.Events")
    if okEv and EventsMod then
      local origEvSet = EventsMod.set
      EventsMod.set = function(self, id, value)
        if origEvSet then origEvSet(self, id, value) end
        if Game and Game.save then
          syncSaveFlags(Game.save, Game.world)
          if isGtsServerConnected and performForcedSave then
            performForcedSave(Game)
          end
        end
      end
    end

    -- Hook Gen 2 World:setMapScene & World:setScene
    local okW, WorldMod = pcall(require, "src.world.gen2.World")
    if okW and WorldMod then
      local origSetMapScene = WorldMod.setMapScene
      local origSetScene = WorldMod.setScene

      if origSetMapScene then
        WorldMod.setMapScene = function(self, group, mapNum, scene)
          origSetMapScene(self, group, mapNum, scene)
          if Game and Game.save then
            syncSaveFlags(Game.save, self)
            if isGtsServerConnected and performForcedSave then
              performForcedSave(Game)
            end
          end
        end
      end

      if origSetScene then
        WorldMod.setScene = function(self, scene)
          origSetScene(self, scene)
          if Game and Game.save then
            syncSaveFlags(Game.save, self)
            if isGtsServerConnected and performForcedSave then
              performForcedSave(Game)
            end
          end
        end
      end
    end
  end

  -- Networking State
  local netSession = nil
  local isHost = false
  local roomCode = nil
  local lastSendTime = 0
  local lastPlayerX = nil
  local lastPlayerY = nil
  local lastPlayerMap = nil
  local activeBattleAdapter = nil
  local activeParty = nil
  local pendingPartyInvite = nil
  local lastPartySyncTime = 0
  local openPartyMainMenu = nil
 -- Active GtsNetAdapter instance
  local isWaitingForChallenge = false -- Locks player movement while waiting for challenge response
  local challengeWaitTimer = 0
  local lastBattleEndTime = -999 -- Cooldown: ignore challenges for 5s after battle ends
  local inBattle = false          -- Guard: prevents double-starting a battle from duplicate messages
  local clientSessionId = string.format("%08x%08x", love.math.random(10000000, 99999999), os.time())

  -- MMO Multi-Player NPC Registry (trainerId -> NPC object)
  local netNpcs = {}       -- trainerId -> human NPC object
  local netFollowers = {}  -- trainerId -> follower NPC object
  local netPlayerMap = {}  -- trainerId -> player raw position data

  -- Custom Trainer Profile State & MMO Leveling Engine (1 to 100)
  local localTrainerTitle = "ACE TRAINER"
  local localFavoriteMon = "CHARIZARD"
  local mmoLevel = 1
  local mmoXp = 0
  local mmoToken = nil
  local localSelectedSprite = "SPRITE_RED"

  -- Leveling Curve Calculation: starts fast, slows down gradually
  local function calculateXpForLevel(lvl)
    if lvl <= 1 then return 0 end
    return math.floor(50 * ((lvl - 1) ^ 1.8))
  end

  local function calculateLevelFromXp(xp)
    if xp <= 0 then return 1 end
    for lvl = 100, 1, -1 do
      if xp >= calculateXpForLevel(lvl) then
        return lvl
      end
    end
    return 1
  end

  local AVAILABLE_AVATARS = {
    { id = "SPRITE_RED", label = "RED / BOY" },
    { id = "SPRITE_BLUE", label = "BLUE / RIVAL" },
    { id = "SPRITE_GIRL", label = "LEAF / GIRL" },
    { id = "SPRITE_OAK", label = "PROF. OAK" },
    { id = "SPRITE_COOLTRAINER_M", label = "COOLTRAINER M" },
    { id = "SPRITE_COOLTRAINER_F", label = "COOLTRAINER F" },
    { id = "SPRITE_ROCKET", label = "TEAM ROCKET" },
    { id = "SPRITE_LASS", label = "LASS" },
    { id = "SPRITE_YOUNGSTER", label = "YOUNGSTER" },
    { id = "SPRITE_BLACKBELT", label = "BLACKBELT" },
    { id = "SPRITE_SUPER_NERD", label = "SUPER NERD" },
    { id = "SPRITE_HIKER", label = "HIKER" },
    { id = "SPRITE_BEAUTY", label = "BEAUTY" },
    { id = "SPRITE_BUG_CATCHER", label = "BUG CATCHER" },
    { id = "SPRITE_SWIMMER", label = "SWIMMER" },
    { id = "SPRITE_SAILOR", label = "SAILOR" },
    { id = "SPRITE_WAITER", label = "GENTLEMAN" }
  }

  -- Global Trade Station (GTS) Database
  _G.GEN1ONLINE_GTS = _G.GEN1ONLINE_GTS or {
    listings = {},       -- listingId -> listing object
    user_counts = {},    -- trainerId -> active deposit count
    history = {},        -- array of last 50 trade receipts
    claim_boxes = {},    -- trainerId -> list of completed traded mons
    next_id = 1001,
  }
  local gtsDb = _G.GEN1ONLINE_GTS

  -- TRUE ASYNCHRONOUS BACKGROUND THREADING ENGINE (love.thread)
  -- Pos-sync channel: flush-all, keep newest (stale positions discarded)
  local netOutChannel    = _G.love and _G.love.thread and _G.love.thread.getChannel("gen1mmo_out")
  local netInChannel     = _G.love and _G.love.thread and _G.love.thread.getChannel("gen1mmo_in")
  -- Battle channel: FIFO, every message delivered (moves cannot be dropped)
  local battleOutChannel = _G.love and _G.love.thread and _G.love.thread.getChannel("gen1mmo_battle_out")
  local battleInChannel  = _G.love and _G.love.thread and _G.love.thread.getChannel("gen1mmo_battle_in")
  -- Debug channel for thread errors
  local debugChannel    = _G.love and _G.love.thread and _G.love.thread.getChannel("gen1mmo_debug")
  local bgThread = nil

  -- Capture package paths for the thread
  local threadPackagePath = package.path
  local threadPackageCpath = package.cpath
  -- Escape backslashes to avoid invalid escape sequences in the thread code string literal
  local escapedPath = string.gsub(threadPackagePath, "\\", "\\\\")
  local escapedCpath = string.gsub(threadPackageCpath, "\\", "\\\\")

  -- Remote NPC count logging timer
  local remoteCountLogTime = 0

  local threadCode = [[
    -- Inject main thread's package paths (backslashes escaped)
    package.path = "]] .. escapedPath .. [["
    package.cpath = "]] .. escapedCpath .. [["

    require("love.timer")
    local http   = pcall(require, "socket.http") and require("socket.http") or nil
    local https  = pcall(require, "ssl.https")   and require("ssl.https")   or nil
    local ltn12  = pcall(require, "ltn12")        and require("ltn12")        or nil
    local socket = pcall(require, "socket")       and require("socket")       or nil

    local outChan       = love.thread.getChannel("gen1mmo_out")
    local inChan        = love.thread.getChannel("gen1mmo_in")
    local battleOutChan = love.thread.getChannel("gen1mmo_battle_out")
    local battleInChan  = love.thread.getChannel("gen1mmo_battle_in")
    local debugChan     = love.thread.getChannel("gen1mmo_debug")

    local function doPost(url, body)
      local resp_body = {}
      local isHttps = (url:sub(1, 5) == "https")
      
      -- 1. Try LuaSec https if available
      if isHttps and https then
        local ok, err = pcall(https.request, {
          url = url, method = "POST",
          headers = { ["Content-Type"]="application/json",
                      ["Content-Length"]=tostring(#body),
                      ["X-Mod-Version"]="0.3.5.1" },
          source = ltn12 and ltn12.source.string(body),
          sink   = ltn12 and ltn12.sink.table(resp_body),
          timeout = 3.5
        })
        if ok and #resp_body > 0 then
          return table.concat(resp_body)
        end
      end

      -- 2. Try curl.exe for HTTPS
      if isHttps then
        local tempName = "tmp_bg_" .. tostring(os.time()) .. "_" .. tostring(math.random(1000, 9999)) .. ".json"
        local fullPath = nil
        if love and love.filesystem then
          love.filesystem.write(tempName, body)
          fullPath = (love.filesystem.getSaveDirectory() .. "/" .. tempName):gsub("/", "\\")
        end
        if fullPath then
          local cmd = string.format('curl.exe -s --max-time 4 -X POST -H "Content-Type: application/json" -H "X-Mod-Version: 0.3.5.1" -d @"%s" "%s"', fullPath, url)
          local p = io.popen(cmd)
          if p then
            local raw = p:read("*a")
            p:close()
            love.filesystem.remove(tempName)
            if raw and #raw > 0 then return raw end
          else
            love.filesystem.remove(tempName)
          end
        end
      end

      -- 3. Try socket.http for direct HTTP or local fallback
      local targetUrl = isHttps and url:gsub("^https://[^/]+", "http://127.0.0.1:7779") or url
      if http and ltn12 then
        local ok, err = pcall(http.request, {
          url = targetUrl, method = "POST",
          headers = { ["Content-Type"]="application/json",
                      ["Content-Length"]=tostring(#body),
                      ["X-Mod-Version"]="0.3.5.1" },
          source = ltn12.source.string(body),
          sink   = ltn12.sink.table(resp_body),
          timeout = 3.5
        })
        if ok and #resp_body > 0 then
          return table.concat(resp_body)
        end
      end

      return ""
    end

    while true do
      -- 1. BATTLE channel:
      --    send_battle_msg: FIFO — every send must be delivered
      --    poll_battle_msgs: keep-newest — old polls are stale, discard them
      local fifoSends = {}
      local newestPoll = nil
      local bReq = battleOutChan:pop()
      while bReq do
        if bReq.keepNewest then
          newestPoll = bReq  -- discard older polls, keep only latest
        else
          table.insert(fifoSends, bReq)  -- must deliver every send
        end
        bReq = battleOutChan:pop()
      end
      -- Process sends first (order matters)
      for _, req in ipairs(fifoSends) do
        local resp = doPost(req.url, req.body)
        if #resp > 0 then battleInChan:push(resp) end
      end
      -- Then process newest poll only (after all sends are done)
      if newestPoll then
        local resp = doPost(newestPoll.url, newestPoll.body)
        if #resp > 0 then battleInChan:push(resp) end
      end

      -- 2. POSITION-SYNC channel: flush all, keep only the newest
      local req = nil
      local nxt = outChan:pop()
      while nxt do req = nxt; nxt = outChan:pop() end
      if req then
        local resp = doPost(req.url, req.body)
        if #resp > 0 then inChan:push(resp) end
      end

      if socket and socket.sleep then
        socket.sleep(0.008)
      elseif love and love.timer and love.timer.sleep then
        love.timer.sleep(0.008)
      end
    end
  ]]

  if _G.love and _G.love.thread then
    pcall(function()
      bgThread = _G.love.thread.newThread(threadCode)
      bgThread:start()
    end)
  end

  -- Optional: print debug messages from thread (call occasionally in love.update)
  local function printThreadDebug()
    if debugChannel then
      local msg = debugChannel:pop()
      while msg do
        print("[Thread Debug] " .. tostring(msg))
        msg = debugChannel:pop()
      end
    end
  end

  -- Universal Transport Helper (Supports direct HTTPS via LuaSec, curl.exe popen fallback for Windows/Linux/Mac, and HTTP)
  local function makeHttpRequest(reqTable)
    reqTable.timeout = reqTable.timeout or 4.0
    local isHttps = (reqTable.url:sub(1, 5) == "https")

    -- 1. Try LuaSec https if available
    if isHttps and https then
      local ok, res, code, headers, status = pcall(https.request, reqTable)
      if ok and code and code >= 200 and code < 400 then
        return ok, res, code, headers, status
      end
    end

    -- 2. Try curl.exe for HTTPS when LuaSec is not available in Love2D
    if isHttps and not https then
      local timeoutSec = math.ceil(reqTable.timeout or 4.0)
      local isPost = (reqTable.method == "POST")
      local tempFile = nil
      local cmd = nil

      if isPost and reqTable.source and love and love.filesystem then
        local chunks = {}
        while true do
          local chunk = reqTable.source()
          if not chunk then break end
          table.insert(chunks, chunk)
        end
        local bodyStr = table.concat(chunks)
        tempFile = "tmp_req_" .. tostring(os.time()) .. "_" .. tostring(love.math.random(1000, 9999)) .. ".json"
        love.filesystem.write(tempFile, bodyStr)
        local fullTempPath = (love.filesystem.getSaveDirectory() .. "/" .. tempFile):gsub("/", "\\")
        cmd = string.format('curl.exe -s --max-time %d -X POST -H "Content-Type: application/json" -H "X-Mod-Version: %s" -d @"%s" "%s"',
          timeoutSec, MOD_VERSION, fullTempPath, reqTable.url)
      else
        cmd = string.format('curl.exe -s --max-time %d -H "X-Mod-Version: %s" "%s"',
          timeoutSec, MOD_VERSION, reqTable.url)
      end

      local p = io.popen(cmd)
      if p then
        local rawResp = p:read("*a")
        p:close()
        if tempFile and love and love.filesystem then
          love.filesystem.remove(tempFile)
        end
        if rawResp and #rawResp > 0 then
          if reqTable.sink then
            reqTable.sink(rawResp)
          end
          return true, 1, 200, {}, "HTTP/1.1 200 OK"
        end
      else
        if tempFile and love and love.filesystem then
          love.filesystem.remove(tempFile)
        end
      end
    end

    -- 3. Standard HTTP via socket.http
    if http and not isHttps then
      local ok, res, code, headers, status = pcall(http.request, reqTable)
      if ok and code then return ok, res, code, headers, status end
    end

    -- 4. Fallback to local server http://127.0.0.1:7779 if Cloudflare tunnel fails
    if isHttps and http then
      local fallbackUrl = reqTable.url:gsub("^https://[^/]+", "http://127.0.0.1:7779")
      local altTable = {}
      for k, v in pairs(reqTable) do altTable[k] = v end
      altTable.url = fallbackUrl
      local ok, res, code, headers, status = pcall(http.request, altTable)
      if ok and code then return ok, res, code, headers, status end
    end

    return false, nil, nil, nil, nil
  end

  local MOD_VERSION = "0.3.5.1"

  -- Generation detection: "gen1" or "gen2"
  local currentGeneration = "gen1"
  do
    local okGv, GvMod = pcall(require, "src.core.GameVersion")
    if okGv and GvMod and GvMod.get then
      local vid = GvMod.get()
      if vid == "gold" or vid == "silver" or vid == "crystal" then
        currentGeneration = "gen2"
      end
    end
  end
  local isGen2 = (currentGeneration == "gen2")

  -- Generation-aware Starting Spawn Locations (Johto / New Bark Town for Gold, Kanto / Pallet Town for Gen 1)
  local defaultStartingOutdoor = isGen2 and "NEW_BARK_TOWN" or "PALLET_TOWN"
  local defaultStartingOutdoorX = isGen2 and 13 or 5
  local defaultStartingOutdoorY = isGen2 and 6 or 6
  local defaultStartingIndoor = isGen2 and "PLAYERS_HOUSE_2F" or "REDS_HOUSE_2F"
  local defaultStartingIndoorX = isGen2 and 3 or 3
  local defaultStartingIndoorY = isGen2 and 3 or 6

  -- Client Game Version (Red/Blue/Yellow) & Recomp Engine Version Detector
  local function getClientVersionInfo()
    local gameName = "Pokemon Red"
    local okGv, GvMod = pcall(require, "src.core.GameVersion")
    if okGv and GvMod and GvMod.get then
      local vid = GvMod.get()
      gameName = (GvMod.VERSIONS and GvMod.VERSIONS[vid] and GvMod.VERSIONS[vid].displayName) or (tostring(vid):sub(1,1):upper() .. tostring(vid):sub(2))
    end

    local recompVer = "0.0.0-dev"
    local okVer, VerMod = pcall(require, "src.core.Version")
    if okVer and VerMod and VerMod.engine then
      recompVer = "v" .. tostring(VerMod.engine)
    end
    return gameName, recompVer
  end


  -- Profanity Filter Module Loader
  local Profanity = nil
  local okProf, profMod = pcall(require, "mods.gen1online-gamecorner.other.profanity")
  if okProf and profMod then
    Profanity = profMod
  else
    local okProf2, profMod2 = pcall(require, "other.profanity")
    if okProf2 and profMod2 then Profanity = profMod2 end
  end

  local function gtsApiGet(path, timeout)
    local response_body = {}
    local separator = path:find("?") and "&" or "?"
    local fullPath = path .. separator .. "version=" .. MOD_VERSION .. "&modVersion=" .. MOD_VERSION
    local ok, res, code, headers, status = makeHttpRequest({
      url = GTS_SERVER_URL .. fullPath,
      method = "GET",
      headers = {
        ["X-Mod-Version"] = MOD_VERSION
      },
      sink = function(chunk)
        if chunk then table.insert(response_body, chunk) end
      end,
      timeout = timeout or 4.0
    })
    if ok and #response_body > 0 then
      local str = table.concat(response_body)
      local okJson, data = pcall(Json.decode, str)
      if okJson and data then return data end
    end
    return nil
  end

  local function gtsApiPost(payload, timeout)
    payload = payload or {}
    local gName, rVer = getClientVersionInfo()
    payload.modVersion = MOD_VERSION
    payload.version = MOD_VERSION
    payload.gameVersion = gName
    payload.recompVersion = rVer
    local jsonStr = Json.encode(payload)
    local response_body = {}
    local sent = false
    local ok, res, code, headers, status = makeHttpRequest({
      url = GTS_SERVER_URL .. "/gts",
      method = "POST",
      headers = {
        ["Content-Type"] = "application/json",
        ["Content-Length"] = tostring(#jsonStr),
        ["X-Mod-Version"] = MOD_VERSION
      },
      source = function()
        if not sent then sent = true; return jsonStr end
        return nil
      end,
      sink = function(chunk)
        if chunk then table.insert(response_body, chunk) end
      end,
      timeout = timeout or 4.0
    })
    if ok and #response_body > 0 then
      local str = table.concat(response_body)
      local okJson, data = pcall(Json.decode, str)
      if okJson and data then return data end
    end
    return nil
  end  -- Text Auto-Wrapping & 2-Line Dialogue Page Break Formatter
  local function wrapText(str, maxLen)
    maxLen = maxLen or 17
    if not str or #str == 0 then return "" end
    local rawLines = {}
    for paragraph in tostring(str):gmatch("[^\r\n\f]+") do
      local currentLine = ""
      for word in paragraph:gmatch("%S+") do
        if #currentLine == 0 then
          currentLine = word
        elseif #currentLine + 1 + #word <= maxLen then
          currentLine = currentLine .. " " .. word
        else
          table.insert(rawLines, currentLine)
          currentLine = word
        end
      end
      if #currentLine > 0 then
        table.insert(rawLines, currentLine)
      end
    end
    -- Group every 2 lines into a dialog page separated by \f
    local pages = {}
    for i = 1, #rawLines, 2 do
      local l1 = rawLines[i]
      local l2 = rawLines[i + 1]
      if l2 then
        table.insert(pages, l1 .. "\n" .. l2)
      else
        table.insert(pages, l1)
      end
    end
    return table.concat(pages, "\f")
  end

  -- Helper to list all Gen 1 Pokémon species sorted alphabetically
  local function getAllGen1Species(data)
    local speciesList = {}
    if data and data.pokemon then
      for key, def in pairs(data.pokemon) do
        local name = def.name or key
        if type(key) == "string" and name and def.dex and def.dex >= 1 and def.dex <= 151 then
          table.insert(speciesList, { id = key, name = name, dex = def.dex })
        end
      end
      table.sort(speciesList, function(a, b) return a.name < b.name end)
    end
    return speciesList
  end

  -- Fully Asynchronous 100% Non-Blocking Network Adapter for LinkBattle
  --
  -- CRITICAL CONTRACT (matches Net.lua API used by LinkBattle.lua):
  --   LinkBattle calls update() then IMMEDIATELY poll() on the same frame.
  --   update() MUST drain any available battle responses into self.inbox
  --   synchronously, before poll() is called. Pushing to a background thread
  --   and reading back later means poll() will always see an empty inbox.
  --
  --   Solution: update() does TWO things:
  --     1. Drain battleInChannel (background thread responses) -> self.inbox
  --     2. Push a fresh poll_battle_msgs request for NEXT frame's responses
  local GtsNetAdapter = {}
  GtsNetAdapter.__index = GtsNetAdapter

  function GtsNetAdapter.new(myId, targetId, roomId)
    local self = setmetatable({}, GtsNetAdapter)
    self.myId = tostring(myId)
    self.targetId = tostring(targetId)
    self.roomId = roomId or ("ROOM_" .. self.myId .. "_" .. self.targetId)
    self.inbox = {}
    self.closed = false
    self.paired = true   -- already paired when battle starts
    activeBattleAdapter = self
    return self
  end

  function GtsNetAdapter:send(msg)
    -- IMPORTANT: Suppress 'bye' messages from reaching the server room.
    -- LinkBattle.lua calls net:send({type="bye"}) in origFinish, AFTER our
    -- battle.finish wrapper has already called clear_battle_room. If 'bye'
    -- is forwarded, it arrives in the room queue AFTER the clear and poisons
    -- the opponent's next battle, causing an instant "other player left" loop.
    -- Room cleanup is handled server-side by clear_battle_room, so bye is
    -- unnecessary and actively harmful here.
    if msg and msg.type == "bye" then return end

    -- FIFO battle channel: send_battle_msg must NEVER be dropped
    if battleOutChannel then
      battleOutChannel:push({
        url = GTS_SERVER_URL .. "/gts",
        body = Json.encode({
          action = "send_battle_msg",
          modVersion = MOD_VERSION,
          version = MOD_VERSION,
          roomId = self.roomId,
          targetId = self.targetId,
          msg = msg
        })
      })
    end
  end

  function GtsNetAdapter:update()
    -- STEP 1: Drain any battle responses that the background thread has
    --   already fetched into self.inbox NOW so poll() sees them this frame.
    if battleInChannel then
      local bStr = battleInChannel:pop()
      while bStr do
        local ok, bRes = pcall(Json.decode, bStr)
        if ok and bRes and bRes.msgs then
          for _, m in ipairs(bRes.msgs) do
            table.insert(self.inbox, m)
          end
        end
        bStr = battleInChannel:pop()
      end
    end

    -- STEP 2: Push a fresh poll request every frame (keepNewest=true so
    --   the background thread discards stale polls if they pile up).
    --   No rate limit needed — the background thread coalesces them.
    if not self.closed and battleOutChannel then
      battleOutChannel:push({
        keepNewest = true,   -- ← tells background thread to discard older polls
        url = GTS_SERVER_URL .. "/gts",
        body = Json.encode({
          action = "poll_battle_msgs",
          modVersion = MOD_VERSION,
          version = MOD_VERSION,
          roomId = self.roomId,
          myId = self.myId
        })
      })
    end
  end

  function GtsNetAdapter:poll()
    local out = self.inbox
    self.inbox = {}
    return out
  end

  function GtsNetAdapter:take(msgType)
    for idx, msg in ipairs(self.inbox) do
      if not msgType or (type(msg) == "table" and msg.type == msgType) then
        return table.remove(self.inbox, idx)
      end
    end
    return nil
  end

  function GtsNetAdapter:hasPending()
    return #self.inbox > 0
  end

  function GtsNetAdapter:getStatus()
    if self.closed then return "closed" end
    return "paired"
  end

  function GtsNetAdapter:close()
    -- Mark closed and clear the global reference.
    -- We do NOT send a "bye" via the room queue here — the room is
    -- cleared server-side by clear_battle_room in battle.finish, so
    -- sending a bye would only poison the NEXT battle's fresh room
    -- if clear_battle_room races with the new poll.
    self.closed = true
    if activeBattleAdapter == self then
      activeBattleAdapter = nil
    end
  end

  local syncMultiNetPlayers = nil
  local getTrainerInfo = nil
  local startPvpBattle = nil
  local startLinkTrade = nil
  local saveOnlineAccount = nil
  local loadOnlineAccount = nil
  local syncLocalProfile = nil
  local performForcedSave = nil
  local writeOnlineSave = nil
  local loadOnlineSave = nil
  local addMmoXp = nil
  local openOnlineOptionsMenu = nil
  local openFreshOnlinePlayerMenu = nil
  local openRedeemTokenMenu = nil
  local openMyProfileMenu = nil
  local openTrainerCardScreen = nil
  local openMmoLevelInfoScreen = nil
  local openMmoChatMenu = nil
  local handleDisconnect = nil
  local handleConnectToServer = nil
  local applyPlayerSprite = nil

  -- NOTE: Battle responses are drained by GtsNetAdapter:update() directly, not here.
  --       This function only handles position-sync and challenge/trade signals.
  local function processGlobalThreadMessages(game)
    -- Drain ALL queued position-sync responses (drain-all prevents stale challenge
    -- data from sitting in netInChannel across multiple frames and firing after the
    -- battle ends when the inBattle / cooldown guards are no longer active).
    if not netInChannel then return end

    local respStr = netInChannel:pop()
    while respStr do
      local ok, res = pcall(Json.decode, respStr)
      if ok and res then
        if res.error == "VERSION_MISMATCH" then
          handleDisconnect(game, string.format("VERSION MISMATCH!\nSERVER IS ON V%s\nCLIENT IS ON V%s\nPLEASE UPDATE MOD!", res.serverVersion or "NEW", MOD_VERSION))
          return
        elseif res.error == "ALREADY_LOGGED_IN" or res.error == "BANNED" then
          handleDisconnect(game, (res.message or "ACCOUNT ALREADY ACTIVE ON ANOTHER DEVICE!\nDISCONNECTED FOR SAFETY."))
          return
        end

        if res.success then
          -- Party invite receiver
          if res.partyInvite and not pendingPartyInvite and not activeParty then
            pendingPartyInvite = res.partyInvite
            local inv = res.partyInvite
            local tid, tName = getTrainerInfo(game.save)
                        local pMenu = {
              {
                label = "ACCEPT INVITE",
                onSelect = function()
                    local gWorld = getWorld(game)
                    local curMap = (gWorld and gWorld.map and gWorld.map.id) or defaultStartingOutdoor
                    local curX = (gWorld and gWorld.player and gWorld.player.cellX) or defaultStartingOutdoorX
                    local curY = (gWorld and gWorld.player and gWorld.player.cellY) or defaultStartingOutdoorY
                    local aRes = gtsApiPost({
                      action = "party_accept",
                      trainerId = tid,
                      name = tName,
                      level = mmoLevel or 1,
                      map = curMap,
                      x = curX,
                      y = curY,
                      spriteId = localSelectedSprite
                    }, 1.5)
                    if aRes and aRes.success then
                      activeParty = aRes.party
                      pendingPartyInvite = nil
                      game.stack:push(TextBox.new(game, wrapText("JOINED CO-OP PARTY!\nALL XP IS NOW SHARED WITH MEMBERS!")))
                    else
                      pendingPartyInvite = nil
                      game.stack:push(TextBox.new(game, wrapText("COULD NOT JOIN PARTY!")))
                    end
                  end
                },
                {
                  label = "DECLINE",
                  onSelect = function()
                    gtsApiPost({ action = "party_decline", trainerId = tid }, 1.0)
                    pendingPartyInvite = nil
                  end
                }
              }
              local invMsg = string.format("%s INVITED YOU TO A CO-OP PARTY!\nACCEPT INVITE?", inv.fromName or "A TRAINER")
              game.stack:push(TextBox.new(game, wrapText(invMsg), function()
                game.stack:push(Menu.new(game, pMenu, { tx = 0, ty = 0, tw = 20, maxVisible = 6, startCloses = true }))
              end))
            end

            -- Shared Party XP receiver
            if res.partyXp and #res.partyXp > 0 then
              for _, xev in ipairs(res.partyXp) do
                addMmoXp(game, "party_share", xev.xp or 50)
                game.stack:push(TextBox.new(game, wrapText(string.format("PARTY CO-OP BONUS!\n+%d XP FROM %s!", xev.xp or 50, xev.fromName or "TEAMMATE"))))
              end
            end

            if res.party ~= nil then
              activeParty = res.party
            end
            -- 1. Route multi-player positions if overworld active
            local gWorld = getWorld(game)
            if res.players and gWorld then
              syncMultiNetPlayers(game, gWorld, res.players)
            end

          -- 2. Route pending battle messages directly to active GtsNetAdapter
          if res.msgs and activeBattleAdapter then
            for _, m in ipairs(res.msgs) do
              table.insert(activeBattleAdapter.inbox, m)
            end
          end

          -- 3. Live Network Challenge Receiver (PVP Battle or Trade Popup!)
          if res.challenge then
            local nowT = (_G.love and _G.love.timer and _G.love.timer.getTime) and _G.love.timer.getTime() or os.time()
            local inCooldown = (nowT - lastBattleEndTime) < 5.0

            if inCooldown then
              -- Post-battle cooldown: silently wipe stale challenges from the server
              -- so they stop appearing on every sync_pos response.
              local myId = getTrainerInfo(game.save)
              if myId then
                gtsApiPost({ action = "clear_challenge", trainerId = myId }, 0.5)
              end
            else
              local challengerName = res.challenge.fromName or "TRAINER"
              local challengerId = res.challenge.fromId
              local cType = res.challenge.type or "PVP"
              local remotePartyPacked = res.challenge.party or {}
              local sharedSeed = res.challenge.seed or 12345
              local roomId = res.challenge.roomId

              if cType == "ACCEPT_PVP" then
                -- Guard: never start a second battle if one is already running
                if inBattle then
                  local myId = getTrainerInfo(game.save)
                  gtsApiPost({ action = "clear_challenge", trainerId = myId }, 0.5)
                else
                  isWaitingForChallenge = false
                  local myId = getTrainerInfo(game.save)
                  gtsApiPost({ action = "clear_challenge", trainerId = myId }, 0.5)

                  if not game.save or not game.save.party or #game.save.party == 0 then
                    game.stack:push(TextBox.new(game, wrapText("YOU NEED AT LEAST 1 POKéMON IN YOUR PARTY TO BATTLE!")))
                  elseif not remotePartyPacked or #remotePartyPacked == 0 then
                    game.stack:push(TextBox.new(game, wrapText(string.format("%s HAS NO POKéMON IN THEIR PARTY!", challengerName or "FOE"))))
                  else
                    startPvpBattle(game, challengerName, challengerId, remotePartyPacked, true, sharedSeed, roomId)
                  end
                end
              elseif cType == "ACCEPT_TRADE" then
                isWaitingForChallenge = false
                local myId = getTrainerInfo(game.save)
                gtsApiPost({ action = "clear_challenge", trainerId = myId }, 0.5)
                if not game.save or not game.save.party or #game.save.party == 0 then
                  game.stack:push(TextBox.new(game, wrapText("YOU NEED AT LEAST 1 POKéMON IN YOUR PARTY TO TRADE!")))
                else
                  startLinkTrade(game, challengerName, challengerId, false, roomId)
                end
              elseif cType == "DECLINE" then
                isWaitingForChallenge = false
                local myId = getTrainerInfo(game.save)
                gtsApiPost({ action = "clear_challenge", trainerId = myId }, 0.5)
                game.stack:push(TextBox.new(game, wrapText("CHALLENGE DECLINED BY OPPONENT.")))
              elseif cType == "PVP" or cType == "PVP_DOUBLES" or cType == "TRADE" then
                local myId, myName = getTrainerInfo(game.save)
                local promptItems = {
                  {
                    label = (cType == "PVP_DOUBLES") and "ACCEPT 2V2 DOUBLES" or string.format("ACCEPT %s", cType),
                    onSelect = function()
                      gtsApiPost({ action = "clear_challenge", trainerId = myId }, 0.5)
                      local myPackedParty = Protocol.packParty(game.save and game.save.party or {})
                      if cType == "PVP" or cType == "PVP_DOUBLES" then
                        if not game.save or not game.save.party or #game.save.party == 0 then
                          game.stack:push(TextBox.new(game, wrapText("YOU NEED AT LEAST 1 POKéMON IN YOUR PARTY TO BATTLE!")))
                          return
                        end
                        if not remotePartyPacked or #remotePartyPacked == 0 then
                          game.stack:push(TextBox.new(game, wrapText(string.format("%s HAS NO POKéMON IN THEIR PARTY!", challengerName or "FOE"))))
                          return
                        end
                        gtsApiPost({
                          action = "send_challenge",
                          targetId = challengerId,
                          fromId = myId,
                          fromName = myName,
                          challengeType = "ACCEPT_PVP",
                          party = myPackedParty,
                          seed = sharedSeed,
                          roomId = roomId
                        }, 1.5)
                        startPvpBattle(game, challengerName, challengerId, remotePartyPacked, false, sharedSeed, roomId)
                      elseif cType == "TRADE" then
                        if not game.save or not game.save.party or #game.save.party == 0 then
                          game.stack:push(TextBox.new(game, wrapText("YOU NEED AT LEAST 1 POKéMON IN YOUR PARTY TO TRADE!")))
                          return
                        end
                        gtsApiPost({
                          action = "send_challenge",
                          targetId = challengerId,
                          fromId = myId,
                          fromName = myName,
                          challengeType = "ACCEPT_TRADE",
                          roomId = roomId
                        }, 1.5)
                        startLinkTrade(game, challengerName, challengerId, true, roomId)
                      end
                    end
                  },
                  {
                    label = "DECLINE",
                    onSelect = function()
                      gtsApiPost({ action = "clear_challenge", trainerId = myId }, 0.5)
                      gtsApiPost({
                        action = "send_challenge",
                        targetId = challengerId,
                        fromId = myId,
                        fromName = myName,
                        challengeType = "DECLINE"
                      }, 0.5)
                    end
                  }
                }
                game.stack:push(Menu.new(game, promptItems, { tx = 1, ty = 1, tw = 18, th = 6 }))
              end
            end -- end cooldown else
          end -- end if res.challenge
        end -- end if res.success
      end -- end if ok and res
      respStr = netInChannel:pop()
    end
  end

  -- Sync GTS Database with 24/7 Server
  local function fetchGtsServerSync(trainerId)
    local data = gtsApiGet("/gts/browse", 3.0)
    if data and data.success then
      isGtsServerConnected = true
      gtsDb.listings = data.listings or {}
      gtsDb.history = data.history or {}

      if trainerId then
        local claimData = gtsApiGet("/gts/claims?trainerId=" .. tostring(trainerId), 3.0)
        if claimData and claimData.success then
          gtsDb.claim_boxes[tostring(trainerId)] = claimData.claims or {}
        end
      end
      return true
    end
    return false
  end

  -- Patch SPRITE_RED with walker = true for 3D Voxel camera while preserving GBC color palette
  pcall(function()
    mod.content.sprites:patch("SPRITE_RED", {
      walker = true,
    })
  end)

  local activeQuestsCache = {}

  local function fetchPlayerQuests(game)
    game = game or Game
    local tid = getTrainerInfo and getTrainerInfo(game and game.save) or "100001"
    local data = gtsApiPost({ action = "get_quests", trainerId = tid }, 1.5)
    if data and data.success and data.quests then
      activeQuestsCache = data.quests
      return activeQuestsCache
    end
    return activeQuestsCache or {}
  end

  local function getTrainerId(save)
    local tid, tName = getTrainerInfo(save)
    return tid
  end

  -- Trainer ID & Name Helper
  getTrainerInfo = function(save)
    local p = save and save.player
    if not p then return 12345, "TRAINER" end
    if not p.id then
      -- IMPORTANT: plain math.random() is NOT auto-seeded by Lua/LOVE, so two
      -- players who each roll their very first trainer ID around the same
      -- point in their own process's (identical, unseeded) random sequence
      -- can end up with the SAME id. Since the server keys active_players by
      -- trainerId, a collision means one player's sync_pos overwrites the
      -- other's entry, and each of them filters out anything matching "self"
      -- -- which now also matches the other player -- making them invisible
      -- to each other. love.math's RNG is auto-seeded per-process (time+PID)
      -- by LOVE itself, so it doesn't collide across separate machines.
      if _G.love and _G.love.math and _G.love.math.random then
        p.id = love.math.random(10000, 99999)
      else
        math.randomseed(os.time() + math.floor((os.clock() or 0) * 1000000))
        p.id = math.random(10000, 99999)
      end
    end
    return p.id, p.name or "TRAINER"
  end

  -- Calculate Total Owned Badges from Save
  -- Calculate Total Owned Badges from Save
  local function getBadgeCount(save)
    if not save or not save.badges then return 0 end
    local count = 0
    for _, b in pairs(save.badges) do
      if b then count = count + 1 end
    end
    return count
  end

  -- Calculate Total Pokédex Caught from Save
  local function getPokedexCount(save)
    if not save or not save.pokedex or not save.pokedex.owned then return 0 end
    local count = 0
    for _, owned in pairs(save.pokedex.owned) do
      if owned then count = count + 1 end
    end
    return count
  end

  -- Dual Save State Storage: Dedicated Online MMO Save File (Independent of Local save.lua / save_gold.lua)
  local function getOnlineSaveFiles()
    local gv = "red"
    local okGv, GvMod = pcall(require, "src.core.GameVersion")
    if okGv and GvMod and GvMod.get then gv = GvMod.get() or "red" end
    local suffix = (gv == "blue" and "_blue") or (gv == "yellow" and "_yellow") or (gv == "gold" and "_gold") or ""
    return "save_online" .. suffix .. ".lua", "save_online" .. suffix .. ".lua.bak", "save_online" .. suffix .. ".lua.tmp"
  end

  local offlineSaveBackup = nil

  local function loadOfflineSave()
    if isGen2 then
      local okGen2Save, Gen2SaveModule = pcall(require, "src.core.gen2.Save")
      if okGen2Save and Gen2SaveModule and Gen2SaveModule.load then
        local data = Gen2SaveModule.load("gold")
        if data then return data end
      end
    end
    local okSaveData, SaveDataModule = pcall(require, "src.core.SaveData")
    if okSaveData and SaveDataModule and SaveDataModule.load then
      local data = SaveDataModule.load()
      if data then return data end
    end
    return nil
  end

  loadOnlineSave = function()
    local SaveSerializer = require("src.core.SaveSerializer")
    local fs = love.filesystem
    if not fs then return nil end
    local saveFile, bakFile, tmpFile = getOnlineSaveFiles()
    local content = fs.read(saveFile)
    if not content then
      content = fs.read(bakFile) or fs.read(tmpFile)
    end
    if not content then return nil end
    local ok, data = pcall(SaveSerializer.decode, content)
    if ok and data and type(data) == "table" then
      syncSaveFlags(data, Game and (Game.world or Game.overworld))
      return data
    end
    return nil
  end

  writeOnlineSave = function(saveTable)
    if not saveTable or type(saveTable) ~= "table" then return false end
    syncSaveFlags(saveTable, Game and (Game.world or Game.overworld))

    local SaveSerializer = require("src.core.SaveSerializer")
    local fs = love.filesystem
    if not fs then return false end
    local saveFile, bakFile, tmpFile = getOnlineSaveFiles()
    local encoded = SaveSerializer.encode(saveTable)
    if fs.getInfo(saveFile) then
      local prev = fs.read(saveFile)
      if prev then fs.write(bakFile, prev) end
    end
    fs.write(tmpFile, encoded)
    fs.remove(saveFile)
    fs.write(saveFile, encoded)
    fs.remove(tmpFile)
    return true
  end

  -- Global Save Guards: Intercept all Start Menu and in-game saves while online
  -- 1. Gen 1 SaveData.save Guard
  local okSaveData, SaveDataModule = pcall(require, "src.core.SaveData")
  if okSaveData and SaveDataModule and SaveDataModule.save then
    local origSaveDataSave = SaveDataModule.save
    SaveDataModule.save = function(data, mods)
      if isGtsServerConnected or (data and data.onlineAccount and data.onlineAccount.token) then
        saveOnlineAccount(data)
        return writeOnlineSave(data)
      end
      return origSaveDataSave(data, mods)
    end
  end

  -- 2. Gen 2 / Gold Save.save Guard
  local okGen2Save, Gen2SaveModule = pcall(require, "src.core.gen2.Save")
  if okGen2Save and Gen2SaveModule and Gen2SaveModule.save then
    local origGen2Save = Gen2SaveModule.save
    Gen2SaveModule.save = function(save)
      if isGtsServerConnected or (save and save.onlineAccount and save.onlineAccount.token) then
        saveOnlineAccount(save)
        return writeOnlineSave(save)
      end
      return origGen2Save(save)
    end
  end

  -- Forced Game Save helper (Captures live coordinates & routes strictly to save_online when online)
  performForcedSave = function(game)
    if not game or not game.save then return end
    if not isGtsServerConnected then
      -- Offline saves are written explicitly by in-game Save menu, never forced on every event
      return
    end

    syncSaveFlags(game.save, game.world)

    if game.snapshotSave then
      pcall(function() game:snapshotSave() end)
    elseif game.overworld and game.overworld.captureSave then
      pcall(function() game.overworld:captureSave(game.save) end)
    end
    saveOnlineAccount(game.save)
    writeOnlineSave(game.save)
  end

  -- Sync Local Trainer Profile & Online Account to Server
  loadOnlineAccount = function(save)
    if not save then return end
    save.onlineAccount = save.onlineAccount or {}
    local acc = save.onlineAccount
    if acc.name and save.player then save.player.name = acc.name end
    if acc.trainerId and save.player then save.player.id = acc.trainerId end
    mmoLevel = acc.level or 1
    mmoXp = acc.xp or 0
    mmoToken = acc.token or nil
    localSelectedSprite = acc.spriteId or "SPRITE_RED"
    if acc.title then localTrainerTitle = acc.title end
    if acc.favoriteMon then localFavoriteMon = acc.favoriteMon end
    if acc.blackouts then save.blackoutCount = acc.blackouts end

    -- Sanitize pcItems: migrate any legacy array-of-objects format to { ITEM_ID = count }
    -- (PlayerPC.lua and Bag.lua expect pairs() over string keys, not ipairs over arrays)
    local function sanitizeItemMap(tbl)
      if type(tbl) ~= "table" then return {} end
      -- Check if it's already in the correct key-value format (string keys = item IDs)
      for k, v in pairs(tbl) do
        if type(k) == "string" and type(v) == "number" then
          return tbl -- already correct format
        end
        -- It's array-of-objects: { { item = "POTION", count = 1 }, ... }
        if type(k) == "number" and type(v) == "table" then
          local out = {}
          for _, entry in ipairs(tbl) do
            if type(entry) == "table" and entry.item then
              out[entry.item] = (out[entry.item] or 0) + (entry.count or 1)
            end
          end
          return out
        end
        break
      end
      return tbl
    end

    save.pcItems = sanitizeItemMap(save.pcItems)
    if not next(save.pcItems) then
      save.pcItems = { POTION = 1 }
    end

    save.inventory = sanitizeItemMap(save.inventory)
  end

  saveOnlineAccount = function(save)
    if not save then return end
    save.onlineAccount = save.onlineAccount or {}
    save.onlineAccount.trainerId = (save.player and save.player.id) or nil
    save.onlineAccount.name = (save.player and save.player.name) or "RED"
    save.onlineAccount.level = mmoLevel
    save.onlineAccount.xp = mmoXp
    save.onlineAccount.token = mmoToken
    save.onlineAccount.spriteId = localSelectedSprite
    save.onlineAccount.title = localTrainerTitle
    save.onlineAccount.favoriteMon = localFavoriteMon
    save.onlineAccount.blackouts = save.blackoutCount or 0
  end

  syncLocalProfile = function(game, winDelta)
    if not game or not game.save then return end
    loadOnlineAccount(game.save)
    local trainerId, trainerName = getTrainerInfo(game.save)
    syncSaveFlags(game.save, game.world or (mod and mod.world))

    -- Pack badges list
    local badgesList = {}
    if game.save.badges and type(game.save.badges) == "table" then
      for bName, hasB in pairs(game.save.badges) do
        if hasB == true then table.insert(badgesList, bName) end
      end
    end

    -- Pack party summary
    local partySummary = {}
    if game.save.party then
      for _, mon in ipairs(game.save.party) do
        table.insert(partySummary, {
          species = mon.species,
          level = mon.level,
          nickname = mon.nickname,
          hp = mon.hp,
          maxHp = (mon.stats and mon.stats.hp) or mon.hp
        })
      end
    end

    gtsApiPost({
      action = "update_profile",
      trainerId = trainerId,
      name = trainerName,
      title = localTrainerTitle,
      badges = getBadgeCount(game.save),
      badgesList = badgesList,
      pokedexCount = getPokedexCount(game.save),
      pvpWins = winDelta or 0,
      blackouts = (game.save and game.save.blackoutCount) or 0,
      favoriteMon = localFavoriteMon,
      flags = game.save.flags,
      completedFlags = game.save.completedFlagNames or {},
      mapScenes = game.save.mapScenes or {},
      party = partySummary,
      money = (game.save.player and game.save.player.money) or game.save.money or 0,
      coins = (game.save.player and game.save.player.coins) or game.save.coins or 0,
      map = (game.save.player and game.save.player.map) or (game.save.position and game.save.position.map) or "UNKNOWN"
    }, 1.5)
  end

  addMmoXp = function(game, xpType, extraAmount, extraFields)
    local rewards = {
      catch = 50,
      wild_battle = 15,
      trainer_battle = 40,
      pvp_win = 100,
      pvp_loss = 25,
      breeding = 60
    }
    local delta = extraAmount or rewards[xpType] or 10
    local oldLevel = mmoLevel
    mmoXp = mmoXp + delta
    mmoLevel = calculateLevelFromXp(mmoXp)

    if game and game.save then
      saveOnlineAccount(game.save)
      performForcedSave(game)

      local tid, tName = getTrainerInfo(game.save)
      local payload = {
        action = "sync_xp",
        trainerId = tid,
        token = mmoToken,
        xpType = xpType,
        badges = getBadgeCount(game.save),
        pokedexCount = getPokedexCount(game.save)
      }
      if extraFields then
        for k, v in pairs(extraFields) do payload[k] = v end
      end
      gtsApiPost(payload, 1.5)

      if mmoLevel > oldLevel then
        local Sound = require("src.core.Sound")
        pcall(function() Sound.play(game.data, "Level_Up") end)
        game.stack:push(TextBox.new(game, wrapText(string.format("LEVEL UP!\nREACHED MMO LEVEL %d!", mmoLevel))))
      end
    end
  end

  -- LAUNCH NATIVE LOCKSTEP GEN 1 LINK BATTLES (LinkBattle.newHost / LinkBattle.newGuest)
  startPvpBattle = function(game, opponentName, opponentId, remotePartyPacked, isHostPlayer, seed, roomId)
    if inBattle then return end  -- Double-start guard
    if not game or not game.save or not game.save.party or #game.save.party == 0 then
      inBattle = false
      game.stack:push(TextBox.new(game, wrapText("YOU NEED AT LEAST 1 POKéMON IN YOUR PARTY TO BATTLE!")))
      return
    end
    if not remotePartyPacked or #remotePartyPacked == 0 then
      inBattle = false
      game.stack:push(TextBox.new(game, wrapText(string.format("%s HAS NO POKéMON IN THEIR PARTY!", opponentName or "FOE"))))
      return
    end

    inBattle = true
    local trainerId, myName = getTrainerInfo(game.save)
    local myPackedParty = Protocol.packParty(game.save.party)

    local netAdapter = GtsNetAdapter.new(trainerId, opponentId, roomId)

    local opts = {
      myParty = myPackedParty,
      theirParty = remotePartyPacked,
      theirName = opponentName or "FOE",
      seed = seed or 12345,
      role = isHostPlayer and "host" or "guest"
    }

    local battle = nil
    if isHostPlayer then
      battle = LinkBattle.newHost(game, netAdapter, opts)
    else
      battle = LinkBattle.newGuest(game, netAdapter, opts)
    end

    if battle then
      local origFinish = battle.finish
      battle.finish = function(self)
        inBattle = false
        activeBattleAdapter = nil

        -- FLUSH both in-channels to eliminate any stale ACCEPT_PVP / battle
        -- responses that the background thread queued during the battle.
        -- Without this, a stale ACCEPT_PVP in netInChannel fires a new battle
        -- the moment battle.finish clears the inBattle guard.
        if netInChannel    then while netInChannel:pop()    do end end
        if battleInChannel then while battleInChannel:pop() do end end

        -- Clear challenge state for BOTH players on server so neither
        -- gets auto-prompted for a rematch on next sync_pos.
        local myId = getTrainerInfo(game.save)
        gtsApiPost({ action = "clear_challenge", trainerId = myId    }, 0.5)
        gtsApiPost({ action = "clear_challenge", trainerId = opponentId }, 0.5)
        -- Also clear the room so stale battle messages don't linger
        gtsApiPost({ action = "clear_battle_room", roomId = roomId }, 0.5)

        -- Brief cooldown prevents the overworld from immediately firing
        -- another challenge on the very first sync_pos after returning.
        isWaitingForChallenge = false
        lastBattleEndTime = (_G.love and _G.love.timer and _G.love.timer.getTime)
                              and _G.love.timer.getTime() or os.time()

        if origFinish then origFinish(self) end

        -- Call clear_battle_room a SECOND time after origFinish, because the
        -- engine sends a 'bye' inside origFinish (which we now suppress in
        -- GtsNetAdapter:send, but belt-and-suspenders: clear again in case
        -- anything else lands in the room before the opponent polls).
        gtsApiPost({ action = "clear_battle_room", roomId = roomId }, 0.5)

        if self.result == "win" then
          addMmoXp(game, "pvp_win", nil, { opponentName = opponentName or "TRAINER", opponentId = opponentId or "0" })
          syncLocalProfile(game, 1)
          performForcedSave(game)
          game.stack:push(TextBox.new(game, string.format("VICTORY!\nDEFEATED %s IN PVP!\n(+100 MMO XP)", opponentName or "TRAINER")))
        else
          addMmoXp(game, "pvp_loss", nil, { opponentName = opponentName or "TRAINER", opponentId = opponentId or "0" })
          performForcedSave(game)
          game.stack:push(TextBox.new(game, string.format("LINK BATTLE FINISHED\nWITH %s!\n(+25 MMO XP)", opponentName or "TRAINER")))
        end
      end

      game.stack:push(battle)
    end
  end

  -- LAUNCH REAL VANILLA LINK TRADE ENGINE WITH CUTSCENE & TRADE EVOLUTIONS
  startLinkTrade = function(game, partnerName, partnerId, isHostPlayer, roomId)
    local myId, myName = getTrainerInfo(game.save)

    if not game.save or not game.save.party or #game.save.party == 0 then
      game.stack:push(TextBox.new(game, wrapText("YOU HAVE NO POKéMON TO TRADE!")))
      return
    end

    local netAdapter = GtsNetAdapter.new(myId, partnerId, roomId)
    local LinkState = require("src.link.LinkState")

    local linkState = LinkState.new(game)
    linkState.net = netAdapter
    linkState.peerName = partnerName or "TRAINER"
    linkState.verdict = "full"
    linkState:startMode("trade", isHostPlayer)

    game.stack:push(linkState)
  end

  -- Remove ONLY the follower NPC for a remote player (keeps the player avatar)
  local function removeNetFollower(ow, tid)
    if not ow then return end
    tid = tostring(tid)

    if netFollowers[tid] then
      local fNpc = netFollowers[tid]
      if ow.npcs then
        for i = #ow.npcs, 1, -1 do
          if ow.npcs[i] == fNpc or (ow.npcs[i] and ow.npcs[i].trainerId == tid and ow.npcs[i].isCoopFollower) then
            table.remove(ow.npcs, i)
          end
        end
      end
      if ow.entities then
        for j = #ow.entities, 1, -1 do
          if ow.entities[j] == fNpc or (ow.entities[j] and ow.entities[j].trainerId == tid and ow.entities[j].isCoopFollower) then
            table.remove(ow.entities, j)
          end
        end
      end
      netFollowers[tid] = nil
    end
  end

  -- CLEAN ENTITY GC HELPER
  local function removeNetPlayer(ow, tid)
    if not ow then return end
    tid = tostring(tid)

    removeNetFollower(ow, tid)

    if netNpcs[tid] then
      local pNpc = netNpcs[tid]
      if ow.npcs then
        for i = #ow.npcs, 1, -1 do
          if ow.npcs[i] == pNpc or (ow.npcs[i] and ow.npcs[i].trainerId == tid and ow.npcs[i].isCoopPlayer) then
            table.remove(ow.npcs, i)
          end
        end
      end
      if ow.entities then
        for j = #ow.entities, 1, -1 do
          if ow.entities[j] == pNpc or (ow.entities[j] and ow.entities[j].trainerId == tid and ow.entities[j].isCoopPlayer) then
            table.remove(ow.entities, j)
          end
        end
      end
      netNpcs[tid] = nil
    end

    netPlayerMap[tid] = nil
  end

  local function clearAllNetPlayers(ow)
    if not ow then return end
    for tid, _ in pairs(netNpcs) do
      removeNetPlayer(ow, tid)
    end
    netNpcs = {}
    netFollowers = {}
    netPlayerMap = {}
  end

  -- Disconnect Flow
  handleDisconnect = function(game, reason)
    if netSession then
      pcall(function() netSession:close() end)
      netSession = nil
    end
    isHost = false
    roomCode = nil
    activeBattleAdapter = nil
    isWaitingForChallenge = false

    -- 1. Save online progress to save_online.lua before disconnecting
    if isGtsServerConnected and game and game.save then
      writeOnlineSave(game.save)
    end
    isGtsServerConnected = false

    local ow = getWorld(game)
    if ow then
      clearAllNetPlayers(ow)
    end

    -- 2. Restore local offline save from backup or disk (save_gold.lua / save.lua)
    local localSave = offlineSaveBackup or loadOfflineSave()
    if localSave and game then
      game.save = localSave
      if game.adoptSave then game:adoptSave(game.save) end
      localSelectedSprite = "SPRITE_RED"
      applyPlayerSprite(game, "SPRITE_RED")
      local pMap = (game.save.position and game.save.position.map) or (game.save.player and game.save.player.map) or defaultStartingOutdoor
      local px = (game.save.position and game.save.position.x) or (game.save.player and game.save.player.x) or defaultStartingOutdoorX
      local py = (game.save.position and game.save.position.y) or (game.save.player and game.save.player.y) or defaultStartingOutdoorY
      local pDir = (game.save.position and game.save.position.facing) or (game.save.player and game.save.player.facing) or "down"
      if ow and ow.setMap then
        pcall(function() ow:setMap(pMap, px, py, pDir) end)
      end
    end

    game.stack:push(TextBox.new(game, wrapText(reason or "DISCONNECTED FROM SERVER.\nLOCAL SAVE RESTORED.")))
  end

  -- REAL-TIME TILE-BY-TILE 1X SPRITE MOVEMENT (Max 1 Directional Tile at a time, No Warping/Flickering)
  local function updateNpcMovement(npc, dt)
    if not npc or not npc.targetPx or not npc.targetPy then return end

    local dx = npc.targetPx - npc.px
    local dy = npc.targetPy - npc.py
    local dist = math.sqrt(dx * dx + dy * dy)

    -- If map changed or wildly out of bounds (> 320 px, e.g. map reload), snap cleanly
    if dist > 320 then
      npc.px = npc.targetPx
      npc.py = npc.targetPy
      npc.cellX = npc.targetCellX or math.floor(npc.px / 16)
      npc.cellY = npc.targetCellY or math.floor(npc.py / 16)
      npc.x = npc.cellX
      npc.y = npc.cellY
      npc.moving = false
      npc.progress = 0
      return
    end

    if dist > 0.5 then
      -- Lock movement speed to standard 1X walking speed (96 px/sec = 1 tile per 10 frames at 60fps)
      local walkSpeed = 96
      -- Step at most 16 pixels (1 tile) per movement step to avoid skipping or warping
      local maxStep = 16
      local step = math.min(dist, walkSpeed * (dt or 0.01667), maxStep)

      -- Move along primary axis first (cardinal tile-by-tile movement)
      if math.abs(dx) > math.abs(dy) then
        local dirSign = dx > 0 and 1 or -1
        npc.px = npc.px + dirSign * step
        npc.facing = dx > 0 and "right" or "left"
      else
        local dirSign = dy > 0 and 1 or -1
        npc.py = npc.py + dirSign * step
        npc.facing = dy > 0 and "down" or "up"
      end

      npc.cellX = math.floor((npc.px + 8) / 16)
      npc.cellY = math.floor((npc.py + 8) / 16)
      npc.x = npc.cellX
      npc.y = npc.cellY

      npc.moving = true
      npc.progress = (npc.progress or 0) + step * 2.5
      if (npc.progress or 0) >= 16 then
        npc.progress = 0
        npc.stepFlip = not npc.stepFlip
      end
    else
      -- Snapped cleanly into target cell
      npc.px = npc.targetPx
      npc.py = npc.targetPy
      npc.cellX = npc.targetCellX or math.floor(npc.px / 16)
      npc.cellY = npc.targetCellY or math.floor(npc.py / 16)
      npc.x = npc.cellX
      npc.y = npc.cellY
      npc.moving = false
      npc.progress = 0
    end
  end

  -- Sync Multi-Player Network NPCs on Overworld Map (100% Continuous Real-Time Tracking)
  syncMultiNetPlayers = function(game, ow, playersList)
    if not ow or not ow.map then
        clearAllNetPlayers(ow)
        return
    end

    local activeIds = {}
    local currentMapId = tostring(ow.map.id)
    print("[DEBUG] syncMultiNetPlayers: current map = " .. currentMapId)

    for _, data in ipairs(playersList or {}) do
        local tid = tostring(data.trainerId)
        local remoteMapId = tostring(data.map)
        print("[DEBUG] Player " .. tid .. " is on map " .. remoteMapId)

        -- Only process if the remote player is on the SAME map (case-insensitive)
        if remoteMapId:lower() == currentMapId:lower() then
            activeIds[tid] = true
            netPlayerMap[tid] = data

            local facing = data.facing or "down"
            local isMoving = data.moving or false
            local destX = data.x or 5
            local destY = data.y or 5

            local originX = destX
            local originY = destY
            if isMoving then
                local delta = Collision.DELTA[facing] or { 0, 1 }
                originX = destX - delta[1]
                originY = destY - delta[2]
            end

            local targetPx = destX * 16
            local targetPy = destY * 16
            local originPx = originX * 16
            local originPy = originY * 16

            local fCellX = data.fx or originX
            local fCellY = data.fy or originY
            local fTargetPx = fCellX * 16
            local fTargetPy = fCellY * 16

            -- 1. Create NPC Avatar on Initial Spawn
            if not netNpcs[tid] then
                print("[DEBUG] Creating NPC for player " .. tid .. " at " .. originX .. "," .. originY)
                local pNpc = NPC.new(game.data, ow.map.id, {
                    index = 100000 + (tonumber(tid) or 0) % 90000,
                    name = data.name or "TRAINER",
                    sprite = "SPRITE_RED",
                    movement = "STAY",
                    range = "NONE",
                    x = originX,
                    y = originY,
                })
                pNpc.trainerId = tid
                pNpc.isCoopPlayer = true
                pNpc.passable = true
                pNpc.px = originPx
                pNpc.py = originPy
                pNpc.targetPx = targetPx
                pNpc.targetPy = targetPy
                pNpc.cellX = originX
                pNpc.cellY = originY
                pNpc.targetCellX = destX
                pNpc.targetCellY = destY
                pNpc.facing = facing
                pNpc.update = function(self, dt, map, entities) end

                -- Attach SpriteRenderer (Support Custom Avatar Selection)
                local chosenRemoteSprite = data.spriteId or (isGen2 and "SPRITE_CHRIS" or "SPRITE_RED")
                local sprites = (game.data and (game.data.gen2Sprites or game.data.sprites)) or {}
                local spriteDef = sprites[chosenRemoteSprite] or sprites["SPRITE_CHRIS"] or sprites["SPRITE_RED"]
                if spriteDef then
                    pNpc.sprite = SpriteRenderer.new(spriteDef, pNpc.id)
                    print("[DEBUG] Attached " .. chosenRemoteSprite .. " renderer to player " .. tid)
                else
                    -- FALLBACK: create a solid red square to see if the NPC exists
                    local fallbackImage = love.graphics.newImage(love.image.newImageData(16, 16, "rgba8", {255,0,0,255}))
                    local fallbackDef = { id = "FALLBACK", image = fallbackImage, frames = 1, walker = false, trueColor = true }
                    pNpc.sprite = SpriteRenderer.new(fallbackDef, pNpc.id)
                    print("[WARN] " .. chosenRemoteSprite .. " missing for " .. tid .. " – using red square")
                end

                table.insert(ow.npcs, pNpc)
                table.insert(ow.entities, pNpc)
                netNpcs[tid] = pNpc
                print("[DEBUG] NPC for player " .. tid .. " added to entities. Total remote NPCs: " .. #ow.entities)
            end

            -- 2. CONTINUOUS MOVEMENT TARGET UPDATES
            local pNpc = netNpcs[tid]
            if pNpc.targetPx ~= targetPx or pNpc.targetPy ~= targetPy then
                pNpc.targetPx = targetPx
                pNpc.targetPy = targetPy
                pNpc.targetCellX = destX
                pNpc.targetCellY = destY
                pNpc.moving = true
            end
            pNpc.facing = facing

            -- 3. CONTINUOUS FOLLOWER TARGET UPDATES
            if data.species then
                local spriteId = "SPRITE_WILD_" .. tostring(data.species)
                local spriteDef = game.data and game.data.sprites and game.data.sprites[spriteId]
                if spriteDef then
                    if not netFollowers[tid] then
                        local fNpc = NPC.new(game.data, ow.map.id, {
                            index = 200000 + (tonumber(tid) or 0) % 90000,
                            name = tostring(data.species),
                            sprite = spriteId,
                            movement = "STAY",
                            range = "NONE",
                            x = fCellX,
                            y = fCellY,
                        })
                        fNpc.trainerId = tid
                        fNpc.spriteId = spriteId
                        fNpc.isCoopFollower = true
                        fNpc.passable = true
                        fNpc.px = fTargetPx
                        fNpc.py = fTargetPy
                        fNpc.targetPx = fTargetPx
                        fNpc.targetPy = fTargetPy
                        fNpc.cellX = fCellX
                        fNpc.cellY = fCellY
                        fNpc.targetCellX = fCellX
                        fNpc.targetCellY = fCellY
                        fNpc.facing = facing
                        fNpc.update = function(self, dt, map, entities) end
                        table.insert(ow.npcs, fNpc)
                        table.insert(ow.entities, fNpc)
                        netFollowers[tid] = fNpc
                    elseif netFollowers[tid].spriteId ~= spriteId then
                        netFollowers[tid].spriteId = spriteId
                        netFollowers[tid].sprite = SpriteRenderer.new(spriteDef, netFollowers[tid].id)
                    end

                    local fNpc = netFollowers[tid]
                    if fNpc.targetPx ~= fTargetPx or fNpc.targetPy ~= fTargetPy then
                        fNpc.targetPx = fTargetPx
                        fNpc.targetPy = fTargetPy
                        fNpc.targetCellX = fCellX
                        fNpc.targetCellY = fCellY
                        fNpc.moving = true
                    end
                    fNpc.facing = facing
                else
                -- CRITICAL FIX: the vanilla ROM ships NO SPRITE_WILD_* overworld
                  -- sprites (data/generated/sprites.lua only has trainer sprites
            -- like SPRITE_RED/SPRITE_BLUE), so this lookup ALWAYS fails for
            -- any real follower species. The old code called
            -- removeNetPlayer() here, which deleted the PLAYER AVATAR that
            -- had just been created a few lines above in this same function
            -- call -- so every remote player with a party Pokemon (i.e.
            -- basically everyone in real play) was spawned and instantly
            -- destroyed before a single frame ever rendered them, making
            -- them invisible to whoever received their data. Only remove
            -- the (never-successfully-created) follower here; never the
            -- avatar.
            removeNetFollower(ow, tid)
          end
            end
        else
            -- Remote player is on a different map – remove their NPCs if they exist
            if netNpcs[tid] then
                print("[DEBUG] Removing NPC for player " .. tid .. " because map mismatch (" .. remoteMapId .. " != " .. currentMapId .. ")")
                removeNetPlayer(ow, tid)
            end
        end
    end

    -- Clean Memory Leak – remove NPCs for players no longer in the list
    for tid, _ in pairs(netNpcs) do
        if not activeIds[tid] then
            print("[DEBUG] Removing NPC for player " .. tid .. " (no longer in active list)")
            removeNetPlayer(ow, tid)
        end
    end

    -- Optional: print total remote NPC count every 5 seconds
    local now = os.time()
    if now - remoteCountLogTime >= 5 then
        print("[DEBUG] Remote NPC count: " .. #netNpcs)
        remoteCountLogTime = now
    end
  end

  local function getRankTitle(level, pvpWins)
    level = tonumber(level) or 1
    if level >= 100 then return "POKéMON LEGEND"
    elseif level >= 90 then return "GRAND MASTER"
    elseif level >= 80 then return "CHAMPION"
    elseif level >= 70 then return "ELITE FOUR"
    elseif level >= 60 then return "VETERAN"
    elseif level >= 50 then return "MASTER"
    elseif level >= 40 then return "ACE TRAINER"
    elseif level >= 30 then return "EXPERT"
    elseif level >= 20 then return "TRAINER"
    elseif level >= 10 then return "ROOKIE"
    else return "NOVICE" end
  end

        -- View Detailed Trainer Card UI Screen with Server Rank, Level & Battle Record
  openTrainerCardScreen = function(game, tid, rawData)
    local myTid, myName = getTrainerInfo(game.save)
    local isMe = (not tid) or (tostring(tid) == tostring(myTid))
    local queryTid = isMe and myTid or tid

    local pData = gtsApiGet("/gts/profile?trainerId=" .. tostring(queryTid), 1.5)
    local profile = (pData and pData.success and pData.profile) or {}

    local name = profile.name or (isMe and myName) or (rawData and rawData.name) or "TRAINER"
    local level = tonumber(profile.level or (isMe and mmoLevel) or (rawData and rawData.level) or 1)
    local pvpWins = tonumber(profile.pvpWins or (rawData and rawData.pvpWins) or 0)
    local pvpLosses = tonumber(profile.pvpLosses or 0)
    local gtsTrades = tonumber(profile.gtsTrades or 0)
    local serverRank = tonumber(profile.serverRank or 1)
    local totalPlayers = tonumber(profile.totalPlayers or 1)
    local rank = profile.rank or getRankTitle(level, pvpWins)
    local badges = tonumber(profile.badges or (isMe and getBadgeCount(game.save)) or 0)
    local pokedexCount = tonumber(profile.pokedexCount or (isMe and getPokedexCount(game.save)) or 0)
    local favMon = profile.favoriteMon or (isMe and localFavoriteMon) or "PIKACHU"

    local expVal = tonumber(profile.xp or (isMe and mmoXp) or (rawData and rawData.xp) or 0)
    local nextLvlTarget = calculateXpForLevel(level + 1)
    local expNeeded = (level >= 100) and 0 or math.max(0, nextLvlTarget - expVal)

    if #name > 10 then name = name:sub(1, 10) end
    if #rank > 10 then rank = rank:sub(1, 10) end
    if #favMon > 10 then favMon = favMon:sub(1, 10) end

    local container = {
      isOverworld = false,
      update = function(self, dt)
        local input = game.input
        if input:wasPressed("b") or input:wasPressed("a") or input:wasPressed("start") then
          game.stack:pop()
        end
      end,
      draw = function(self)
        Font.drawBox(0, 0, 20, 18)
        local hdr = "TRAINER CARD"
        Font.draw(hdr, math.floor((160 - #hdr * 8) / 2), 10)
        Font.draw("==================", 8, 20)
        Font.draw(string.format("NAME: %s", name:sub(1, 12)), 8, 30)
        Font.draw(string.format("LV:%d  ID:%s", level, tostring(queryTid):sub(1,6)), 8, 42)
        Font.draw(string.format("EXP:%d (%d NEED)", expVal, expNeeded), 8, 54)
        Font.draw(string.format("TITLE: %s", rank:sub(1, 11)), 8, 66)
        Font.draw(string.format("RANK: #%d / %d", serverRank, totalPlayers), 8, 78)
        Font.draw(string.format("PVP: %dW / %dL", pvpWins, pvpLosses), 8, 90)
        Font.draw(string.format("BADGES:%d/8 DEX:%d", badges, pokedexCount), 8, 102)
        Font.draw(string.format("FAVORITE: %s", favMon:sub(1, 8)), 8, 114)
        Font.draw("==================", 8, 122)
        Font.draw("A/B: CLOSE", math.floor((160 - 10 * 8) / 2), 128)
      end
    }
    game.stack:push(container)
  end

    -- View Dedicated Level, Experience Points & Next Level Info Screen
  openMmoLevelInfoScreen = function(game)
    local lvl = mmoLevel or 1
    local xp = mmoXp or 0
    local nextLvlXp = calculateXpForLevel(lvl + 1)
    local needed = (lvl >= 100) and 0 or math.max(0, nextLvlXp - xp)
    local trainerId, trainerName = getTrainerInfo(game.save)
    local tNameShort = (trainerName or "RED"):sub(1, 10)

    local container = {
      isOverworld = false,
      update = function(self, dt)
        local input = game.input
        if input:wasPressed("b") or input:wasPressed("a") or input:wasPressed("start") then
          game.stack:pop()
        end
      end,
      draw = function(self)
        Font.drawBox(0, 0, 20, 18)
        local hdr = "EXP & LEVEL INFO"
        Font.draw(hdr, math.floor((160 - #hdr * 8) / 2), 8)
        Font.draw("==================", 8, 18)
        Font.draw(string.format("PLAYER: %s", tNameShort), 8, 28)
        Font.draw(string.format("ID: %s", tostring(trainerId):sub(1, 10)), 8, 40)
        Font.draw(string.format("LEVEL: %d / 100", lvl), 8, 54)
        Font.draw(string.format("TOTAL EXP: %d", xp), 8, 68)
        if lvl >= 100 then
          Font.draw("STATUS: MAX LEVEL!", 8, 84)
          Font.draw("EXP NEEDED: 0", 8, 98)
        else
          Font.draw(string.format("NEXT: LV%d (%d)", lvl + 1, nextLvlXp), 8, 84)
          Font.draw(string.format("EXP NEED: %d", needed), 8, 98)
        end
        Font.draw("==================", 8, 114)
        Font.draw("A/B: CLOSE", math.floor((160 - 10 * 8) / 2), 126)
      end
    }
    game.stack:push(container)
  end

  -- Helper to add history receipt to GTS
  local function addGtsReceipt(text)
    table.insert(gtsDb.history, 1, {
      text = text,
      time = os.time()
    })
    while #gtsDb.history > 50 do
      table.remove(gtsDb.history)
    end
  end

    -- GTS Summary Card & Trade Execution
  local function openGtsSummaryCard(game, listing)
    local trainerId, buyerName = getTrainerInfo(game.save)
    local offered = listing.offeredMon
    local offName = offered.nickname or (game.data.pokemon[offered.species] and game.data.pokemon[offered.species].name) or offered.species
    local otName = listing.trainerName or "TRAINER"

    if #offName > 10 then offName = offName:sub(1, 10) end
    if #otName > 8 then otName = otName:sub(1, 8) end

    local wantedList = listing.wanted or {}

    local container = {
      isOverworld = false,
      update = function(self, dt)
        local input = game.input
        if input:wasPressed("b") then
          game.stack:pop()
          return
        elseif input:wasPressed("a") then
          if listing.trainerId == trainerId then
            game.stack:push(TextBox.new(game, wrapText("THIS IS YOUR OWN LISTING! MANAGE IN MY LISTINGS.")))
            return
          end

          local eligibleSlots = {}
          for i, pMon in ipairs(game.save.party) do
            for _, wSpec in ipairs(wantedList) do
              if pMon.species == wSpec then
                table.insert(eligibleSlots, { index = i, mon = pMon })
                break
              end
            end
          end

          if #eligibleSlots == 0 then
            game.stack:push(TextBox.new(game, wrapText("YOU DO NOT HAVE ANY OF THE WANTED POKéMON!")))
            return
          end

          local tradeItems = {}
          for _, choice in ipairs(eligibleSlots) do
            local pMon = choice.mon
            local idx = choice.index
            local pName = pMon.nickname or pMon.species
            if #pName > 7 then pName = pName:sub(1, 7) end
            table.insert(tradeItems, {
              label = string.format("GIVE %s (LV%d)", pName, pMon.level),
              onSelect = function()
                local sentMon = table.remove(game.save.party, idx)
                local packedSent = Protocol.packMon(sentMon)

                local res = gtsApiPost({
                  action = "trade",
                  listingId = listing.id,
                  buyerId = trainerId,
                  buyerName = buyerName,
                  sentMon = packedSent
                }, 2.0)

                local receivedMon = Protocol.unpackMon(game.data, offered)
                local addedToParty = Party.add(game.save.party, receivedMon)
                if not addedToParty then
                  Boxes.deposit(game.save, receivedMon)
                end

                gtsDb.claim_boxes[listing.trainerId] = gtsDb.claim_boxes[listing.trainerId] or {}
                table.insert(gtsDb.claim_boxes[listing.trainerId], {
                  mon = packedSent,
                  fromName = buyerName,
                  fromId = trainerId,
                  originalOffered = offName
                })

                gtsDb.listings[listing.id] = nil
                gtsDb.user_counts[listing.trainerId] = math.max(0, (gtsDb.user_counts[listing.trainerId] or 1) - 1)

                addGtsReceipt(string.format("%s TRADED %s TO %s FOR %s", buyerName, sentMon.nickname or sentMon.species, listing.trainerName, offName))
                performForcedSave(game)

                local Sound = require("src.core.Sound")
                pcall(function() Sound.play(game.data, "Trade_Machine") end)

                game.stack:pop()
                local msg = string.format("GTS TRADE DONE! RECEIVED %s!", offName)
                game.stack:push(TextBox.new(game, wrapText(msg)))
              end
            })
          end
          table.insert(tradeItems, { label = "BACK", onSelect = function() end })
          game.stack:push(Menu.new(game, tradeItems, { tx = 0, ty = 0, tw = 20, maxVisible = 7, startCloses = true }))
        end
      end,
      draw = function(self)
        Font.drawBox(0, 0, 20, 18)
        local hdr = "GTS LISTING"
        Font.draw(hdr, math.floor((160 - #hdr * 8) / 2), 10)
        Font.draw("==================", 8, 20)
        Font.draw(string.format("OFFER: %s", offName:sub(1, 11)), 8, 32)
        Font.draw(string.format("LEVEL: %d", offered.level or 1), 8, 44)
        Font.draw(string.format("OT: %s (ID %s)", otName:sub(1, 6), tostring(listing.trainerId or 0):sub(1,6)), 8, 56)
        Font.draw("WANTED POKéMON:", 8, 68)

        if #wantedList == 0 then
          Font.draw(" - ANY POKéMON", 8, 80)
        else
          local curY = 80
          for _, wSpec in ipairs(wantedList) do
            local wName = (game.data.pokemon[wSpec] and game.data.pokemon[wSpec].name) or wSpec
            if #wName > 14 then wName = wName:sub(1, 14) end
            Font.draw(string.format(" - %s", wName), 8, curY)
            curY = curY + 12
          end
        end

        Font.draw("==================", 8, 114)
        local ftr = "A: TRADE  B: BACK"
        Font.draw(ftr, math.floor((160 - #ftr * 8) / 2), 126)
      end
    }
    game.stack:push(container)
  end

  -- GTS Browse Submenu (WITH STRICT CONNECTION GUARD)
  local function openGtsBrowseMenu(game)
    if not isGtsServerConnected then
      game.stack:push(TextBox.new(game, wrapText("YOU ARE NOT CONNECTED TO GTS SERVER! SELECT CONNECT GTS SERVER FIRST.")))
      return
    end

    local trainerId, trainerName = getTrainerInfo(game.save)
    fetchGtsServerSync(trainerId)

    local items = {}
    for id, listing in pairs(gtsDb.listings) do
      local offered = listing.offeredMon
      local offName = offered.nickname or (game.data.pokemon[offered.species] and game.data.pokemon[offered.species].name) or offered.species
      local tName = listing.trainerName or "OT"
      if #offName > 7 then offName = offName:sub(1, 7) end
      if #tName > 5 then tName = tName:sub(1, 5) end

      table.insert(items, {
        label = string.format("%s L%d (%s)", offName, offered.level or 1, tName),
        onSelect = function()
          openGtsSummaryCard(game, listing)
        end
      })
    end

    if #items == 0 then
      game.stack:push(TextBox.new(game, wrapText("NO ACTIVE TRADES FOUND ON GTS.")))
      return
    end

    table.insert(items, { label = "BACK", onSelect = function() end })
    local menu = Menu.new(game, items, { tx = 0, ty = 0, tw = 20, maxVisible = 7, startCloses = true })
    game.stack:push(menu)
  end

  -- GTS My Listings & Claim Box Submenu (WITH STRICT CONNECTION GUARD)
  local function openGtsMyListingsMenu(game)
    if not isGtsServerConnected then
      game.stack:push(TextBox.new(game, wrapText("YOU ARE NOT CONNECTED TO GTS SERVER! SELECT CONNECT GTS SERVER FIRST.")))
      return
    end

    local trainerId, trainerName = getTrainerInfo(game.save)
    fetchGtsServerSync(trainerId)

    local items = {}

    -- 1. Active Deposits (Withdraw)
    for id, listing in pairs(gtsDb.listings) do
      if tostring(listing.trainerId) == tostring(trainerId) then
        local offered = listing.offeredMon
        local offName = offered.nickname or (game.data.pokemon[offered.species] and game.data.pokemon[offered.species].name) or offered.species
        if #offName > 7 then offName = offName:sub(1, 7) end
        table.insert(items, {
          label = string.format("TAKE %s LV%d", offName, offered.level or 1),
          onSelect = function()
            local returnedMon = Protocol.unpackMon(game.data, offered)
            local added = Party.add(game.save.party, returnedMon)
            if not added then Boxes.deposit(game.save, returnedMon) end

            gtsApiPost({ action = "withdraw", listingId = id, trainerId = trainerId }, 2.0)

            gtsDb.listings[id] = nil
            gtsDb.user_counts[trainerId] = math.max(0, (gtsDb.user_counts[trainerId] or 1) - 1)
            addGtsReceipt(string.format("%s WITHDREW DEPOSITED %s", trainerName, offName))
            performForcedSave(game)

            local msg = string.format("WITHDREW %s FROM GTS!", offName)
            game.stack:push(TextBox.new(game, wrapText(msg)))
          end
        })
      end
    end

    -- 2. Claim Box (Traded Mons Waiting to be Claimed)
    local claims = gtsDb.claim_boxes[tostring(trainerId)] or {}
    for idx, claim in ipairs(claims) do
      local packed = claim.mon
      local cName = packed.nickname or (game.data.pokemon[packed.species] and game.data.pokemon[packed.species].name) or packed.species
      local fromStr = claim.fromName or "TRADER"
      if #cName > 7 then cName = cName:sub(1, 7) end
      if #fromStr > 5 then fromStr = fromStr:sub(1, 5) end
      table.insert(items, {
        label = string.format("GET %s (%s)", cName, fromStr),
        onSelect = function()
          local claimedMon = Protocol.unpackMon(game.data, packed)
          local added = Party.add(game.save.party, claimedMon)
          if not added then Boxes.deposit(game.save, claimedMon) end

          gtsApiPost({ action = "claim", trainerId = trainerId, index = idx - 1 }, 2.0)

          table.remove(gtsDb.claim_boxes[tostring(trainerId)], idx)
          addGtsReceipt(string.format("%s CLAIMED TRADED %s", trainerName, cName))
          performForcedSave(game)

          local msg = string.format("CLAIMED %s FROM GTS!", cName)
          game.stack:push(TextBox.new(game, wrapText(msg)))
        end
      })
    end

    if #items == 0 then
      game.stack:push(TextBox.new(game, wrapText("YOU HAVE NO ACTIVE DEPOSITS OR CLAIMS.")))
      return
    end

    table.insert(items, { label = "BACK", onSelect = function() end })
    local menu = Menu.new(game, items, { tx = 0, ty = 0, tw = 20, maxVisible = 7, startCloses = true })
    game.stack:push(menu)
  end

  -- GTS Recent History (Last 50 Receipts) Submenu (WITH STRICT CONNECTION GUARD)
  local function openGtsHistoryMenu(game)
    if not isGtsServerConnected then
      game.stack:push(TextBox.new(game, wrapText("YOU ARE NOT CONNECTED TO GTS SERVER! SELECT CONNECT GTS SERVER FIRST.")))
      return
    end

    local trainerId, trainerName = getTrainerInfo(game.save)
    fetchGtsServerSync(trainerId)

    local items = {}
    for _, r in ipairs(gtsDb.history) do
      local lbl = r.text
      if #lbl > 16 then lbl = lbl:sub(1, 16) end
      table.insert(items, {
        label = lbl,
        onSelect = function()
          game.stack:push(TextBox.new(game, wrapText(r.text)))
        end
      })
    end

    if #items == 0 then
      game.stack:push(TextBox.new(game, wrapText("NO GTS TRANSACTIONS RECORDED YET.")))
      return
    end

    table.insert(items, { label = "BACK", onSelect = function() end })
    local menu = Menu.new(game, items, { tx = 0, ty = 0, tw = 20, maxVisible = 7, startCloses = true })
    game.stack:push(menu)
  end

  -- Interactive Wanted Species Selection Screen
  local function openWantedSpeciesSelector(game, onComplete)
    local wanted = {}
    local allSpecies = getAllGen1Species(game.data)

    local function showMainWantedMenu()
      local items = {}
      if #wanted > 0 then
        table.insert(items, {
          label = string.format("CONFIRM (%d/3)", #wanted),
          onSelect = function()
            onComplete(wanted)
          end
        })
      end

      if #wanted < 3 then
        table.insert(items, {
          label = string.format("+ ADD (%d/3)", #wanted + 1),
          onSelect = function()
            local ranges = {
              { label = "A - C", minChar = "A", maxChar = "C" },
              { label = "D - F", minChar = "D", maxChar = "F" },
              { label = "G - I", minChar = "G", maxChar = "I" },
              { label = "J - L", minChar = "J", maxChar = "L" },
              { label = "M - O", minChar = "M", maxChar = "O" },
              { label = "P - R", minChar = "P", maxChar = "R" },
              { label = "S - U", minChar = "S", maxChar = "U" },
              { label = "V - Z", minChar = "V", maxChar = "Z" },
            }
            local rangeItems = {}
            for _, r in ipairs(ranges) do
              table.insert(rangeItems, {
                label = r.label,
                onSelect = function()
                  local monItems = {}
                  for _, spec in ipairs(allSpecies) do
                    local firstLetter = spec.name:sub(1, 1):upper()
                    if firstLetter >= r.minChar and firstLetter <= r.maxChar then
                      table.insert(monItems, {
                        label = spec.name:sub(1, 14),
                        onSelect = function()
                          table.insert(wanted, spec.id)
                          showMainWantedMenu()
                        end
                      })
                    end
                  end
                  if #monItems == 0 then
                    game.stack:push(TextBox.new(game, wrapText("NO POKéMON IN THIS RANGE.")))
                  else
                    table.insert(monItems, { label = "BACK", onSelect = function() showMainWantedMenu() end })
                    game.stack:push(Menu.new(game, monItems, { tx = 0, ty = 0, tw = 20, maxVisible = 7, startCloses = true }))
                  end
                end
              })
            end
            table.insert(rangeItems, { label = "BACK", onSelect = function() showMainWantedMenu() end })
            game.stack:push(Menu.new(game, rangeItems, { tx = 0, ty = 0, tw = 20, maxVisible = 7, startCloses = true }))
          end
        })
      end

      if #wanted > 0 then
        table.insert(items, {
          label = "CLEAR ALL",
          onSelect = function()
            wanted = {}
            showMainWantedMenu()
          end
        })
      end

      table.insert(items, {
        label = "CANCEL",
        onSelect = function()
          onComplete(nil)
        end
      })

      game.stack:push(Menu.new(game, items, { tx = 0, ty = 0, tw = 20, maxVisible = 7, startCloses = true }))
    end

    showMainWantedMenu()
  end

  -- GTS Deposit Submenu (WITH INTERACTIVE WANTED SPECIES SELECTOR)
  local function openGtsDepositMenu(game)
    if not isGtsServerConnected then
      game.stack:push(TextBox.new(game, wrapText("YOU ARE NOT CONNECTED TO GTS SERVER! SELECT CONNECT GTS SERVER FIRST.")))
      return
    end

    if not game.save or not game.save.party or #game.save.party < 2 then
      game.stack:push(TextBox.new(game, wrapText("YOU NEED AT LEAST 2 POKéMON IN PARTY TO DEPOSIT!")))
      return
    end

    local trainerId, trainerName = getTrainerInfo(game.save)
    fetchGtsServerSync(trainerId)

    local activeCount = gtsDb.user_counts[trainerId] or 0
    if activeCount >= 3 then
      game.stack:push(TextBox.new(game, wrapText("YOU REACHED THE MAX 3 GTS DEPOSITS!")))
      return
    end

    local partyItems = {}
    for idx, mon in ipairs(game.save.party) do
      local monName = mon.nickname or (game.data.pokemon[mon.species] and game.data.pokemon[mon.species].name) or mon.species
      if #monName > 8 then monName = monName:sub(1, 8) end
      table.insert(partyItems, {
        label = string.format("%s (LV%d)", monName, mon.level),
        onSelect = function()
          local chosenSlot = idx
          local chosenMon = mon

          openWantedSpeciesSelector(game, function(wantedList)
            if not wantedList or #wantedList == 0 then return end

            local depositMon = table.remove(game.save.party, chosenSlot)
            if depositMon and depositMon.nickname and Profanity and Profanity.censor then
              depositMon.nickname = Profanity.censor(depositMon.nickname)
            end
            local packedMon = Protocol.packMon(depositMon)

            local res = gtsApiPost({
              action = "deposit",
              trainerId = trainerId,
              trainerName = trainerName,
              offeredMon = packedMon,
              wanted = wantedList
            }, 2.0)

            if res and res.success then
              gtsDb.listings[res.listing.id] = res.listing
            end

            gtsDb.user_counts[trainerId] = (gtsDb.user_counts[trainerId] or 0) + 1
            performForcedSave(game)

            local msg = string.format("%s WAS DEPOSITED TO GTS!", depositMon.nickname or depositMon.species)
            game.stack:push(TextBox.new(game, wrapText(msg)))
          end)
        end
      })
    end
    table.insert(partyItems, { label = "BACK", onSelect = function() end })

    game.stack:push(Menu.new(game, partyItems, { tx = 0, ty = 0, tw = 20, maxVisible = 7, startCloses = true }))
  end

  -- Main GTS Top-Level Menu (WITH USER-FRIENDLY AUTO-CONNECT)
  local function openGtsMainMenu(game)
    if not isGtsServerConnected then
      local connectPrompt = {
        {
          label = "CONNECT TO GTS",
          onSelect = function()
            handleConnectToServer(game)
          end
        },
        {
          label = "CANCEL",
          onSelect = function() end
        }
      }
      local msg = "YOU ARE NOT CONNECTED TO GTS SERVER!\nWOULD YOU LIKE TO CONNECT NOW?"
      game.stack:push(TextBox.new(game, wrapText(msg), function()
        game.stack:push(Menu.new(game, connectPrompt, { tx = 0, ty = 0, tw = 20, maxVisible = 6, startCloses = true }))
      end))
      return
    end

    local trainerId, trainerName = getTrainerInfo(game.save)
    fetchGtsServerSync(trainerId)

    local items = {
      {
        label = "BROWSE TRADES",
        onSelect = function() openGtsBrowseMenu(game) end
      },
      {
        label = "DEPOSIT MON",
        onSelect = function() openGtsDepositMenu(game) end
      },
      {
        label = "MY LISTINGS",
        onSelect = function() openGtsMyListingsMenu(game) end
      },
      {
        label = "RECENT HISTORY",
        onSelect = function() openGtsHistoryMenu(game) end
      },
      { label = "BACK", onSelect = function() end }
    }

    game.stack:push(Menu.new(game, items, { tx = 0, ty = 0, tw = 20, maxVisible = 7, startCloses = true }))
  end

  -- Customize Local Trainer Profile Submenu ("ONLINE SETTINGS")
  openMyProfileMenu = function(game)
    local titles = {
      "ACE TRAINER", "BUG CATCHER", "POKéMANIAC", "LASS", "YOUNGSTER",
      "CHAMPION", "GYM LEADER", "BLACKBELT", "SUPER NERD", "COOLTRAINER"
    }

    local items = {
      {
        label = "TRAINER CARD",
        onSelect = function()
          syncLocalProfile(game, 0)
          local tid, tName = getTrainerInfo(game.save)
          openTrainerCardScreen(game, tid, { name = tName })
        end
      },
      {
        label = "CHANGE AVATAR",
        onSelect = function()
          local spriteItems = {}
          for _, av in ipairs(AVAILABLE_AVATARS) do
            table.insert(spriteItems, {
              label = av.label,
              onSelect = function()
                localSelectedSprite = av.id
                if game.save and game.save.onlineAccount then
                  game.save.onlineAccount.spriteId = av.id
                end
                applyPlayerSprite(game, av.id)
                syncLocalProfile(game, 0)
                local msg = string.format("AVATAR CHANGED TO:\n%s!", av.label)
                game.stack:push(TextBox.new(game, wrapText(msg)))
              end
            })
          end
          table.insert(spriteItems, { label = "BACK", onSelect = function() end })
          game.stack:push(Menu.new(game, spriteItems, { tx = 0, ty = 0, tw = 20, maxVisible = 7, startCloses = true }))
        end
      },
      {
        label = "CHANGE TITLE",
        onSelect = function()
          local titleItems = {}
          for _, t in ipairs(titles) do
            table.insert(titleItems, {
              label = t,
              onSelect = function()
                localTrainerTitle = t
                if game.save and game.save.onlineAccount then
                  game.save.onlineAccount.title = t
                end
                syncLocalProfile(game, 0)
                local msg = string.format("TITLE UPDATED TO:\n%s!", t)
                game.stack:push(TextBox.new(game, wrapText(msg)))
              end
            })
          end
          table.insert(titleItems, { label = "BACK", onSelect = function() end })
          game.stack:push(Menu.new(game, titleItems, { tx = 0, ty = 0, tw = 20, maxVisible = 7, startCloses = true }))
        end
      },
      {
        label = "FAVORITE MON",
        onSelect = function()
          if not game.save or not game.save.party or #game.save.party == 0 then
            game.stack:push(TextBox.new(game, wrapText("YOU HAVE NO POKéMON IN YOUR PARTY!")))
            return
          end
          local favItems = {}
          for _, mon in ipairs(game.save.party) do
            local mName = mon.nickname or (game.data.pokemon[mon.species] and game.data.pokemon[mon.species].name) or mon.species
            table.insert(favItems, {
              label = mName:sub(1, 14),
              onSelect = function()
                localFavoriteMon = mName
                if game.save and game.save.onlineAccount then
                  game.save.onlineAccount.favoriteMon = mName
                end
                syncLocalProfile(game, 0)
                local msg = string.format("FAVORITE POKéMON SET TO:\n%s!", mName)
                game.stack:push(TextBox.new(game, wrapText(msg)))
              end
            })
          end
          table.insert(favItems, { label = "BACK", onSelect = function() end })
          game.stack:push(Menu.new(game, favItems, { tx = 0, ty = 0, tw = 20, maxVisible = 7, startCloses = true }))
        end
      },
      {
        label = "VIEW TOKEN",
        onSelect = function()
          local tokStr = mmoToken or (game.save and game.save.onlineAccount and game.save.onlineAccount.token) or "NONE"
          local msg = string.format("RECOVERY TOKEN:\n%s\nSAVE THIS TOKEN TO RESTORE ON ANY DEVICE!", tokStr)
          game.stack:push(TextBox.new(game, wrapText(msg)))
        end
      },
      {
        label = "REDEEM TOKEN",
        onSelect = function()
          openRedeemTokenMenu(game)
        end
      },
      { label = "BACK", onSelect = function() end }
    }

    game.stack:push(Menu.new(game, items, { tx = 0, ty = 0, tw = 20, maxVisible = 7, startCloses = true }))
  end

  -- Apply custom sprite avatar to local player immediately on overworld
  applyPlayerSprite = function(game, spriteId)
    if not game or not spriteId then return end
    local sprites = (game.data and (game.data.gen2Sprites or game.data.sprites)) or {}
    local sDef = sprites[spriteId] or sprites["SPRITE_RED"] or sprites["SPRITE_CHRIS"]
    local gWorld = getWorld(game)
    if sDef and gWorld and gWorld.player then
      if gWorld.player.setSprite then
        gWorld.player:setSprite(sDef)
      else
        gWorld.player.sprite = SpriteRenderer.new(sDef, "player")
      end
    end
  end

  -- Wrap Player.new to ensure whenever local player is initialized, chosen avatar is used
  local PlayerModule = pcall(require, "src.world.Player") and require("src.world.Player") or nil
  if PlayerModule and PlayerModule.new then
    local origPlayerNew = PlayerModule.new
    PlayerModule.new = function(data, cx, cy, facing)
      local p = origPlayerNew(data, cx, cy, facing)
      if localSelectedSprite and data.sprites and data.sprites[localSelectedSprite] then
        p.sprite = SpriteRenderer.new(data.sprites[localSelectedSprite], "player")
      end
      return p
    end
  end

  local Gen2PlayerModule = pcall(require, "src.world.gen2.Player") and require("src.world.gen2.Player") or nil
  if Gen2PlayerModule and Gen2PlayerModule.new then
    local origGen2PlayerNew = Gen2PlayerModule.new
    Gen2PlayerModule.new = function(cx, cy, facing, spriteDef)
      local p = origGen2PlayerNew(cx, cy, facing, spriteDef)
      if localSelectedSprite and _G.Game and _G.Game.data then
        local sprites = _G.Game.data.gen2Sprites or _G.Game.data.sprites
        if sprites and sprites[localSelectedSprite] then
          p:setSprite(sprites[localSelectedSprite])
        end
      end
      return p
    end
  end

  -- Redeem Recovery Token to Restore Lost Save
  openRedeemTokenMenu = function(game)
    local NamingScreen = require("src.ui.NamingScreen")
    local okScreens, Screens = pcall(require, "src.ui.Screens")
    local namingId = isGen2 and "Gen2NamingScreen" or "NamingScreen"
    local tokenOpts = {
      maxLen = 8,
      onDone = function(enteredToken)
        if not enteredToken or #enteredToken == 0 then return end
        enteredToken = enteredToken:gsub("%s+", ""):upper()

        local res = gtsApiPost({ action = "redeem_token", token = enteredToken }, 3.0)
        if res and res.success and res.account then
          local acc = res.account
          mmoLevel = acc.level or 1
          mmoXp = acc.xp or 0
          mmoToken = acc.token or enteredToken
          localSelectedSprite = acc.spriteId or "SPRITE_RED"
          if acc.title then localTrainerTitle = acc.title end
          if acc.favoriteMon then localFavoriteMon = acc.favoriteMon end

          local newSave = nil
          if isGen2 then
            local okGen2Save, Gen2SaveModule = pcall(require, "src.core.gen2.Save")
            if okGen2Save and Gen2SaveModule and Gen2SaveModule.newGame then
              newSave = Gen2SaveModule.newGame({ playerName = acc.name or "GOLD" })
            end
          end
          if not newSave then
            local SaveDataModule = pcall(require, "src.core.SaveData") and require("src.core.SaveData") or nil
            local bootCfg = game.bootConfig and game:bootConfig() or nil
            newSave = (SaveDataModule and SaveDataModule.newGame and SaveDataModule.newGame(bootCfg)) or {}
          end

          newSave.player = newSave.player or {}
          newSave.player.name = acc.name or (isGen2 and "GOLD" or "RED")
          newSave.player.id = acc.trainerId or getTrainerInfo(game.save)
          newSave.player.map = defaultStartingOutdoor
          newSave.player.x = defaultStartingOutdoorX
          newSave.player.y = defaultStartingOutdoorY
          newSave.player.facing = "down"
          newSave.player.surfing = false
          if isGen2 then
            newSave.position = {
              map = defaultStartingOutdoor,
              x = defaultStartingOutdoorX,
              y = defaultStartingOutdoorY,
              facing = "down"
            }
            newSave.spawn = defaultStartingOutdoor
            newSave.player.money = 3000
          else
            newSave.lastHeal = { map = defaultStartingOutdoor, x = defaultStartingOutdoorX, y = defaultStartingOutdoorY }
            newSave.lastOutdoor = { id = defaultStartingOutdoor, x = defaultStartingOutdoorX, y = defaultStartingOutdoorY }
            newSave.money = 3000
          end
          newSave.blackoutCount = acc.blackoutCount or 0
          newSave.onlineAccount = acc

          game.save = newSave
          if game.adoptSave then game:adoptSave(game.save) end
          saveOnlineAccount(game.save)
          writeOnlineSave(game.save)

          applyPlayerSprite(game, localSelectedSprite)
          isGtsServerConnected = true

          local ow = getWorld(game)
          if ow then
            ow.lastOutdoor = { id = defaultStartingOutdoor, x = defaultStartingOutdoorX, y = defaultStartingOutdoorY }
            if ow.setMap then
              pcall(function() ow:setMap(defaultStartingOutdoor, defaultStartingOutdoorX, defaultStartingOutdoorY, "down") end)
            end
          end

          syncLocalProfile(game, 0)
          fetchGtsServerSync(acc.trainerId)

          game.stack:push(TextBox.new(game, wrapText(string.format("TOKEN REDEEMED!\nWELCOME BACK, %s!\nMMO LEVEL %d RESTORED!", acc.name or "TRAINER", mmoLevel)), function()
            openOnlineOptionsMenu(game)
          end))
        else
          local err = (res and res.error) or "TOKEN NOT FOUND"
          game.stack:push(TextBox.new(game, wrapText(string.format("ERROR: %s!\nCOULD NOT RESTORE SAVE.", err))))
        end
      end
    }
    if okScreens and Screens and Screens.push then
      Screens.push(game, namingId, tokenOpts)
    else
      game.stack:push(NamingScreen.new(game, tokenOpts))
    end
  end

  -- Fresh Online Player Creation & Authentic Naming Screen
    openFreshOnlinePlayerMenu = function(game)
    local NamingScreen = require("src.ui.NamingScreen")

    local function pickCharacterSprite(chosenName)
      local spriteItems = {}
      for _, av in ipairs(AVAILABLE_AVATARS) do
        table.insert(spriteItems, {
          label = av.label,
          onSelect = function()
            local chosenSprite = av.id

            local res = gtsApiPost({
              action = "register_player",
              isNewCharacter = true,
              name = chosenName,
              spriteId = chosenSprite,
              title = localTrainerTitle,
              badges = 0,
              pokedexCount = 0
            }, 2.0)

            if res and res.success and res.account then
              local acc = res.account
              local newTid = tonumber(acc.trainerId) or 100001
              mmoLevel = 1
              mmoXp = 0
              mmoToken = acc.token
              localSelectedSprite = chosenSprite
              isGtsServerConnected = true

              -- Initialize Fresh Player Save via Gen 2 Save.newGame or Gen 1 SaveData.newGame
              local newSave = nil
              if isGen2 then
                local okGen2Save, Gen2SaveModule = pcall(require, "src.core.gen2.Save")
                if okGen2Save and Gen2SaveModule and Gen2SaveModule.newGame then
                  newSave = Gen2SaveModule.newGame({ playerName = chosenName })
                end
              end
              if not newSave then
                local SaveDataModule = pcall(require, "src.core.SaveData") and require("src.core.SaveData") or nil
                local bootCfg = game.bootConfig and game:bootConfig() or nil
                newSave = (SaveDataModule and SaveDataModule.newGame and SaveDataModule.newGame(bootCfg)) or {}
              end

              newSave.player = newSave.player or {}
              newSave.player.name = chosenName
              newSave.player.id = newTid
              newSave.player.map = defaultStartingIndoor
              newSave.player.x = defaultStartingIndoorX
              newSave.player.y = defaultStartingIndoorY
              newSave.player.facing = isGen2 and "down" or "up"
              newSave.player.surfing = false
              newSave.flags = newSave.flags or {}
              newSave.engineFlags = newSave.engineFlags or {}
              newSave.events = newSave.events or {}
              newSave.eventFlags = newSave.eventFlags or {}
              if isGen2 then
                newSave.position = {
                  map = defaultStartingIndoor,
                  x = defaultStartingIndoorX,
                  y = defaultStartingIndoorY,
                  facing = "down"
                }
                newSave.spawn = defaultStartingOutdoor
                newSave.player.money = 3000
                newSave.player.coins = 0
              else
                newSave.lastHeal = { map = defaultStartingOutdoor, x = defaultStartingOutdoorX, y = defaultStartingOutdoorY }
                newSave.lastOutdoor = { id = defaultStartingOutdoor, x = defaultStartingOutdoorX, y = defaultStartingOutdoorY }
                newSave.money = 3000
                newSave.coins = 0
              end
              newSave.party = {}
              newSave.badges = {}
              newSave.pokedex = newSave.pokedex or { owned = {}, seen = {} }
              newSave.inventory = newSave.inventory or {}
              newSave.inventory["POTION"] = 1
              newSave.pcItems = { POTION = 1 }
              newSave.onlineAccount = {
                trainerId = tostring(newTid),
                name = chosenName,
                level = 1,
                xp = 0,
                token = acc.token,
                spriteId = chosenSprite,
                title = localTrainerTitle,
                favoriteMon = localFavoriteMon
              }

              game.save = newSave
              if game.adoptSave then game:adoptSave(game.save) end
              saveOnlineAccount(game.save)
              writeOnlineSave(game.save) -- Dedicated save_online.lua (leaves save.lua untouched!)

              -- Apply sprite to local player immediately
              applyPlayerSprite(game, chosenSprite)

              -- Warp/load starting map in bedroom & set starting outdoor town as remembered outdoor map
              local ow = getWorld(game)
              if ow then
                ow.lastOutdoor = { id = defaultStartingOutdoor, x = defaultStartingOutdoorX, y = defaultStartingOutdoorY }
                if ow.setMap then
                  pcall(function() ow:setMap(defaultStartingIndoor, defaultStartingIndoorX, defaultStartingIndoorY, isGen2 and "down" or "up") end)
                end
              end

              syncLocalProfile(game, 0)
              fetchGtsServerSync(newTid)

              if ow and ow.player and ow.map and netOutChannel then
                local p = ow.player
                local delta = Collision.DELTA[p.facing] or { 0, 1 }
                local followerSpecies = game.save.party and game.save.party[1] and game.save.party[1].species

                netOutChannel:push({
                  url = GTS_SERVER_URL .. "/gts",
                  body = Json.encode({
                    action = "sync_pos",
                    modVersion = MOD_VERSION,
                    version = MOD_VERSION,
                    gameVersion = select(1, getClientVersionInfo()),
                    recompVersion = select(2, getClientVersionInfo()),
                    trainerId = tostring(newTid),
                    name = chosenName,
                    spriteId = localSelectedSprite,
                    title = localTrainerTitle,
                    level = 1,
                    map = ow.map.id,
                    x = p.cellX,
                    y = p.cellY,
                    px = p.cellX * 16,
                    py = p.cellY * 16,
                    fx = p.cellX - delta[1],
                    fy = p.cellY - delta[2],
                    facing = p.facing,
                    moving = false,
                    species = followerSpecies
                  })
                })
              end

              local createdMsg = string.format("PLAYER CREATED!\nTRAINER ID: %d\nTOKEN: %s\nWELCOME TO GEN 1 ONLINE!", newTid, acc.token or "READY")
              game.stack:push(TextBox.new(game, wrapText(createdMsg), function()
                openOnlineOptionsMenu(game)
              end))
            else
              local err = (res and res.error) or "NETWORK_ERROR"
              local errMsg = string.format("COULD NOT CREATE PLAYER!\n%s", err)
              game.stack:push(TextBox.new(game, wrapText(errMsg)))
            end
          end
        })
      end
      game.stack:push(Menu.new(game, spriteItems, { tx = 1, ty = 1, tw = 18, maxVisible = 6, startCloses = true }))
    end

    local function startNewCharacterFlow()
      local defaultName = (game.save and game.save.player and game.save.player.name) or "RED"
      local namingScreen = NamingScreen.new(game, {
        title = Strings("YOUR NAME?"),
        maxLen = 7,
        default = defaultName,
        onDone = function(enteredName)
          enteredName = (enteredName or ""):gsub("^%s+", ""):gsub("%s+$", "")
          if #enteredName == 0 then enteredName = "RED" end

          if Profanity and Profanity.contains and Profanity.contains(enteredName) then
            game.stack:push(TextBox.new(game, wrapText("NAME CONTAINS INAPPROPRIATE LANGUAGE!\nPLEASE CHOOSE ANOTHER NAME."), function()
              openFreshOnlinePlayerMenu(game)
            end))
            return
          end

          local check = gtsApiGet("/player/check_name?name=" .. enteredName, 1.5)
          if check and check.taken then
            local reasonText = (check.reason == "PROFANITY_DETECTED" and "INAPPROPRIATE LANGUAGE DETECTED!") or string.format("NAME '%s' IS TAKEN ON SERVER!", enteredName)
            game.stack:push(TextBox.new(game, wrapText(reasonText .. "\nPLEASE CHOOSE ANOTHER NAME."), function()
              openFreshOnlinePlayerMenu(game)
            end))
          else
            pickCharacterSprite(enteredName)
          end
        end
      })
      game.stack:push(namingScreen)
    end

    local connectOptions = {
      {
        label = "CREATE NEW PLAYER",
        onSelect = function()
          startNewCharacterFlow()
        end
      },
      {
        label = "REDEEM RECOVERY TOKEN",
        onSelect = function()
          openRedeemTokenMenu(game)
        end
      }
    }

    game.stack:push(Menu.new(game, connectOptions, { tx = 1, ty = 1, tw = 18, maxVisible = 6, startCloses = true }))
  end

  -- In-Game Global & Local MMO Chat Menu
  openMmoChatMenu = function(game)
    local trainerId, trainerName = getTrainerInfo(game.save)

    local chatOptions = {
      {
        label = "SEND CHAT MESSAGE",
        onSelect = function()
          local chatPresets = {
            "HELLO EVERYONE!",
            "LOOKING FOR TRADES!",
            "ANYONE READY FOR PVP?",
            "GG, WELL PLAYED!",
            "JUST CAUGHT A RARE MON!",
            "AT INDIGO PLATEAU!",
            "TRADING AT GTS!",
            "EXPLORING KANTO!"
          }
          local presetItems = {}
          for _, msgText in ipairs(chatPresets) do
            table.insert(presetItems, {
              label = msgText,
              onSelect = function()
                local cleanText = (Profanity and Profanity.censor) and Profanity.censor(msgText) or msgText
                local res = gtsApiPost({
                  action = "send_chat",
                  trainerId = trainerId,
                  name = trainerName,
                  text = cleanText,
                  scope = "global"
                }, 1.5)
                if res and res.success then
                  game.stack:push(TextBox.new(game, wrapText(string.format("CHAT BROADCAST:\n%s", cleanText))))
                else
                  game.stack:push(TextBox.new(game, wrapText("COULD NOT SEND CHAT TO SERVER!")))
                end
              end
            })
          end
          game.stack:push(Menu.new(game, presetItems, { tx = 1, ty = 1, tw = 18, maxVisible = 6, startCloses = true }))
        end
      },
      {
        label = "VIEW CHAT LOG (50)",
        onSelect = function()
          local res = gtsApiGet("/chat/history", 1.5)
          local msgs = (res and res.success and res.messages) or {}
          local logItems = {}
          for i = #msgs, 1, -1 do
            local m = msgs[i]
            local line = string.format("[%s] %s: %s", m.scope == "global" and "G" or "L", (m.name or "TR"):sub(1, 6), m.text)
            if #line > 16 then line = line:sub(1, 16) end
            table.insert(logItems, {
              label = line,
              onSelect = function()
                game.stack:push(TextBox.new(game, wrapText(string.format("%s (%s):\n%s", m.name or "TRAINER", m.scope or "global", m.text))))
              end
            })
          end
          if #logItems == 0 then
            game.stack:push(TextBox.new(game, wrapText("NO CHAT MESSAGES YET!")))
            return
          end
          game.stack:push(Menu.new(game, logItems, { tx = 1, ty = 1, tw = 18, maxVisible = 6, startCloses = true }))
        end
      },
      { label = "EXIT", onSelect = function() end }
    }

    game.stack:push(Menu.new(game, chatOptions, { tx = 1, ty = 1, tw = 18, maxVisible = 6, startCloses = true }))
  end

    -- =========================================================================
  -- CO-OP MULTIPLAYER PARTY SYSTEM (Shared Double XP, Party Warp & Status HUD)
  -- =========================================================================

  openPartyMainMenu = function(game)
    local trainerId, trainerName = getTrainerInfo(game.save)
    local gWorld = getWorld(game)
    local curMap = (gWorld and gWorld.map and gWorld.map.id) or defaultStartingOutdoor
    local px = (gWorld and gWorld.player and gWorld.player.cellX) or defaultStartingOutdoorX
    local py = (gWorld and gWorld.player and gWorld.player.cellY) or defaultStartingOutdoorY

    if not activeParty then
      local soloItems = {
        {
          label = "CREATE PARTY",
          onSelect = function()
            local res = gtsApiPost({
              action = "party_create",
              trainerId = trainerId,
              name = trainerName,
              level = mmoLevel or 1,
              map = curMap,
              x = px,
              y = py,
              spriteId = localSelectedSprite
            }, 1.5)
            if res and res.success then
              activeParty = res.party
              local msg = "PARTY CREATED!\nINVITE PLAYERS TO SHARE DOUBLE XP & WARP!"
              game.stack:push(TextBox.new(game, wrapText(msg), function()
                openPartyMainMenu(game)
              end))
            else
              game.stack:push(TextBox.new(game, wrapText("COULD NOT CREATE PARTY!")))
            end
          end
        },
        {
          label = "INVITE PLAYER",
          onSelect = function()
            local pRes = gtsApiGet("/gts/players", 1.5)
            local players = (pRes and pRes.players) or {}
            local inviteItems = {}
            for tid, p in pairs(players) do
              if tostring(tid) ~= tostring(trainerId) then
                local pNameShort = (p.name or "TRAINER"):sub(1, 8)
                table.insert(inviteItems, {
                  label = string.format("%s (LV%d)", pNameShort, p.level or 1),
                  onSelect = function()
                    local iRes = gtsApiPost({
                      action = "party_invite",
                      trainerId = trainerId,
                      name = trainerName,
                      targetId = tid,
                      level = mmoLevel or 1,
                      map = curMap,
                      x = px,
                      y = py,
                      spriteId = localSelectedSprite
                    }, 1.5)
                    if iRes and iRes.success then
                      local msg = string.format("INVITATION SENT TO %s!", p.name or "TRAINER")
                      game.stack:push(TextBox.new(game, wrapText(msg)))
                    else
                      game.stack:push(TextBox.new(game, wrapText("COULD NOT SEND INVITE!")))
                    end
                  end
                })
              end
            end
            if #inviteItems == 0 then
              game.stack:push(TextBox.new(game, wrapText("NO OTHER PLAYERS CURRENTLY ONLINE.")))
            else
              table.insert(inviteItems, { label = "BACK", onSelect = function() end })
              game.stack:push(Menu.new(game, inviteItems, { tx = 0, ty = 0, tw = 20, maxVisible = 7, startCloses = true }))
            end
          end
        },
        { label = "BACK", onSelect = function() end }
      }
      game.stack:push(Menu.new(game, soloItems, { tx = 0, ty = 0, tw = 20, maxVisible = 7, startCloses = true }))
      return
    end

    -- In active party
    local isLeader = (tostring(activeParty.leaderId) == tostring(trainerId))
    local partyItems = {
      {
        label = "MEMBERS & HUD",
        onSelect = function()
          local memberItems = {}
          for mid, m in pairs(activeParty.members or {}) do
            local leaderTag = (tostring(mid) == tostring(activeParty.leaderId)) and "*" or ""
            local mNameShort = (m.name or "TRAINER"):sub(1, 8)
            table.insert(memberItems, {
              label = string.format("%s%s (LV%d)", mNameShort, leaderTag, m.level or 1),
              onSelect = function()
                local statusMsg = string.format("PARTY MEMBER:\nNAME: %s\nLEVEL: %d\nMAP: %s", m.name or "TRAINER", m.level or 1, m.map or "UNKNOWN")
                game.stack:push(TextBox.new(game, wrapText(statusMsg)))
              end
            })
          end
          table.insert(memberItems, { label = "BACK", onSelect = function() end })
          game.stack:push(Menu.new(game, memberItems, { tx = 0, ty = 0, tw = 20, maxVisible = 7, startCloses = true }))
        end
      },
      {
        label = "WARP TO MEMBER",
        onSelect = function()
          local warpItems = {}
          for mid, m in pairs(activeParty.members or {}) do
            if tostring(mid) ~= tostring(trainerId) then
              local mNameShort = (m.name or "TRAINER"):sub(1, 10)
              table.insert(warpItems, {
                label = string.format("WARP: %s", mNameShort),
                onSelect = function()
                  local wRes = gtsApiPost({ action = "party_warp_target", targetId = mid }, 1.5)
                  local wWorld = getWorld(game)
                  if wRes and wRes.success and wWorld and wWorld.setMap then
                    pcall(function() require("src.core.Sound").play(game.data, "Teleport_Exit1") end)
                    wWorld:setMap(wRes.map or defaultStartingOutdoor, (wRes.x or 5) + 1, wRes.y or 5, "down")
                    local msg = string.format("WARPED TO %s!", m.name or "TEAMMATE")
                    game.stack:push(TextBox.new(game, wrapText(msg)))
                  else
                    game.stack:push(TextBox.new(game, wrapText("COULD NOT WARP TO MEMBER!")))
                  end
                end
              })
            end
          end
          if #warpItems == 0 then
            game.stack:push(TextBox.new(game, wrapText("NO OTHER PARTY MEMBERS TO WARP TO.")))
          else
            table.insert(warpItems, { label = "BACK", onSelect = function() end })
            game.stack:push(Menu.new(game, warpItems, { tx = 0, ty = 0, tw = 20, maxVisible = 7, startCloses = true }))
          end
        end
      },
      {
        label = "INVITE PLAYER",
        onSelect = function()
          local pRes = gtsApiGet("/gts/players", 1.5)
          local players = (pRes and pRes.players) or {}
          local inviteItems = {}
          for tid, p in pairs(players) do
            if tostring(tid) ~= tostring(trainerId) and not (activeParty.members and activeParty.members[tostring(tid)]) then
              local pNameShort = (p.name or "TRAINER"):sub(1, 8)
              table.insert(inviteItems, {
                label = string.format("%s (LV%d)", pNameShort, p.level or 1),
                onSelect = function()
                  local iRes = gtsApiPost({
                    action = "party_invite",
                    trainerId = trainerId,
                    name = trainerName,
                    targetId = tid,
                    level = mmoLevel or 1,
                    map = curMap,
                    x = px,
                    y = py,
                    spriteId = localSelectedSprite
                  }, 1.5)
                  if iRes and iRes.success then
                    local msg = string.format("INVITATION SENT TO %s!", p.name or "TRAINER")
                    game.stack:push(TextBox.new(game, wrapText(msg)))
                  else
                    game.stack:push(TextBox.new(game, wrapText("COULD NOT SEND INVITE!")))
                  end
                end
              })
            end
          end
          if #inviteItems == 0 then
            game.stack:push(TextBox.new(game, wrapText("NO OTHER AVAILABLE PLAYERS ONLINE.")))
          else
            table.insert(inviteItems, { label = "BACK", onSelect = function() end })
            game.stack:push(Menu.new(game, inviteItems, { tx = 0, ty = 0, tw = 20, maxVisible = 7, startCloses = true }))
          end
        end
      },
      {
        label = "LEAVE PARTY",
        onSelect = function()
          gtsApiPost({ action = "party_leave", trainerId = trainerId }, 1.5)
          activeParty = nil
          game.stack:push(TextBox.new(game, wrapText("LEFT THE PARTY.")))
        end
      },
      { label = "BACK", onSelect = function() end }
    }

    game.stack:push(Menu.new(game, partyItems, { tx = 0, ty = 0, tw = 20, maxVisible = 7, startCloses = true }))
  end

    -- Online Options Menu (Shown in Start Menu once connected)
  openOnlineOptionsMenu = function(game)
    local trainerId, trainerName = getTrainerInfo(game.save)
    loadOnlineAccount(game.save)

    local items = {
      {
        label = (activeParty and "PARTY (ACTIVE)") or "CO-OP PARTY",
        onSelect = function()
          openPartyMainMenu(game)
        end
      },
      {
        label = "MY PROFILE",
        onSelect = function()
          syncLocalProfile(game, 0)
          openTrainerCardScreen(game, trainerId, { name = trainerName })
        end
      },
      {
        label = string.format("EXP (LV%d)", mmoLevel or 1),
        onSelect = function()
          openMmoLevelInfoScreen(game)
        end
      },
      {
        label = "GLOBAL CHAT",
        onSelect = function() openMmoChatMenu(game) end
      },
      {
        label = "ONLINE SETTINGS",
        onSelect = function() openMyProfileMenu(game) end
      },
      {
        label = string.format("VERSION: V%s", MOD_VERSION),
        onSelect = function()
          local srvInfo = gtsApiGet("/server/info", 1.5)
          local srvVer = (srvInfo and (srvInfo.modVersion or srvInfo.version)) or MOD_VERSION
          local msg = string.format("MOD VERSION: V%s\nSERVER VERSION: V%s\nPROTOCOLS SYNCED!", MOD_VERSION, srvVer)
          game.stack:push(TextBox.new(game, wrapText(msg)))
        end
      },
      {
        label = "RECOVERY TOKEN",
        onSelect = function()
          local tokStr = mmoToken or (game.save and game.save.onlineAccount and game.save.onlineAccount.token) or "NONE"
          local tid = getTrainerInfo(game.save)
          local msg = string.format("RECOVERY TOKEN:\n%s\nTRAINER ID: %s\nUSE THIS TOKEN TO RECOVER YOUR SAVE ON ANY DEVICE!", tokStr, tid)
          game.stack:push(TextBox.new(game, wrapText(msg)))
        end
      },
      {
        label = "RECOVER WITH TOKEN",
        onSelect = function()
          openRedeemTokenMenu(game)
        end
      },
      {
        label = "RESET / SWITCH",
        onSelect = function()
          local confirmMenu = {
            {
              label = "NO, KEEP CURRENT",
              onSelect = function() end
            },
            {
              label = "YES, RESET",
              onSelect = function()
                local fs = love.filesystem
                if fs then
                  local sf, bf, tf = getOnlineSaveFiles()
                  pcall(function() fs.remove(sf) end)
                  pcall(function() fs.remove(bf) end)
                  pcall(function() fs.remove(tf) end)
                end
                openFreshOnlinePlayerMenu(game)
              end
            }
          }
          game.stack:push(TextBox.new(game, wrapText("WARNING: THIS WILL OVERWRITE YOUR ONLINE CHARACTER! LOCAL SAVE IS UNTOUCHED. PROCEED?"), function()
            game.stack:push(Menu.new(game, confirmMenu, { tx = 0, ty = 0, tw = 20, maxVisible = 6, startCloses = true }))
          end))
        end
      },
      {
        label = "DISCONNECT",
        onSelect = function()
          isGtsServerConnected = false
          netNpcs = {}
          netFollowers = {}
          game.stack:push(TextBox.new(game, wrapText("DISCONNECTED FROM GEN 1 ONLINE SERVER.")))
        end
      }
    }

    game.stack:push(Menu.new(game, items, { tx = 0, ty = 0, tw = 20, maxVisible = 7, startCloses = true }))
  end

  handleConnectToServer = function(game)
    -- 0. Enforce Pokémon Gold (Gen 2) Only
    if not isGen2 then
      game.stack:push(TextBox.new(game, wrapText("THE ONLINE SERVER HAS MIGRATED EXCLUSIVELY TO POKEMON GOLD (GEN 2)!\nPLEASE LAUNCH POKEMON GOLD TO PLAY ONLINE.")))
      return
    end

    -- 1. Verify Mod Version Handshake with Server First
    local srvInfo = gtsApiGet("/server/info", 3.0)
    if srvInfo and (srvInfo.modVersion or srvInfo.version) then
      local srvVer = srvInfo.modVersion or srvInfo.version
      if srvVer ~= MOD_VERSION then
        local msg = string.format("VERSION MISMATCH!\nSERVER IS ON V%s\nYOUR MOD IS ON V%s\nPLEASE UPDATE TO PLAY!", srvVer, MOD_VERSION)
        game.stack:push(TextBox.new(game, wrapText(msg)))
        return
      end
    end

    -- 2. Backup the local offline save in memory and capture exact offline coordinates
    if game and game.save and not isGtsServerConnected then
      local ow = getWorld(game)
      if game.snapshotSave then
        pcall(function() game:snapshotSave() end)
      elseif ow and ow.player and ow.map then
        local p = ow.player
        if isGen2 then
          game.save.position = game.save.position or {}
          game.save.position.map = ow.map.id
          game.save.position.x = p.cellX
          game.save.position.y = p.cellY
          game.save.position.facing = p.facing
        end
        game.save.player = game.save.player or {}
        game.save.player.map = ow.map.id
        game.save.player.x = p.cellX
        game.save.player.y = p.cellY
        game.save.player.facing = p.facing
      end
      local SaveSerializer = require("src.core.SaveSerializer")
      local ok, encoded = pcall(SaveSerializer.encode, game.save)
      if ok and encoded then
        offlineSaveBackup = SaveSerializer.decode(encoded)
      else
        offlineSaveBackup = game.save
      end
    end

    -- 3. Check if a dedicated online save (save_online.lua / save_online_gold.lua) exists on disk
    local onlineSave = loadOnlineSave()
    if onlineSave and onlineSave.onlineAccount and onlineSave.onlineAccount.token and onlineSave.onlineAccount.name then
      local pMap = (onlineSave.position and onlineSave.position.map) or (onlineSave.player and onlineSave.player.map) or (onlineSave.map and onlineSave.map.id) or defaultStartingOutdoor
      local px = (onlineSave.position and onlineSave.position.x) or (onlineSave.player and onlineSave.player.x) or (onlineSave.map and onlineSave.map.x) or defaultStartingOutdoorX
      local py = (onlineSave.position and onlineSave.position.y) or (onlineSave.player and onlineSave.player.y) or (onlineSave.map and onlineSave.map.y) or defaultStartingOutdoorY
      local pDir = (onlineSave.position and onlineSave.position.facing) or (onlineSave.player and onlineSave.player.facing) or (onlineSave.map and onlineSave.map.facing) or "down"

      game.save = onlineSave
      if isGen2 then
        game.save.position = game.save.position or {}
        game.save.position.map = pMap
        game.save.position.x = px
        game.save.position.y = py
        game.save.position.facing = pDir
      end
      game.save.player = game.save.player or {}
      game.save.player.map = pMap
      game.save.player.x = px
      game.save.player.y = py
      game.save.player.facing = pDir

      if game.adoptSave then game:adoptSave(game.save) end

      local acc = game.save.onlineAccount
      local tid, currentName = getTrainerInfo(game.save)
      loadOnlineAccount(game.save)
      isGtsServerConnected = true

      -- WARP / SET MAP to exact online coordinates FIRST!
      local ow = getWorld(game)
      if ow and ow.setMap then
        pcall(function() ow:setMap(pMap, px, py, pDir) end)
        if ow.player then
          ow.player.cellX = px
          ow.player.cellY = py
          ow.player.px = px * 16
          ow.player.py = py * 16
          ow.player.facing = pDir
        end
      end

      syncLocalProfile(game, 0)
      applyPlayerSprite(game, localSelectedSprite)
      writeOnlineSave(game.save)

      local ok = fetchGtsServerSync(tid)
      if ok and ow and ow.player and ow.map and netOutChannel then
        local p = ow.player
        local delta = Collision.DELTA[p.facing] or { 0, 1 }
        local followerSpecies = game.save.party and game.save.party[1] and game.save.party[1].species

        netOutChannel:push({
          url = GTS_SERVER_URL .. "/gts",
          body = Json.encode({
            action = "sync_pos",
            modVersion = MOD_VERSION,
            version = MOD_VERSION,
            gameVersion = select(1, getClientVersionInfo()),
            recompVersion = select(2, getClientVersionInfo()),
            trainerId = tid,
            name = acc.name or currentName,
            spriteId = localSelectedSprite,
            title = localTrainerTitle,
            level = mmoLevel,
            map = ow.map.id,
            x = p.cellX,
            y = p.cellY,
            px = p.cellX * 16,
            py = p.cellY * 16,
            fx = p.cellX - delta[1],
            fy = p.cellY - delta[2],
            facing = p.facing,
            moving = p.moving,
            species = followerSpecies
          })
        })
        local connMsg = string.format("CONNECTED TO SERVER!\nONLINE SAVE: %s", acc.name or currentName)
        game.stack:push(TextBox.new(game, wrapText(connMsg), function()
          openOnlineOptionsMenu(game)
        end))
      else
        game.stack:push(TextBox.new(game, wrapText("CANNOT CONNECT TO SERVER! CHECK CONNECTION.")))
      end
    else
      -- 3. No online save exists yet on device: launch Character Creation without touching local save.lua!
      openFreshOnlinePlayerMenu(game)
    end
  end

    -- Hook Start Menu
  mod.hooks:wrap("ui.start_menu.items", function(nextFn, game, items)
    local list = nextFn and nextFn(game, items) or items
    if not list or type(list) ~= "table" then list = items end

        local hasAccount = game.save and game.save.onlineAccount and game.save.onlineAccount.token
    local isConnected = isGtsServerConnected and hasAccount
    local menuLabel = isConnected and "ONLINE OPTIONS" or "CONNECT TO SERVER"

    -- Remove manual SAVE from Start Menu when online (Everything is auto-persisted)
    if isConnected then
      local filtered = {}
      for _, item in ipairs(list) do
        local lbl = tostring(item and item.label or ""):upper()
        if not lbl:find("SAVE") or lbl:find("OPTION") or lbl:find("RESET") then
          table.insert(filtered, item)
        end
      end
      list = filtered
    end

    local curLvl = mmoLevel or 1
    local curXp = mmoXp or 0
    local nextReq = calculateXpForLevel(curLvl + 1)
    local toNext = (curLvl >= 100) and 0 or math.max(0, nextReq - curXp)

        local expItem = {
      label = string.format("EXP (LV%d)", curLvl),
      onSelect = function()
        openMmoLevelInfoScreen(game)
      end,
    }

    local versionItem = {
      label = "VERSION",
      onSelect = function()
        local srvInfo = gtsApiGet("/server/info", 1.5)
        local srvVer = (srvInfo and (srvInfo.modVersion or srvInfo.version)) or "OFFLINE"
        local statusStr = (srvVer == MOD_VERSION) and "SYNCED" or (srvVer == "OFFLINE" and "OFFLINE" or "UPDATE REQ")
        local gName, rVer = getClientVersionInfo()
        local msg = string.format("GEN 1 ONLINE\nMOD: V%s\nGAME: %s\nRECOMP: %s\nSERVER: V%s\nSTATUS: %s", MOD_VERSION, gName, rVer, srvVer, statusStr)
        game.stack:push(TextBox.new(game, wrapText(msg)))
      end,
    }

    local newItem = {
      label = isConnected and "ONLINE" or "CONNECT",
      onSelect = function()
        if isConnected then
          openOnlineOptionsMenu(game)
        else
          handleConnectToServer(game)
        end
      end,
    }

    local inserted = false
    for i, item in ipairs(list) do
      if item and item.label and (tostring(item.label):find("OPTION") or tostring(item.label):find("SAVE")) then
        table.insert(list, i, newItem)
        inserted = true
        break
      end
    end
    if not inserted then
      table.insert(list, newItem)
    end
    return list
  end)

  -- Hook PC Menu (Adds GTS to Pokemon Center & Bedroom PC menus)
  mod.hooks:wrap("ui.pc.items", function(nextFn, game, items)
    local list = nextFn and nextFn(game, items) or items
    if not list or type(list) ~= "table" then list = items end

    local gtsItem = {
      label = "GTS",
      keepOpen = true,
      onSelect = function()
        pcall(function() require("src.core.Sound").play(game.data, "Enter_PC") end)
        openGtsMainMenu(game)
      end
    }

    table.insert(list, gtsItem)
    return list
  end)

  -- =========================================================================
  -- AUTOMATIC IMMEDIATE SAVE & SYNC ON ALL TRAINER / PARTY / TRADE / BATTLE ACTIONS
  -- =========================================================================

  local function onEvent(eventName, callback)
    if mod and mod.events and type(mod.events.on) == "function" then
      pcall(function() mod.events:on(eventName, callback) end)
    elseif mod and mod.events and type(mod.events.on) == "function" then
      pcall(function() mod.events.on(mod, eventName, callback) end)
    elseif Runtime and Runtime.events and type(Runtime.events.on) == "function" then
      pcall(function() Runtime.events:on(eventName, callback) end)
    end
  end

  -- 1. Battles Finished (Wild & Trainer Battles) - Handled in BattleState.finish hook below to prevent double XP triggers

  -- 2. Pokémon Caught
  onEvent("pokemon.caught", function(payload)
    if Game and Game.save then
      addMmoXp(Game, "catch")
      performForcedSave(Game)
      syncLocalProfile(Game, 0)
    end
  end)

  -- 3. Pokémon Evolved & Move Learned
  onEvent("pokemon.evolved", function(payload)
    if Game and Game.save then
      addMmoXp(Game, "breeding", 50)
      performForcedSave(Game)
      syncLocalProfile(Game, 0)
    end
  end)

  onEvent("pokemon.level_up", function(payload)
    if Game and Game.save then
      performForcedSave(Game)
    end
  end)

  onEvent("pokemon.move_learned", function(payload)
    if Game and Game.save then
      performForcedSave(Game)
    end
  end)

  -- 4. Trades & Pokémon Received
  onEvent("trade.completed", function(payload)
    if Game and Game.save then
      performForcedSave(Game)
      syncLocalProfile(Game, 0)
    end
  end)

  onEvent("pokemon.received", function(payload)
    if Game and Game.save then
      performForcedSave(Game)
      syncLocalProfile(Game, 0)
    end
  end)

  -- 5. Trainer Badges & Story Milestone Flags
  onEvent("flag.changed", function(payload)
    if Game and Game.save then
      performForcedSave(Game)
      syncLocalProfile(Game, 0)
    end
  end)

  -- 6. Blackout / Party Fainted
  onEvent("world.blacked_out", function(payload)
    if Game and Game.save then
      Game.save.blackoutCount = (Game.save.blackoutCount or 0) + 1
      saveOnlineAccount(Game.save)
      performForcedSave(Game)
      syncLocalProfile(Game, 0)
    end
  end)

  do
    -- 7. Nurse Joy Healing Finished
    local origFinishNurseHeal = OverworldState.finishNurseHeal
    OverworldState.finishNurseHeal = function(self, bye, onDone)
      if Game and Game.save then
        performForcedSave(Game)
        syncLocalProfile(Game, 0)
      end
      if origFinishNurseHeal then
        return origFinishNurseHeal(self, bye, onDone)
      end
    end

  -- 8. PC Box Storage Operations
  local BoxesModule = pcall(require, "src.pokemon.Boxes") and require("src.pokemon.Boxes") or nil
  if BoxesModule and BoxesModule.deposit then
    local origDeposit = BoxesModule.deposit
    BoxesModule.deposit = function(save, mon)
      local res = origDeposit(save, mon)
      if isGtsServerConnected and Game and Game.save then performForcedSave(Game) end
      return res
    end
  end

  -- 9. Bag & Inventory Operations
  local BagModule = pcall(require, "src.inventory.Bag") and require("src.inventory.Bag") or nil
  if BagModule then
    if BagModule.add then
      local origBagAdd = BagModule.add
      BagModule.add = function(save, itemId, count, data)
        local res = origBagAdd(save, itemId, count, data)
        if isGtsServerConnected and Game and Game.save then performForcedSave(Game) end
        return res
      end
    end
    if BagModule.remove then
      local origBagRemove = BagModule.remove
      BagModule.remove = function(save, itemId, count)
        local res = origBagRemove(save, itemId, count)
        if isGtsServerConnected and Game and Game.save then performForcedSave(Game) end
        return res
      end
    end
  end

  -- Hook Map Transition to clear and re-sync overworld entities
  local origSetMap = OverworldState.setMap
  OverworldState.setMap = function(self, mapId, cellX, cellY, facing)
    clearAllNetPlayers(self)
    local res = origSetMap(self, mapId, cellX, cellY, facing)
    lastPlayerMap = mapId
    if isGtsServerConnected and Game and Game.save then
      if Game.save.player then
        Game.save.player.map = mapId
        Game.save.player.x = cellX or Game.save.player.x or 3
        Game.save.player.y = cellY or Game.save.player.y or 6
        Game.save.player.facing = facing or Game.save.player.facing or "down"
      end
      if isGen2 and Game.save.position then
        Game.save.position.map = mapId
        Game.save.position.x = cellX or Game.save.position.x or 3
        Game.save.position.y = cellY or Game.save.position.y or 6
        Game.save.position.facing = facing or Game.save.position.facing or "down"
      end
      writeOnlineSave(Game.save)
    end
    NPCs.spawnForMap(self)
    return res
  end

  -- Hook Overworld UI to Draw Scaled-Down 70% Micro Pure Black Text HIGH ABOVE Player Heads
  local origDrawUI = OverworldState.drawUI
  OverworldState.drawUI = function(self)
    if origDrawUI then origDrawUI(self) end

    if isGtsServerConnected and Game and self.camera and self.player and _G.love and _G.love.graphics then
      local camX = self.camera.x or (self.player.cellX * 16)
      local camY = self.camera.y or (self.player.cellY * 16)

      -- Draw 70% micro pure black text with ZERO background rectangle
      local function drawHeaderTag(nameStr, sx, sy)
        love.graphics.push()
        love.graphics.setColor(0, 0, 0, 1)
        love.graphics.translate(sx, sy)
        love.graphics.scale(0.7, 0.7)
        Font.draw(nameStr, -math.floor(#nameStr * 4), 0)
        love.graphics.pop()
      end

      -- 1. Draw micro names high above remote player NPCs (28px above foot anchor)
      for tid, pNpc in pairs(netNpcs) do
        local rawData = netPlayerMap[tid] or {}
        local name = rawData.name or pNpc.name or "TRAINER"

        local sx = math.floor(pNpc.px - camX + 80)
        local sy = math.floor(pNpc.py - camY + 72 - 28)

        if sx >= -40 and sx <= 200 and sy >= -20 and sy <= 160 then
          drawHeaderTag(name, sx, sy)
        end
      end

      -- 2. Draw micro name high above local player's head (28px above center)
      local myName = (Game.save and Game.save.player and Game.save.player.name) or "YOU"
      local mySx = 80
      local mySy = 72 - 28
      drawHeaderTag(myName, mySx, mySy)
    end
  end

  -- Hook Overworld Update with TRUE ZERO-LAG Async Threading & Lockout Guard
  local origOverworldUpdate = OverworldState.update
  OverworldState.update = function(self, dt)
    -- LOCKOUT PLAYER MOVEMENT WHILE WAITING FOR CHALLENGE RESPONSE
    if isWaitingForChallenge then
      challengeWaitTimer = (challengeWaitTimer or 0) + dt
      if challengeWaitTimer > 16.0 then
        isWaitingForChallenge = false
        challengeWaitTimer = 0
        Game.stack:push(TextBox.new(Game, "CHALLENGE TIMED OUT\nNO RESPONSE."))
      end
      -- Maintain NPC movement lerp
      for _, pNpc in pairs(netNpcs) do updateNpcMovement(pNpc, dt) end
      for _, fNpc in pairs(netFollowers) do updateNpcMovement(fNpc, dt) end

      -- CRITICAL: Keep pushing sync_pos to the background thread every 150ms so it
      -- polls the server and brings back the ACCEPT_PVP / DECLINE response.
      local now = (_G.love and _G.love.timer and _G.love.timer.getTime) and _G.love.timer.getTime() or os.time()
      if now - lastSendTime >= 0.15 and self.player and self.map and netOutChannel then
        lastSendTime = now
        local trainerId, trainerName = getTrainerInfo(Game.save)
        local p = self.player
        local delta = Collision.DELTA[p.facing] or { 0, 1 }
        local followerSpecies = Game.save.party and Game.save.party[1] and Game.save.party[1].species
        netOutChannel:push({
          url = GTS_SERVER_URL .. "/gts",
          body = Json.encode({
            action = "sync_pos",
            trainerId = trainerId,
            sessionId = clientSessionId,
            name = trainerName,
            title = localTrainerTitle,
            map = self.map.id,
            x = p.cellX,
            y = p.cellY,
            px = p.px,
            py = p.py,
            fx = p.cellX - delta[1],
            fy = p.cellY - delta[2],
            facing = p.facing,
            moving = false,
            species = followerSpecies
          })
        })
      end

      -- Read any server responses the background thread has returned
      processGlobalThreadMessages(Game)
      return
    end

    if self.map then
      NPCs.spawnForMap(self)
    end
    if origOverworldUpdate then origOverworldUpdate(self, dt) end
    if not Game or not isGtsServerConnected then return end

    -- 1. Lerp smooth movement for all active MMO players and followers at 100% 60 FPS
    for _, pNpc in pairs(netNpcs) do updateNpcMovement(pNpc, dt) end
    for _, fNpc in pairs(netFollowers) do updateNpcMovement(fNpc, dt) end

    -- 2. Process incoming async thread messages
    processGlobalThreadMessages(Game)

    -- 3. Push position to background thread (Instant on movement OR 100ms interval)
    local ow = self
    local p = ow.player
    if p and ow.map and netOutChannel then
      local now = (_G.love and _G.love.timer and _G.love.timer.getTime) and _G.love.timer.getTime() or os.time()
      local positionChanged = (p.cellX ~= lastPlayerX) or (p.cellY ~= lastPlayerY) or (ow.map.id ~= lastPlayerMap)

      if positionChanged or (now - lastSendTime >= 0.10) then
        lastSendTime = now
        lastPlayerX = p.cellX
        lastPlayerY = p.cellY
        lastPlayerMap = ow.map.id

        if Game and Game.save then
          Game.save.player = Game.save.player or {}
          Game.save.player.map = ow.map.id
          Game.save.player.x = p.cellX
          Game.save.player.y = p.cellY
          Game.save.player.facing = p.facing

          Game.save.position = Game.save.position or {}
          Game.save.position.map = ow.map.id
          Game.save.position.x = p.cellX
          Game.save.position.y = p.cellY
          Game.save.position.facing = p.facing

          Game.save.map = Game.save.map or {}
          Game.save.map.id = ow.map.id
          Game.save.map.x = p.cellX
          Game.save.map.y = p.cellY
          Game.save.map.facing = p.facing
        end

        if positionChanged then
          local nowSec = (_G.love and _G.love.timer and _G.love.timer.getTime) and _G.love.timer.getTime() or os.time()
          if not lastPositionDiskSaveTime or (nowSec - lastPositionDiskSaveTime >= 2.0) then
            lastPositionDiskSaveTime = nowSec
            writeOnlineSave(Game.save)
          end
        end

        local trainerId, trainerName = getTrainerInfo(Game.save)
        local followerSpecies = Game.save.party and Game.save.party[1] and Game.save.party[1].species

        local delta = Collision.DELTA[p.facing] or { 0, 1 }
        local fx = p.cellX - delta[1]
        local fy = p.cellY - delta[2]

        local payload = {
          action = "sync_pos",
          modVersion = MOD_VERSION,
          version = MOD_VERSION,
          gameVersion = select(1, getClientVersionInfo()),
          recompVersion = select(2, getClientVersionInfo()),
          trainerId = trainerId,
          sessionId = clientSessionId,
          name = trainerName,
          spriteId = localSelectedSprite,
          title = localTrainerTitle,
          level = mmoLevel,
          map = ow.map.id,
          x = p.cellX,
          y = p.cellY,
          px = p.px,
          py = p.py,
          fx = fx,
          fy = fy,
          facing = p.facing,
          moving = p.moving,
          species = followerSpecies
        }

        netOutChannel:push({
          url = GTS_SERVER_URL .. "/gts",
          body = Json.encode(payload)
        })
      end
    end
  end


  local origTalkTo = OverworldState.talkTo
  OverworldState.talkTo = function(self, npc)
    local helpers = {
      wrapText = wrapText,
      getTrainerId = getTrainerId,
      fetchPlayerQuests = fetchPlayerQuests,
      questApiPost = gtsApiPost,
      activeQuestsCache = activeQuestsCache,
      findBugHeadButterfreeIndex = Quests.findBugHeadButterfreeIndex,
      Doubles = Doubles,
      addMmoXp = addMmoXp
    }
    if NPCs.talkTo(self, npc, helpers) then
      return
    end
    return origTalkTo and origTalkTo(self, npc)
  end

  -- Hook Overworld Interact (Facing any MMO player on the map and pressing A)
  local origInteract = OverworldState.interact
  OverworldState.interact = function(self)
    if isWaitingForChallenge then return end

    local p1 = self.player
    local fx, fy = p1:facingCell()

    for tid, pNpc in pairs(netNpcs) do
      if pNpc.cellX == fx and pNpc.cellY == fy then
        local rawData = netPlayerMap[tid] or {}
        local pName = rawData.name or "TRAINER"
        local targetTid = pNpc.trainerId or tid

        local items = {
          {
            label = "VIEW TRAINER CARD",
            onSelect = function()
              openTrainerCardScreen(Game, targetTid, rawData)
            end
          },
          {
            label = "PVP 1V1 SINGLES",
            onSelect = function()
              if not Game.save or not Game.save.party or #Game.save.party == 0 then
                Game.stack:push(TextBox.new(Game, wrapText("YOU NEED AT LEAST 1 POKéMON IN YOUR PARTY TO BATTLE!")))
                return
              end
              local myId, myName = getTrainerInfo(Game.save)
              local myPackedParty = Protocol.packParty(Game.save.party)
              local linkSeed = math.random(1, 2^30)
              local roomId = "BATTLE_"
                .. tostring(math.min(tonumber(myId) or 0, tonumber(targetTid) or 0))
                .. "_"
                .. tostring(math.max(tonumber(myId) or 0, tonumber(targetTid) or 0))
                .. "_" .. tostring(linkSeed)

              isWaitingForChallenge = true
              challengeWaitTimer = 0

              gtsApiPost({
                action = "send_challenge",
                targetId = targetTid,
                fromId = myId,
                fromName = myName,
                challengeType = "PVP",
                party = myPackedParty,
                seed = linkSeed,
                roomId = roomId
              }, 1.5)
              Game.stack:push(TextBox.new(Game, string.format("WAITING FOR %s\nTO ACCEPT 1V1 PVP...", pName)))
            end
          },
          {
            label = "PVP 2V2 DOUBLES",
            onSelect = function()
              if not Game.save or not Game.save.party or #Game.save.party == 0 then
                Game.stack:push(TextBox.new(Game, wrapText("YOU NEED AT LEAST 1 POKéMON IN YOUR PARTY TO BATTLE!")))
                return
              end
              local myId, myName = getTrainerInfo(Game.save)
              local myPackedParty = Protocol.packParty(Game.save.party)
              local linkSeed = math.random(1, 2^30)
              local roomId = "BATTLE_DBL_"
                .. tostring(math.min(tonumber(myId) or 0, tonumber(targetTid) or 0))
                .. "_"
                .. tostring(math.max(tonumber(myId) or 0, tonumber(targetTid) or 0))
                .. "_" .. tostring(linkSeed)

              isWaitingForChallenge = true
              challengeWaitTimer = 0

              gtsApiPost({
                action = "send_challenge",
                targetId = targetTid,
                fromId = myId,
                fromName = myName,
                challengeType = "PVP_DOUBLES",
                party = myPackedParty,
                seed = linkSeed,
                roomId = roomId
              }, 1.5)
              Game.stack:push(TextBox.new(Game, string.format("WAITING FOR %s\nTO ACCEPT 2V2 DOUBLES...", pName)))
            end
          },
          {
            label = "LINK TRADE",
            onSelect = function()
              if not Game.save or not Game.save.party or #Game.save.party == 0 then
                Game.stack:push(TextBox.new(Game, wrapText("YOU NEED AT LEAST 1 POKéMON IN YOUR PARTY TO TRADE!")))
                return
              end
              local myId, myName = getTrainerInfo(Game.save)
              local roomId = "TRADE_"
                .. tostring(math.min(tonumber(myId) or 0, tonumber(targetTid) or 0))
                .. "_"
                .. tostring(math.max(tonumber(myId) or 0, tonumber(targetTid) or 0))
                .. "_" .. tostring(math.random(1, 2^30))

              isWaitingForChallenge = true
              challengeWaitTimer = 0

              gtsApiPost({
                action = "send_challenge",
                targetId = targetTid,
                fromId = myId,
                fromName = myName,
                challengeType = "TRADE",
                roomId = roomId
              }, 1.5)
              Game.stack:push(TextBox.new(Game, wrapText(string.format("WAITING FOR %s TO ACCEPT TRADE...", pName))))
            end
          },
          { label = "CANCEL", onSelect = function() end }
        }
        Game.stack:push(Menu.new(Game, items, { tx = 1, ty = 1, tw = 16, th = 8 }))
        return
      end
    end
    return origInteract(self)
  end

  -- =========================================================================
  -- GEN 2 (GOLD) WORLD HOOKS (setMap, drawWorldBody, step, interact)
  -- =========================================================================
  local okGen2World, Gen2World = pcall(require, "src.world.gen2.World")
  if okGen2World and Gen2World then
    -- 1. Gen 2 Map Transition Hook
    local origGen2SetMap = Gen2World.setMap
    Gen2World.setMap = function(self, mapId, cx, cy, facing, opts)
      clearAllNetPlayers(self)
      local res = origGen2SetMap(self, mapId, cx, cy, facing, opts)
      lastPlayerMap = mapId
      local curGame = self.game or Game
      if isGtsServerConnected and curGame and curGame.save then
        if curGame.save.player then
          curGame.save.player.map = mapId
          curGame.save.player.x = cx or (self.player and self.player.cellX) or defaultStartingOutdoorX
          curGame.save.player.y = cy or (self.player and self.player.cellY) or defaultStartingOutdoorY
          curGame.save.player.facing = facing or (self.player and self.player.facing) or "down"
        end
        if curGame.save.position then
          curGame.save.position.map = mapId
          curGame.save.position.x = cx or (self.player and self.player.cellX) or defaultStartingOutdoorX
          curGame.save.position.y = cy or (self.player and self.player.cellY) or defaultStartingOutdoorY
          curGame.save.position.facing = facing or (self.player and self.player.facing) or "down"
        end
        writeOnlineSave(curGame.save)
      end
      NPCs.spawnForMap(self)
      return res
    end

    -- 2. Gen 2 Floating Micro Pure Black Name Tag Drawing
    local origGen2DrawBody = Gen2World.drawWorldBody
    Gen2World.drawWorldBody = function(self, s)
      if origGen2DrawBody then origGen2DrawBody(self, s) end
      local curGame = self.game or Game
      if isGtsServerConnected and curGame and self.camera and self.player and _G.love and _G.love.graphics then
        local camX = self.camera.x or (self.player.cellX * 16)
        local camY = self.camera.y or (self.player.cellY * 16)
        local G = _G.love.graphics

        local function drawHeaderTag(nameStr, sx, sy)
          G.push()
          G.setColor(0, 0, 0, 1)
          G.translate(sx, sy)
          G.scale(0.7 * (s or 1), 0.7 * (s or 1))
          Font.draw(nameStr, -math.floor(#nameStr * 4), 0)
          G.pop()
        end

        local zoom = s or 1
        -- Remote player name tags
        for tid, pNpc in pairs(netNpcs) do
          local rawData = netPlayerMap[tid] or {}
          local name = rawData.name or pNpc.name or "TRAINER"
          local sx = math.floor((pNpc.px - camX + 8) * zoom)
          local sy = math.floor((pNpc.py - camY - 14) * zoom)
          drawHeaderTag(name, sx, sy)
        end

        -- Local player name tag
        local myName = (curGame.save and curGame.save.player and curGame.save.player.name) or "YOU"
        local mySx = math.floor((self.player.px - camX + 8) * zoom)
        local mySy = math.floor((self.player.py - camY - 14) * zoom)
        drawHeaderTag(myName, mySx, mySy)
      end
    end

    -- 3. Gen 2 Overworld Step & Async Multi-Net Sync Hook
    local origGen2Step = Gen2World.step
    Gen2World.step = function(self)
      local curGame = self.game or Game
      -- LOCKOUT PLAYER MOVEMENT WHILE WAITING FOR CHALLENGE RESPONSE
      if isWaitingForChallenge then
        local dt = 1 / 60
        challengeWaitTimer = (challengeWaitTimer or 0) + dt
        if challengeWaitTimer > 16.0 then
          isWaitingForChallenge = false
          challengeWaitTimer = 0
          if curGame and curGame.stack then
            curGame.stack:push(TextBox.new(curGame, "CHALLENGE TIMED OUT\nNO RESPONSE."))
          end
        end
        for _, pNpc in pairs(netNpcs) do updateNpcMovement(pNpc, dt) end
        for _, fNpc in pairs(netFollowers) do updateNpcMovement(fNpc, dt) end

        local now = (_G.love and _G.love.timer and _G.love.timer.getTime) and _G.love.timer.getTime() or os.time()
        if now - lastSendTime >= 0.15 and self.player and self.map and netOutChannel then
          lastSendTime = now
          local trainerId, trainerName = getTrainerInfo(curGame.save)
          local p = self.player
          local delta = Collision.DELTA[p.facing] or { 0, 1 }
          local followerSpecies = curGame.save and curGame.save.party and curGame.save.party[1] and curGame.save.party[1].species
          netOutChannel:push({
            url = GTS_SERVER_URL .. "/gts",
            body = Json.encode({
              action = "sync_pos",
              modVersion = MOD_VERSION,
              version = MOD_VERSION,
              gameVersion = select(1, getClientVersionInfo()),
              recompVersion = select(2, getClientVersionInfo()),
              trainerId = trainerId,
              sessionId = clientSessionId,
              name = trainerName,
              title = localTrainerTitle,
              map = self.map.id,
              x = p.cellX,
              y = p.cellY,
              px = p.px,
              py = p.py,
              fx = p.cellX - delta[1],
              fy = p.cellY - delta[2],
              facing = p.facing,
              moving = false,
              species = followerSpecies
            })
          })
        end
        processGlobalThreadMessages(curGame)
        return
      end

      if self.map then
        NPCs.spawnForMap(self)
      end

      if origGen2Step then origGen2Step(self) end
      if not curGame or not isGtsServerConnected then return end

      local dt = 1 / 60
      for _, pNpc in pairs(netNpcs) do updateNpcMovement(pNpc, dt) end
      for _, fNpc in pairs(netFollowers) do updateNpcMovement(fNpc, dt) end

      processGlobalThreadMessages(curGame)

      local p = self.player
      if p and self.map and netOutChannel then
        local now = (_G.love and _G.love.timer and _G.love.timer.getTime) and _G.love.timer.getTime() or os.time()
        local positionChanged = (p.cellX ~= lastPlayerX) or (p.cellY ~= lastPlayerY) or (self.map.id ~= lastPlayerMap)

        if positionChanged or (now - lastSendTime >= 0.10) then
          lastSendTime = now
          lastPlayerX = p.cellX
          lastPlayerY = p.cellY
          lastPlayerMap = self.map.id

          if curGame.save and curGame.save.player then
            curGame.save.player.map = self.map.id
            curGame.save.player.x = p.cellX
            curGame.save.player.y = p.cellY
            curGame.save.player.facing = p.facing
          end
          if curGame.save and curGame.save.position then
            curGame.save.position.map = self.map.id
            curGame.save.position.x = p.cellX
            curGame.save.position.y = p.cellY
            curGame.save.position.facing = p.facing
          end

          local trainerId, trainerName = getTrainerInfo(curGame.save)
          local followerSpecies = curGame.save and curGame.save.party and curGame.save.party[1] and curGame.save.party[1].species
          local delta = Collision.DELTA[p.facing] or { 0, 1 }
          local fx = p.cellX - delta[1]
          local fy = p.cellY - delta[2]

          local payload = {
            action = "sync_pos",
            modVersion = MOD_VERSION,
            version = MOD_VERSION,
            gameVersion = select(1, getClientVersionInfo()),
            recompVersion = select(2, getClientVersionInfo()),
            trainerId = trainerId,
            sessionId = clientSessionId,
            name = trainerName,
            spriteId = localSelectedSprite,
            title = localTrainerTitle,
            level = mmoLevel,
            map = self.map.id,
            x = p.cellX,
            y = p.cellY,
            px = p.px,
            py = p.py,
            fx = fx,
            fy = fy,
            facing = p.facing,
            moving = p.moving,
            species = followerSpecies
          }

          netOutChannel:push({
            url = GTS_SERVER_URL .. "/gts",
            body = Json.encode(payload)
          })
        end
      end
    end

    -- 4. Gen 2 Overworld Interaction Hook (A-button on remote players)
    local origGen2Interact = Gen2World.interact
    Gen2World.interact = function(self)
      if isWaitingForChallenge then return end
      local curGame = self.game or Game
      local p1 = self.player
      if not p1 then return origGen2Interact and origGen2Interact(self) end
      local d = Collision.DELTA[p1.facing] or { 0, 1 }
      local fx, fy = p1.cellX + d[1], p1.cellY + d[2]

      for tid, pNpc in pairs(netNpcs) do
        if pNpc.cellX == fx and pNpc.cellY == fy then
          local rawData = netPlayerMap[tid] or {}
          local pName = rawData.name or "TRAINER"
          local targetTid = pNpc.trainerId or tid

          local items = {
            {
              label = "VIEW TRAINER CARD",
              onSelect = function()
                openTrainerCardScreen(curGame, targetTid, rawData)
              end
            },
            {
              label = "PVP 1V1 SINGLES",
              onSelect = function()
                if not curGame.save or not curGame.save.party or #curGame.save.party == 0 then
                  curGame.stack:push(TextBox.new(curGame, wrapText("YOU NEED AT LEAST 1 POKéMON IN YOUR PARTY TO BATTLE!")))
                  return
                end
                local myId, myName = getTrainerInfo(curGame.save)
                local myPackedParty = Protocol.packParty(curGame.save.party)
                local linkSeed = math.random(1, 2^30)
                local roomId = "BATTLE_"
                  .. tostring(math.min(tonumber(myId) or 0, tonumber(targetTid) or 0))
                  .. "_"
                  .. tostring(math.max(tonumber(myId) or 0, tonumber(targetTid) or 0))
                  .. "_" .. tostring(linkSeed)

                isWaitingForChallenge = true
                challengeWaitTimer = 0

                gtsApiPost({
                  action = "send_challenge",
                  targetId = targetTid,
                  fromId = myId,
                  fromName = myName,
                  challengeType = "PVP",
                  party = myPackedParty,
                  seed = linkSeed,
                  roomId = roomId
                }, 1.5)
                curGame.stack:push(TextBox.new(curGame, string.format("WAITING FOR %s\nTO ACCEPT 1V1 PVP...", pName)))
              end
            },
            {
              label = "PVP 2V2 DOUBLES",
              onSelect = function()
                if not curGame.save or not curGame.save.party or #curGame.save.party == 0 then
                  curGame.stack:push(TextBox.new(curGame, wrapText("YOU NEED AT LEAST 1 POKéMON IN YOUR PARTY TO BATTLE!")))
                  return
                end
                local myId, myName = getTrainerInfo(curGame.save)
                local myPackedParty = Protocol.packParty(curGame.save.party)
                local linkSeed = math.random(1, 2^30)
                local roomId = "BATTLE_DBL_"
                  .. tostring(math.min(tonumber(myId) or 0, tonumber(targetTid) or 0))
                  .. "_"
                  .. tostring(math.max(tonumber(myId) or 0, tonumber(targetTid) or 0))
                  .. "_" .. tostring(linkSeed)

                isWaitingForChallenge = true
                challengeWaitTimer = 0

                gtsApiPost({
                  action = "send_challenge",
                  targetId = targetTid,
                  fromId = myId,
                  fromName = myName,
                  challengeType = "PVP_DOUBLES",
                  party = myPackedParty,
                  seed = linkSeed,
                  roomId = roomId
                }, 1.5)
                curGame.stack:push(TextBox.new(curGame, string.format("WAITING FOR %s\nTO ACCEPT 2V2 DOUBLES...", pName)))
              end
            },
            {
              label = "LINK TRADE",
              onSelect = function()
                if not curGame.save or not curGame.save.party or #curGame.save.party == 0 then
                  curGame.stack:push(TextBox.new(curGame, wrapText("YOU NEED AT LEAST 1 POKéMON IN YOUR PARTY TO TRADE!")))
                  return
                end
                local myId, myName = getTrainerInfo(curGame.save)
                local roomId = "TRADE_"
                  .. tostring(math.min(tonumber(myId) or 0, tonumber(targetTid) or 0))
                  .. "_"
                  .. tostring(math.max(tonumber(myId) or 0, tonumber(targetTid) or 0))
                  .. "_" .. tostring(math.random(1, 2^30))

                isWaitingForChallenge = true
                challengeWaitTimer = 0

                gtsApiPost({
                  action = "send_challenge",
                  targetId = targetTid,
                  fromId = myId,
                  fromName = myName,
                  challengeType = "TRADE",
                  roomId = roomId
                }, 1.5)
                curGame.stack:push(TextBox.new(curGame, wrapText(string.format("WAITING FOR %s TO ACCEPT TRADE...", pName))))
              end
            },
            { label = "CANCEL", onSelect = function() end }
          }
          curGame.stack:push(Menu.new(curGame, items, { tx = 1, ty = 1, tw = 16, th = 8 }))
          return
        end
      end
      return origGen2Interact and origGen2Interact(self)
    end
  end

  -- Wrap Game.update to continuously service active GtsNetAdapter during battle
  mod.hooks:wrap("core.game.update", function(nextFn, game, dt)
    if nextFn then nextFn(game, dt) end

    -- Continuous frame service for background thread battle messages
    processGlobalThreadMessages(game)

    -- KEEPALIVE POSITION BROADCAST:
    -- StateStack:update() only calls update() on the TOP of the state stack.
    -- OverworldState.update (where sync_pos normally fires every movement /
    -- 100ms) therefore does NOT run at all while any Menu, TextBox, or other
    -- screen is on top -- e.g. sitting in the CO-OP ONLINE menu, browsing the
    -- GTS, or reading a confirmation textbox. The server purges anyone whose
    -- sync_pos goes quiet for 30+ seconds (PLAYER_TIMEOUT_SECONDS in
    -- gts_server.py), so a player who lingers in a menu vanishes from
    -- everyone else's player list even though they're still fully connected.
    -- This hook runs unconditionally every frame regardless of what's on top
    -- of the stack, so it keeps a low-rate position ping alive whenever the
    -- normal overworld-driven sync isn't running.
    local gWorld = getWorld(game)
    if isGtsServerConnected and not isWaitingForChallenge and gWorld
       and gWorld.player and gWorld.map and netOutChannel then
      local ow = gWorld
      local p = ow.player
      local now = (_G.love and _G.love.timer and _G.love.timer.getTime) and _G.love.timer.getTime() or os.time()
      if now - lastSendTime >= 0.10 then
        lastSendTime = now
        lastPlayerX = p.cellX
        lastPlayerY = p.cellY
        lastPlayerMap = ow.map.id

        local trainerId, trainerName = getTrainerInfo(game.save)
        local followerSpecies = game.save.party and game.save.party[1] and game.save.party[1].species
        local delta = Collision.DELTA[p.facing] or { 0, 1 }

        netOutChannel:push({
          url = GTS_SERVER_URL .. "/gts",
          body = Json.encode({
            action = "sync_pos",
            trainerId = trainerId,
            name = trainerName,
            title = localTrainerTitle,
            map = ow.map.id,
            x = p.cellX,
            y = p.cellY,
            px = p.px,
            py = p.py,
            fx = p.cellX - delta[1],
            fy = p.cellY - delta[2],
            facing = p.facing,
            moving = false,
            species = followerSpecies
          })
        })
      end
    end

    -- Hook Catch XP reward & Analytics Stat reporting
    if Party and Party.add and not Party._mmoHooked then
      Party._mmoHooked = true
      local origPartyAdd = Party.add
      Party.add = function(party, mon)
        local res = origPartyAdd(party, mon)
        if res and Game then
          addMmoXp(Game, "catch")
          local tid = getTrainerId and getTrainerId(Game.save) or "100001"
          local sp = mon and mon.species
          gtsApiPost({ action = "report_battle_stat", trainerId = tid, battleType = "wild", species = sp, caught = true })
        end
        return res
      end
    end

    -- Hook Wild / Trainer Battle XP reward & Analytics Stat reporting (Single Authoritative Hook)
    if BattleState and BattleState.finish and not BattleState._mmoHooked then
      BattleState._mmoHooked = true
      local origBattleFinish = BattleState.finish
      BattleState.finish = function(self)
        if self.result == "win" and Game then
          local tid = getTrainerId and getTrainerId(Game.save) or "100001"
          local isTrainer = (self.kind == "trainer" or self.trainer ~= nil or self.oppClass ~= nil)
          if isTrainer then
            addMmoXp(Game, "trainer_battle")
            gtsApiPost({ action = "report_battle_stat", trainerId = tid, battleType = "npc" })
            if self.oppClass == "OPP_ROUTE2_DAN" or self.oppClass == "OPP_ROUTE2_DAVE" or (self.__dbSideB and self.__dbSideB.trainer and self.__dbSideB.trainer.id == "OPP_ROUTE2_DAVE") then
              if Game.save then Game.save.route2BrothersDefeated = true end
            end
          else
            addMmoXp(Game, "wild_battle")
            local species = self.enemy and self.enemy.mon and self.enemy.mon.species
            gtsApiPost({ action = "report_battle_stat", trainerId = tid, battleType = "wild", species = species })
          end
          performForcedSave(Game)
          syncLocalProfile(Game, 0)
        end
        if origBattleFinish then origBattleFinish(self) end
      end
    end

    -- Optional: print any debug messages from the thread
    printThreadDebug()
  end)
  end


  local function loadLocal(mod, relative)
    local source = assert(mod:read(relative), "missing " .. relative)
    local chunk, err = load(source, "@" .. mod.path .. "/" .. relative)
    assert(chunk, err)
    return chunk()
  end

  do
    local paths = {
      blackjack = "games/blackjack/", holdem = "games/holdem/",
      crash = "games/crash/", tube = "games/tube_flyer/",
      case = "games/prize_case/",
    }
    local Rules = loadLocal(mod, paths.blackjack .. "rules.lua")
    local BlackjackView = loadLocal(mod, paths.blackjack .. "view.lua")
    local HoldemRules = loadLocal(mod, paths.holdem .. "rules.lua")
    local HoldemView = loadLocal(mod, paths.holdem .. "view.lua")
    local CrashRules = loadLocal(mod, paths.crash .. "rules.lua")
    local FlappyRules = loadLocal(mod, paths.tube .. "rules.lua")
    local CaseRules = loadLocal(mod, paths.case .. "rules.lua")
    local ArcadeUI = loadLocal(mod, "games/shared/ui.lua")
    local CrashView = loadLocal(mod, paths.crash .. "view.lua")(ArcadeUI)
    local TubeView = loadLocal(mod, paths.tube .. "view.lua")(ArcadeUI)
    local CaseView = loadLocal(mod, paths.case .. "view.lua")(ArcadeUI)
    local Catalog = loadLocal(mod, "other/prizes/catalog.lua")
    local Pawn = loadLocal(mod, "other/pawn/rules.lua")
    local Services = loadLocal(mod, "other/services.lua")
    local UIFactory = loadLocal(mod, "other/ui.lua")
    local CoinCase = loadLocal(mod, "other/coin_case.lua")
    local Lounge = loadLocal(mod, "other/lounge.lua")
    local Stats = require("src.pokemon.Stats")
    local Sound = require("src.core.Sound")

    local ids = {
      blackjack = "BlackjackCornerTable",
      holdem = "BlackjackCornerHoldemTable",
      pokemon = "BlackjackCornerPokemonPrizes",
      item = "BlackjackCornerItemPrizes",
      crash = "BlackjackCornerCrash",
      tube = "BlackjackCornerTubeFlyer",
      case = "BlackjackCornerPrizeCase",
      lounge = "BLACKJACK_LOUNGE",
    }
    local config = {
      coinCap = 1000000,
      coinBundle = 50,
      coinBundlePrice = 1000,
      masterBallKey = "master_ball_redeemed",
      pawnLedgerKey = "pawned_pokemon",
    }
    local blackjackBets, holdemBets = { 10, 50, 100, 500 }, { 10, 50, 100, 500 }

    mod.options:define({
      { key = "shiny_sparkles", label = "SHINY SPARKLES", type = "toggle", default = true },
    })
    mod.content.constants:patch("coinCap", config.coinCap)
    CoinCase.installSlotCompatibility(config.coinCap)
    CoinCase.installHiddenCoinCompatibility(config.coinCap)

    local Service = Services(mod, Catalog, Pawn, config)
    local UI = UIFactory(mod, Service, Catalog, Pawn, config)
    local function playSound(game, name) Sound.play(game.data, name) end
    local common = {
      mod = mod, coins = Service.coins, coinCap = config.coinCap,
      close = UI.close, play = playSound,
    }
    local function context(extra)
      local out = {}
      for key, value in pairs(common) do out[key] = value end
      for key, value in pairs(extra) do out[key] = value end
      return out
    end

    local Blackjack = loadLocal(mod, paths.blackjack .. "screen.lua")(context({
      rules = Rules, view = BlackjackView, bets = blackjackBets,
    }))
    local Holdem = loadLocal(mod, paths.holdem .. "screen.lua")(context({
      rules = HoldemRules, view = HoldemView, cardView = BlackjackView,
      bets = holdemBets,
      gtsApiGet = function(path, to) return gtsApiGet(path, to) end,
      gtsApiPost = function(payload, to) return gtsApiPost(payload, to) end,
      getTrainerInfo = function(save) return getTrainerInfo(save) end,
      isServerConnected = function() return isGtsServerConnected end,
    }))
    local Crash = loadLocal(mod, paths.crash .. "screen.lua")(context({
      rules = CrashRules, view = CrashView,
    }))
    local TubeFlyer = loadLocal(mod, paths.tube .. "screen.lua")(context({
      rules = FlappyRules, view = TubeView,
    }))
    local PrizeCase = loadLocal(mod, paths.case .. "screen.lua")(context({
      rules = CaseRules, view = CaseView,
      rewardPool = function(game) return Service.caseRewardPool(game, CaseRules) end,
      giveReward = Service.giveCaseReward,
    }))

    for screen, class in pairs({
      [ids.blackjack] = Blackjack, [ids.holdem] = Holdem,
      [ids.crash] = Crash, [ids.tube] = TubeFlyer, [ids.case] = PrizeCase,
    }) do mod.content.screens:register(screen, { new = class.new }) end
    mod.content.screens:register(ids.pokemon, { new = UI.pokemonMenu })
    mod.content.screens:register(ids.item, { new = UI.itemMenu })

    local function getDerivedPath(subpath)
      local p1 = "save/mod-derived/" .. tostring(mod.id or "gen1online-gamecorner") .. "/" .. subpath
      local p2 = "save/mod-derived/blackjack_corner/" .. subpath
      local p3 = "save/mod-derived/gen1online-gamecorner/" .. subpath
      if love and love.filesystem and love.filesystem.getInfo then
        if love.filesystem.getInfo(p1) then return p1 end
        if love.filesystem.getInfo(p2) then return p2 end
        if love.filesystem.getInfo(p3) then return p3 end
      end
      return p1
    end

    for _, tableDef in ipairs({
      { id = "BLACKJACK", file = "blackjack" },
      { id = "HOLDEM", file = "holdem" },
    }) do
      for piece = 1, 8 do
        local sub = string.format("world/%s_table_%02d.png", tableDef.file, piece)
        mod.content.sprites:register(("SPRITE_%s_TABLE_%02d"):format(tableDef.id, piece), {
          image = getDerivedPath(sub), frames = 1, trueColor = true,
        })
      end
    end
    for _, machine in ipairs({ "crash", "flappy", "case" }) do
      for piece = 1, 2 do
        local sub = string.format("world/%s_machine_%02d.png", machine, piece)
        mod.content.sprites:register(("SPRITE_ARCADE_%s_%02d")
          :format(machine:upper(), piece), {
            image = getDerivedPath(sub), frames = 1, trueColor = true,
          })
      end
    end
    Lounge.register(mod, ids.lounge)

    mod.content.map_scripts:register("GAME_CORNER", { talk = {
      TEXT_GAMECORNER_CLERK1 = UI.coinClerk,
      TEXT_GAMECORNER_CLERK = UI.coinClerk,
      TEXT_PAWN_BROKER = UI.pawnBroker,
      TEXT_BLACKJACK_LOUNGE_SIGN = function(game, _, _, done)
        UI.text(game, "CASINO LOUNGE\nTables & Online Poker!", done)
      end,
    } })

    local function openCasino(game, message, screen, done)
      UI.openAfterMessage(game, message, screen, done)
    end
    mod.content.map_scripts:register(ids.lounge, { talk = {
      TEXT_BLACKJACK_TABLE = function(game, _, _, done)
        openCasino(game, "Welcome to the\nBLACKJACK table!\fPlace your bet and\nplay to 21.",
          ids.blackjack, done)
      end,
      TEXT_BLACKJACK_DEALER = function(game, _, _, done)
        openCasino(game, "The table is open.\fClosest to 21\nwins the hand.", ids.blackjack, done)
      end,
      TEXT_HOLDEM_TABLE = function(game, _, _, done)
        openCasino(game, "TEXAS HOLD'EM!\fSolo Practice or\nOnline Multiplayer!\fBet or CHECK on\neach round.",
          ids.holdem, done)
      end,
      TEXT_HOLDEM_DEALER = function(game, _, _, done)
        openCasino(game, "Bet before FLOP,\nafter FLOP,\fand at RIVER.\fBest five-card hand\nwins.",
          ids.holdem, done)
      end,
      TEXT_CASINO_HOSTESS = function(game, _, _, done)
        local count = (game.save and game.save.coins) or 0
        UI.text(game, string.format("Welcome to the\nCasino Lounge!\fYou currently have\n%d coins.", count), done)
      end,
      TEXT_BLACKJACK_PATRON = function(game, _, _, done)
        UI.text(game, "I hit on 16 and\ngot a 5!\fBlackjack is thrilling!", done)
      end,
      TEXT_HOLDEM_PATRON = function(game, _, _, done)
        UI.text(game, "Online Texas Hold'em\nis intense!\fCan you bluff against\nother trainers?", done)
      end,
      TEXT_CRASH_MACHINE = function(game, _, _, done)
        openCasino(game, "CRASH MULTIPLIER!\fCash out before it\ncrashes!", ids.crash, done)
      end,
      TEXT_FLAPPY_MACHINE = function(game, _, _, done)
        openCasino(game, "TUBE FLYER!\fTap A to flap and\ndodge obstacles!", ids.tube, done)
      end,
      TEXT_CASE_MACHINE = function(game, _, _, done)
        openCasino(game, "PRIZE CASE!\fSpin for rare items\nand Pokemon!", ids.case, done)
      end,
    } })
  end

  print("[Gen1Online] Asynchronous Threaded 60FPS MMO Mod initialized successfully.")
end