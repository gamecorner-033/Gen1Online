-- zip test2

  local currentMod = nil
  print("[Gen1Online] Initializing Gen1Online Asynchronous Threaded 60FPS MMO Mod...")

  local function loadLocal(mod, relative)
    local source = nil
    if mod and mod.read then
      pcall(function() source = mod:read(relative) end)
    end
    if not source then
      print("[Gen1Online] Warning: Could not read " .. tostring(relative))
      return function() return {} end
    end
    local loadFn = loadstring or load
    local chunk, err = loadFn(source, "@" .. (mod.path or "mod") .. "/" .. tostring(relative))
    if not chunk then
      print("[Gen1Online] Warning: Failed to parse " .. tostring(relative) .. ": " .. tostring(err))
      return function() return {} end
    end
    local ok, res = pcall(chunk)
    if not ok then
      print("[Gen1Online] Warning: Error executing " .. tostring(relative) .. ": " .. tostring(res))
      return function() return {} end
    end
    if type(res) == "function" then
      return res
    end
    return function() return type(res) == "table" and res or {} end
  end

  -- Quests/NPCs are loaded from their modules later in the factory (see the
  -- module-loading section near the bottom); the empty defaults keep the
  -- overworld hooks from nil-calling anything if a module fails to load.
  local Quests = {}
  local NPCs = {}

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

  -- GTS Server URL: read from gts_config.txt next to main.lua (per-device,
  -- edit without rebuilding). Falls back to a storage value, then the default
  -- local server on port 7779 (0.1ms ping).
  local DEFAULT_SERVER_URL = "http://127.0.0.1:7779"
  local GTS_SERVER_URL = DEFAULT_SERVER_URL
  local function readServerUrlFromConfig()
    local f = _G.love and _G.love.filesystem
    if not (f and f.read) then return nil end
    local candidates = {
      "gts_config.txt",
      "mods/gen1online-gamecorner/gts_config.txt",
    }
    for _, path in ipairs(candidates) do
      local ok, content = pcall(f.read, path)
      if ok and content and #content > 0 then
        for line in tostring(content):gmatch("[^\r\n]+") do
          local key, val = line:match("^%s*([^#=%s]+)%s*=%s*(.-)%s*$")
          if key and val and key:lower() == "server_url" and #val > 0 then
            return val
          end
        end
      end
    end
    return nil
  end
  local function loadServerUrl()
    local fromFile = readServerUrlFromConfig()
    local stored = storageRead and storageRead("gts_server_url")
    if fromFile then
      GTS_SERVER_URL = fromFile
    elseif stored and type(stored) == "string" and #stored > 0 then
      GTS_SERVER_URL = stored
    else
      GTS_SERVER_URL = DEFAULT_SERVER_URL
    end
    _G.GTS_SERVER_URL = GTS_SERVER_URL
    return GTS_SERVER_URL
  end
  local function getServerUrl()
    return GTS_SERVER_URL
  end
  local isGtsServerConnected = false -- Explicit manual connection required via menu

  -- Universal Overworld / World accessor for Gen 1 (overworld) and Gen 2 (world)
  local function getWorld(g)
    g = g or Game
    if not g then return nil end
    return g.world or g.overworld
  end

  -- Networking State
  local netSession = nil
  local isHost = false
  local roomCode = nil
  local lastSendTime = 0
  local lastPlayerX = nil
  local lastPlayerY = nil
  local lastPlayerMap = nil
  local lastPlayerMoving = false
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
  local clientSessionId = string.format("%08x%08x", math.random(10000000, 99999999), os.time())

  -- MMO Multi-Player NPC Registry (trainerId -> NPC object)
  local netNpcs = {}       -- trainerId -> human NPC object
  local netFollowers = {}  -- trainerId -> follower NPC object
  local netPlayerMap = {}  -- trainerId -> player raw position data
  local gtsSpriteDiagWritten = false  -- write remote-sprite diagnostic once

  -- Custom Trainer Profile State & MMO Leveling Engine (1 to 100)
  local localTrainerTitle = "ACE TRAINER"
  local localFavoriteMon = "CHARIZARD"
  local mmoLevel = 1
  local mmoXp = 0
  local mmoToken = nil
  local localSelectedSprite = isGen2 and "SPRITE_CHRIS" or "SPRITE_RED"

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
    { id = "SPRITE_CHRIS", label = "GOLD / PROTAGONIST" },
    { id = "SPRITE_RIVAL", label = "SILVER / RIVAL" },
    { id = "SPRITE_RED", label = "RED" },
    { id = "SPRITE_BLUE", label = "BLUE" },
    { id = "SPRITE_FALKNER", label = "FALKNER" },
    { id = "SPRITE_BUGSY", label = "BUGSY" },
    { id = "SPRITE_WHITNEY", label = "WHITNEY" },
    { id = "SPRITE_MORTY", label = "MORTY" },
    { id = "SPRITE_JASMINE", label = "JASMINE" },
    { id = "SPRITE_CHUCK", label = "CHUCK" },
    { id = "SPRITE_PRYCE", label = "PRYCE" },
    { id = "SPRITE_CLAIR", label = "CLAIR" },
    { id = "SPRITE_LANCE", label = "LANCE" },
    { id = "SPRITE_BROCK", label = "BROCK" },
    { id = "SPRITE_MISTY", label = "MISTY" },
    { id = "SPRITE_ERIKA", label = "ERIKA" },
    { id = "SPRITE_JANINE", label = "JANINE" },
    { id = "SPRITE_SABRINA", label = "SABRINA" },
    { id = "SPRITE_COOLTRAINER_M", label = "COOLTRAINER M" },
    { id = "SPRITE_COOLTRAINER_F", label = "COOLTRAINER F" },
    { id = "SPRITE_BUG_CATCHER", label = "BUG CATCHER" },
    { id = "SPRITE_LASS", label = "LASS" },
    { id = "SPRITE_YOUNGSTER", label = "YOUNGSTER" },
    { id = "SPRITE_BEAUTY", label = "BEAUTY" },
    { id = "SPRITE_SUPER_NERD", label = "SUPER NERD" },
    { id = "SPRITE_ROCKER", label = "ROCKER" },
    { id = "SPRITE_POKEFAN_M", label = "POKEFAN M" },
    { id = "SPRITE_POKEFAN_F", label = "POKEFAN F" },
    { id = "SPRITE_KIMONO_GIRL", label = "KIMONO GIRL" },
    { id = "SPRITE_SAGE", label = "SAGE" },
    { id = "SPRITE_GENTLEMAN", label = "GENTLEMAN" },
    { id = "SPRITE_BLACK_BELT", label = "BLACK BELT" },
    { id = "SPRITE_OFFICER", label = "OFFICER" },
    { id = "SPRITE_SAILOR", label = "SAILOR" },
    { id = "SPRITE_BIKER", label = "BIKER" },
    { id = "SPRITE_ROCKET", label = "TEAM ROCKET" },
    { id = "SPRITE_ROCKET_GIRL", label = "ROCKET GIRL" },
    { id = "SPRITE_OAK", label = "PROF. OAK" },
    { id = "SPRITE_ELM", label = "PROF. ELM" }
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

  local function newQueue()
    local q = {}
    return {
      push = function(self, val) table.insert(q, val) end,
      pop = function(self) return table.remove(q, 1) end,
      peek = function(self) return q[1] end,
      getCount = function(self) return #q end,
      clear = function(self) q = {} end
    }
  end

  local netOutChannel = newQueue()
  local netInChannel = newQueue()

  -- Remote NPC count logging timer
  local remoteCountLogTime = 0

  -- Transport diagnostics: records the outcome of every request attempt so a
  -- failing call can report exactly which transport died and why.
  local netDiag = { url = "", method = "", timeout = 0, attempts = {} }
  local function netDiagReset(url, method, timeout)
    netDiag.url = url or ""
    netDiag.method = method or ""
    netDiag.timeout = timeout or 0
    netDiag.attempts = {}
  end
  local function netDiagAdd(which, outcome)
    netDiag.attempts[#netDiag.attempts + 1] = which .. ": " .. outcome
  end
  local function netDiagReport()
    if #netDiag.attempts == 0 then return "NETWORK_ERROR" end
    local lines = { "NETWORK_ERROR" }
    local u = netDiag.url
    if #u > 50 then u = u:sub(1, 47) .. "..." end
    lines[#lines + 1] = "URL: " .. u
    lines[#lines + 1] = string.format("REQ: %s TIMEOUT %gs", netDiag.method, netDiag.timeout)
    for i = 1, math.min(#netDiag.attempts, 4) do
      lines[#lines + 1] = netDiag.attempts[i]
    end
    return table.concat(lines, "\n")
  end

  -- Universal Transport Helper (Supports direct HTTPS via LuaSec, socket.http, and pure luasocket TCP)
  local function makeHttpRequest(reqTable)
    reqTable.timeout = reqTable.timeout or 8.0
    local isHttps = (reqTable.url:sub(1, 5) == "https")
    netDiagReset(reqTable.url, reqTable.method, reqTable.timeout)

    -- If https requested but no SSL module present in the sandbox, rewrite to http so socket.http / pure socket TCP succeed
    if isHttps then
      local okHttps, httpsMod = pcall(require, "ssl.https")
      local okSsl, ssl = pcall(require, "ssl")
      if not (okHttps and httpsMod) and not (okSsl and ssl and ssl.wrap) then
        reqTable.url = reqTable.url:gsub("^https://", "http://")
        isHttps = false
      end
    end

    -- 1. Try ssl.https if https
    if isHttps then
      local okHttps, httpsMod = pcall(require, "ssl.https")
      if okHttps and httpsMod then
        local ok, res, code, headers, status = pcall(httpsMod.request, reqTable)
        if ok and code and code >= 200 and code < 400 then
          netDiagAdd("ssl.https", "OK code=" .. tostring(code))
          return ok, res, code, headers, status
        end
        if not ok then
          netDiagAdd("ssl.https", "THREW: " .. tostring(res))
        elseif not code then
          netDiagAdd("ssl.https", "FAIL: " .. tostring(status or res))
        else
          netDiagAdd("ssl.https", "code=" .. tostring(code))
        end
      else
        netDiagAdd("ssl.https", "unavailable")
      end
    end

    -- 2. Try socket.http
    local okHttp, httpMod = pcall(require, "socket.http")
    if okHttp and httpMod then
      local ok, res, code, headers, status = pcall(httpMod.request, reqTable)
      code = tonumber(code)
      if ok and code and code >= 200 and code < 400 then
        netDiagAdd("socket.http", "OK code=" .. tostring(code))
        return ok, res, code, headers, status
      end
      if not ok then
        netDiagAdd("socket.http", "THREW: " .. tostring(res))
      elseif not code then
        netDiagAdd("socket.http", "FAIL: " .. tostring(status or res))
      else
        netDiagAdd("socket.http", "code=" .. tostring(code))
      end
    else
      netDiagAdd("socket.http", "unavailable")
    end

    -- 3. Pure luasocket TCP client (Permitted by Sandbox with network permission)
    local okSocket, socket = pcall(require, "socket")
    if okSocket and socket and socket.tcp then
      local host, port, path = reqTable.url:match("^https?://([^/:]+):?(%d*)(/?.*)")
      if host then
        port = tonumber(port) or (isHttps and 443 or 80)
        if path == "" then path = "/" end
        local tcp = socket.tcp()
        tcp:settimeout(reqTable.timeout or 8.0)
        local connOk, connErr = tcp:connect(host, port)
        if connOk then
          local hsOk = true
          if isHttps then
            local okSsl, ssl = pcall(require, "ssl")
            if okSsl and ssl and ssl.wrap then
              local params = { mode = "client", protocol = "any", verify = "none" }
              tcp = ssl.wrap(tcp, params)
              if tcp then hsOk = pcall(tcp.dohandshake, tcp) end
            end
          end
          if not hsOk then
            netDiagAdd("raw-tcp", "TLS handshake failed")
            pcall(tcp.close, tcp)
          else
            local bodyStr = ""
            if reqTable.source and type(reqTable.source) == "function" then
              local chunk = reqTable.source()
              while chunk do
                bodyStr = bodyStr .. tostring(chunk)
                chunk = reqTable.source()
              end
            end

            local reqHeader = string.format("%s %s HTTP/1.1\r\nHost: %s\r\nUser-Agent: LuaSocket 2.0.2\r\nConnection: close\r\nContent-Type: application/json\r\nContent-Length: %d\r\nX-Mod-Version: %s\r\n\r\n%s",
              reqTable.method or (bodyStr ~= "" and "POST" or "GET"),
              path, host, #bodyStr, MOD_VERSION, bodyStr)

            pcall(tcp.send, tcp, reqHeader)
            local respData = {}
            while true do
              local line, err, partial = tcp:receive(4096)
              if line then table.insert(respData, line)
              elseif partial and #partial > 0 then table.insert(respData, partial) end
              if err then break end
            end
            pcall(tcp.close, tcp)

            local fullResp = table.concat(respData)
            local bodyStart = fullResp:find("\r\n\r\n") or fullResp:find("\n\n")
            if bodyStart then
              local realCode = tonumber(fullResp:match("^HTTP/%d%.%d%s+(%d+)")) or 200
              local bodyOnly = fullResp:sub(bodyStart + 4)
              if reqTable.sink and type(reqTable.sink) == "function" then
                reqTable.sink(bodyOnly)
              end
              netDiagAdd("raw-tcp", "code=" .. tostring(realCode) .. " bytes=" .. tostring(#bodyOnly))
              return true, 1, realCode, {}, "OK"
            end
            netDiagAdd("raw-tcp", "conn ok but no HTTP body")
          end
        else
          netDiagAdd("raw-tcp", "connect FAIL: " .. tostring(connErr))
        end
      else
        netDiagAdd("raw-tcp", "bad URL")
      end
    else
      netDiagAdd("raw-tcp", "socket unavailable")
    end

    -- 4. Fallback to local server http://127.0.0.1:7779 if remote failed
    if isHttps and okSocket and socket and socket.tcp then
      local tcp = socket.tcp()
      tcp:settimeout(reqTable.timeout or 8.0)
      if tcp:connect("127.0.0.1", 7779) then
        local bodyStr = ""
        if reqTable.source and type(reqTable.source) == "function" then
          local chunk = reqTable.source()
          while chunk do bodyStr = bodyStr .. tostring(chunk); chunk = reqTable.source() end
        end
        local path = reqTable.url:match("^https?://[^/]+(/?.*)") or "/gts"
        local reqHeader = string.format("%s %s HTTP/1.1\r\nHost: 127.0.0.1:7779\r\nConnection: close\r\nContent-Type: application/json\r\nContent-Length: %d\r\nX-Mod-Version: %s\r\n\r\n%s",
          reqTable.method or "POST", path, #bodyStr, MOD_VERSION, bodyStr)
        pcall(tcp.send, tcp, reqHeader)
        local respData = {}
        while true do
          local line, err, partial = tcp:receive(4096)
          if line then table.insert(respData, line)
          elseif partial and #partial > 0 then table.insert(respData, partial) end
          if err then break end
        end
        pcall(tcp.close, tcp)
        local fullResp = table.concat(respData)
        local bodyStart = fullResp:find("\r\n\r\n") or fullResp:find("\n\n")
        if bodyStart then
          local bodyOnly = fullResp:sub(bodyStart + 4)
          if reqTable.sink and type(reqTable.sink) == "function" then
            reqTable.sink(bodyOnly)
          end
          netDiagAdd("localhost", "code=200")
          return true, 1, 200, {}, "OK"
        end
      else
        netDiagAdd("localhost", "connect FAIL")
      end
    end

    return false, nil, nil, nil, nil
  end

  local MOD_VERSION = "0.3.6.1"

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
      url = getServerUrl() .. fullPath,
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
      netDiagAdd("decode", "response not JSON (code=" .. tostring(code) .. ")")
    elseif not ok then
      netDiagAdd("http", "request failed (code=" .. tostring(code) .. ")")
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
      url = getServerUrl() .. "/gts",
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
      netDiagAdd("decode", "response not JSON (code=" .. tostring(code) .. ")")
    elseif not ok then
      netDiagAdd("http", "request failed (code=" .. tostring(code) .. ")")
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

  -- Helper to list all Gen 1 PokÃ©mon species sorted alphabetically
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

  -- Battle / trade transport for LinkBattle & LinkState, implemented over the
  -- GTS HTTP room API. There is no background thread in the launcher sandbox,
  -- so send() POSTs the message to the room immediately and update() polls
  -- the room on a short rate limit; both are synchronous main-thread calls
  -- (localhost latency, like every other gtsApiPost in this mod).
  --
  -- Servicing: Game:step calls game.linkNet:update() every frame (Gen 1), and
  -- LinkBattle/LinkState also call net:update()/net:poll() from their own
  -- updates, so poll() is driven even while a menu sits on top of the battle.
  local GtsNetAdapter = {}
  GtsNetAdapter.__index = GtsNetAdapter

  local BATTLE_POLL_INTERVAL = 0.15

  function GtsNetAdapter.new(myId, targetId, roomId)
    local self = setmetatable({}, GtsNetAdapter)
    self.myId = tostring(myId)
    self.targetId = tostring(targetId)
    self.roomId = roomId or ("ROOM_" .. self.myId .. "_" .. self.targetId)
    self.inbox = {}
    self.closed = false
    self.paired = true   -- already paired when the battle/trade starts
    self.error = nil
    self.lastPollAt = -math.huge
    activeBattleAdapter = self
    return self
  end

  function GtsNetAdapter:send(msg)
    -- Suppress 'bye' messages: LinkBattle.finish sends {type="bye"} AFTER our
    -- battle.finish wrapper has already called clear_battle_room. Forwarding
    -- it would drop it into the just-cleared room queue and poison the
    -- opponent's NEXT battle with an instant "other player left" loop. Room
    -- cleanup is done server-side by clear_battle_room, so bye is dropped.
    if msg and msg.type == "bye" then return end

    gtsApiPost({
      action = "send_battle_msg",
      roomId = self.roomId,
      targetId = self.targetId,
      msg = msg
    }, 1.5)
  end

  function GtsNetAdapter:update()
    if self.closed then return end
    local now = (_G.love and _G.love.timer and _G.love.timer.getTime)
                  and _G.love.timer.getTime() or os.time()
    if now - self.lastPollAt < BATTLE_POLL_INTERVAL then return end
    self.lastPollAt = now
    local res = gtsApiPost({
      action = "poll_battle_msgs",
      roomId = self.roomId,
      myId = self.myId
    }, 1.5)
    if res and res.msgs then
      for _, m in ipairs(res.msgs) do
        table.insert(self.inbox, m)
      end
    end
  end

  function GtsNetAdapter:poll()
    local out = self.inbox
    self.inbox = {}
    return out
  end

  -- Session-compatible status surface used by LinkState:update (src/link/
  -- Session.lua provides the same methods on the vanilla net path).
  function GtsNetAdapter:getStatus()
    if self.closed then return "closed" end
    return "paired"
  end

  function GtsNetAdapter:hasPending()
    return #self.inbox > 0
  end

  function GtsNetAdapter:take(messageType)
    for i, m in ipairs(self.inbox) do
      if m and m.type == messageType then
        return table.remove(self.inbox, i)
      end
    end
    return nil
  end

  function GtsNetAdapter:pollOne()
    if #self.inbox == 0 then return nil end
    return table.remove(self.inbox, 1)
  end

  function GtsNetAdapter:close()
    -- Mark closed and clear the global reference. No "bye" is sent here: the
    -- room is cleared server-side by clear_battle_room in battle.finish, and
    -- a bye would only poison the next battle's fresh room if it raced it.
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
  local openServerUrlMenu = nil
  local openTrainerCardScreen = nil
  local openMmoLevelInfoScreen = nil
  local openMmoChatMenu = nil
  local handleDisconnect = nil
  local handleConnectToServer = nil
  local applyPlayerSprite = nil

  -- ==========================================================================
  -- Non-blocking persistent HTTP/1.1 client for high-frequency sync traffic.
  -- The game loop never blocks on a network round-trip, and a single TLS
  -- connection is kept alive so we avoid re-doing the (expensive) handshake
  -- for every position sync. Requests are handled one at a time for simple,
  -- reliable response framing.
  -- ==========================================================================
  local asyncState = "idle"        -- idle | connect | handshake | send | recv
  local asyncSock = nil            -- tcp (or ssl-wrapped) socket
  local asyncHost = nil
  local asyncPort = nil
  local asyncIsHttps = false
  local asyncWrite = ""            -- request bytes still to send
  local asyncRead = ""             -- raw response bytes accumulated
  local asyncBody = ""             -- current response body
  local asyncBodyLen = -1          -- expected body length (Content-Length)
  local asyncInHeaders = true      -- still parsing response headers
  local asyncPending = {}          -- queue of { url=.., body=.., resp={} }
  local asyncActive = nil          -- request currently being serviced
  local asyncConnectTried = false
  local asyncConnectStart = 0      -- time the current connect attempt began
  local asyncReconnectUntil = 0    -- absolute time after which we retry
  local asyncStallStart = 0        -- time we last made progress (send/recv)
  local asyncSendTimeout = 0       -- armed send stall deadline (unused for now)

  local function asyncParseUrl(url)
    local scheme, host, port = url:match("^(https?)://([^/:]+):?(%d*)")
    if not scheme then return nil end
    port = tonumber(port) or (scheme == "https" and 443 or 80)
    local path = url:match("^https?://[^/]+(/[^?#]*)") or "/"
    return scheme, host, port, path
  end

  local function asyncClose(reason)
    if asyncSock then
      pcall(function() asyncSock:close() end)
    end
    asyncSock = nil
    asyncState = "idle"
    asyncConnectTried = false
    asyncConnectStart = 0
    asyncStallStart = 0
    asyncWrite = ""
    asyncRead = ""
    asyncBody = ""
    asyncBodyLen = -1
    asyncInHeaders = true
    asyncActive = nil
    -- If there's still pending work and we just failed, retry shortly.
    if #asyncPending > 0 then
      asyncReconnectUntil = (_G.love and _G.love.timer and _G.love.timer.getTime) and _G.love.timer.getTime() or os.time()
      asyncReconnectUntil = asyncReconnectUntil + 0.5
    end
    if reason then netDiagAdd("async", "closed: " .. tostring(reason)) end
  end

  local function asyncEnsureHost()
    if not asyncHost or not asyncPort then
      local first = asyncPending[1]
      if first then
        local scheme, host, port = asyncParseUrl(first.url)
        local okSsl, ssl = pcall(require, "ssl")
        if (scheme == "https") and not (okSsl and ssl and ssl.wrap) then
          -- In Love2D runtime without LuaSec SSL: adapt to port 80 HTTP for Cloudflare tunnel/local server
          asyncHost = host
          asyncPort = 80
          asyncIsHttps = false
        else
          asyncHost = host
          asyncPort = port
          asyncIsHttps = (scheme == "https")
        end
      end
    end
    return asyncHost ~= nil
  end



  -- Blocking TLS handshake (runs once per connection, not per request). This is
  -- the exact path makeHttpRequest uses, which provably connects in-game. A
  -- non-blocking handshake (settimeout(0) + dohandshake polling) was tried and
  -- stalls before completing in this runtime, so we keep the reliable blocking
  -- handshake and switch the socket to non-blocking only AFTER it completes.
  local function asyncDoHandshake(tcp)
    local okSsl, ssl = pcall(require, "ssl")
    if not (okSsl and ssl and ssl.wrap) then return nil, "no ssl" end
    local wrapped = ssl.wrap(tcp, { mode = "client", protocol = "any", verify = "none" })
    if not wrapped then return nil, "ssl wrap failed" end
    wrapped:settimeout(8.0)
    local okHs, hsErr = wrapped:dohandshake()
    if not okHs then return nil, "tls handshake failed: " .. tostring(hsErr) end
    wrapped:settimeout(0)
    return wrapped, nil
  end

  -- NON-BLOCKING connect (settimeout 0 + getpeername polling), then a BLOCKING
  -- TLS handshake once the TCP socket is live. After that the socket runs in
  -- non-blocking mode so per-sync send/recv never block the game loop.
  local function asyncStartConnect()
    if not asyncEnsureHost() then asyncClose("bad url"); return end
    -- Diagnostic: a connect during a battle means the persistent connection
    -- dropped, and the blocking handshake below would freeze the PVP lockstep.
    if inBattle then
      pcall(function()
        local f = _G.love and _G.love.filesystem
        if f and f.write then
          f.write("gts_pvp_diag.txt", "async reconnect during battle\n")
        end
      end)
    end
    local okS, socket = pcall(require, "socket")
    if not (okS and socket and socket.tcp) then
      asyncClose("no luasocket"); return
    end
    local tcp = socket.tcp()
    tcp:settimeout(0)
    local cok = tcp:connect(asyncHost, asyncPort)
    local now = (_G.love and _G.love.timer and _G.love.timer.getTime) and _G.love.timer.getTime() or os.time()
    asyncConnectStart = now
    if cok then
      -- Immediate connection: wrap TLS (blocking handshake) then go to send.
      if asyncIsHttps then
        local wrapped, werr = asyncDoHandshake(tcp)
        if not wrapped then asyncClose(werr); return end
        asyncSock = wrapped
      else
        asyncSock = tcp
      end
      asyncConnectTried = false
      asyncState = "send"
    else
      -- Non-blocking connect: poll getpeername in asyncPoll.
      asyncSock = tcp
      asyncConnectTried = true
      asyncState = "connect"
    end
  end

  local asyncLastSuccess = 0       -- time of last successful response delivery
  local asyncLastTry = 0           -- time we last let the async engine attempt
  local asyncLastError = ""        -- most recent async failure reason
  local lastFallbackTime = 0       -- throttle for the synchronous fallback
  local asyncDiagTime = 0          -- throttle for the async diagnostic file

  local function asyncReset(reason)
    asyncLastError = tostring(reason or "")
    asyncClose(reason)
    asyncPending = {}
    asyncActive = nil
  end

  -- Non-blocking socket operations (especially LuaSec TLS with settimeout(0))
  -- return these when there is nothing to do *yet*: the caller should retry on
  -- the next poll, NOT treat it as a connection failure. "closed" and real
  -- errors (refused/reset) are handled separately by the caller.
  local function asyncWouldBlock(err)
    return err == "timeout" or err == "wantread" or err == "wantwrite"
      or err == "wantconnect" or err == "wantaccept" or err == "wantshutdown"
      or err == "wantclientcert" or err == "again" or err == "busy"
  end

  -- Deliver a completed async request: callbacks (battle messages, etc.) get
  -- the decoded body; everything else goes to netInChannel for the normal
  -- sync/challenge drain.
  local function asyncDeliver(req)
    if not req then return false end
    local body = req.resp and table.concat(req.resp)
    if not body or #body == 0 then return false end
    if type(req.callback) == "function" then
      local ok, dec = pcall(Json.decode, body)
      pcall(req.callback, ok and dec or nil, body)
    elseif netInChannel then
      netInChannel:push(body)
    end
    return true
  end

  local function asyncPollInner()
    local now = (_G.love and _G.love.timer and _G.love.timer.getTime) and _G.love.timer.getTime() or os.time()
    -- Keep servicing while there is pending work OR an in-flight request whose
    -- response is still being read. Only go fully idle when both are empty.
    if #asyncPending == 0 and asyncActive == nil and asyncState == "idle" then
      return
    end
    if asyncState == "idle" then
      if asyncSock then
        -- Reuse the open keep-alive connection for the next request (the whole
        -- point of keep-alive: no fresh connect / TLS handshake per sync).
        asyncState = "send"
      elseif now < asyncReconnectUntil then
        return
      else
        asyncStartConnect()
      end
      return
    elseif asyncState == "connect" then
      if not asyncSock then asyncClose("no sock"); return end
      -- Poll for non-blocking connect completion. Generous timeout: a first
      -- TLS connect through the Cloudflare tunnel can take a few seconds.
      if now - asyncConnectStart > 15.0 then
        asyncClose("connect timed out")
        return
      end
      local peer = asyncSock:getpeername()
      if peer then
        if asyncIsHttps then
          local wrapped, werr = asyncDoHandshake(asyncSock)
          if not wrapped then asyncClose(werr); return end
          asyncSock = wrapped
        end
        asyncConnectTried = false
        asyncState = "send"
      else
        local _, err = asyncSock:getpeername()
        if err and err ~= "timeout" and not asyncWouldBlock(err) then
          asyncClose("connect failed: " .. tostring(err))
          return
        end
        return
      end
    end

    if asyncState == "send" then
      if not asyncSock then asyncClose("no sock"); return end
      if asyncWrite == "" then
        -- Pull the next pending request and build its request bytes.
        if not asyncActive then
          asyncActive = table.remove(asyncPending, 1)
        end
        if not asyncActive then asyncState = "idle"; return end
        local scheme, host, port, path = asyncParseUrl(asyncActive.url)
        local bodyStr = asyncActive.body or ""
        local reqHead = string.format(
          "POST %s HTTP/1.1\r\nHost: %s\r\nUser-Agent: LuaSocket 2.0.2\r\nConnection: keep-alive\r\nContent-Type: application/json\r\nContent-Length: %d\r\nX-Mod-Version: %s\r\n\r\n%s",
          path or "/gts", host, #bodyStr, MOD_VERSION, bodyStr)
        asyncWrite = reqHead
        asyncRead = ""
        asyncBody = ""
        asyncBodyLen = -1
        asyncInHeaders = true
        asyncStallStart = now
      end
      local sent, err, partial = asyncSock:send(asyncWrite)
      if sent and sent > 0 then
        asyncWrite = asyncWrite:sub(sent + 1)
        asyncStallStart = now
      elseif partial and partial > 0 then
        asyncWrite = asyncWrite:sub(partial + 1)
        asyncStallStart = now
      end
      if err and not asyncWouldBlock(err) then
        asyncClose("send failed: " .. tostring(err))
        return
      end
      if asyncStallStart > 0 and now - asyncStallStart > 12.0 then
        -- The reused keep-alive connection is dead (tunnel/server closed it
        -- while idle). Drop it; the next poll reconnects fresh.
        asyncClose("send stalled")
        return
      end
      if asyncWrite == "" then
        asyncState = "recv"
        asyncStallStart = now
      end
      return
    end

    if asyncState == "recv" then
      if not asyncSock then asyncClose("no sock"); return end
      local chunk, err, partial = asyncSock:receive(4096)
      local gotBytes = false
      if chunk then
        asyncStallStart = now
        asyncRead = asyncRead .. chunk
        gotBytes = true
      elseif partial and #partial > 0 then
        -- Non-blocking TLS often returns partial bytes along with "wantread";
        -- consume them so we make progress instead of stalling forever.
        asyncStallStart = now
        asyncRead = asyncRead .. partial
        gotBytes = true
      end

      if gotBytes then
        -- Shared parsing (works for a full chunk OR partial reads): headers
        -- first, then Content-Length-framed body. Repeated here for both
        -- cases would drift, so both feed this one block.
        while asyncInHeaders do
          local hdrEnd = asyncRead:find("\r\n\r\n")
          if not hdrEnd then break end
          local headerBlock = asyncRead:sub(1, hdrEnd - 1)
          asyncRead = asyncRead:sub(hdrEnd + 4)
          for line in (headerBlock .. "\n"):gmatch("([^\r\n]+)") do
            local k, v = line:match("^([^:]+):%s*(.-)%s*$")
            if k and k:lower() == "content-length" then
              asyncBodyLen = tonumber(v) or -1
            end
          end
          asyncInHeaders = false
        end
        if not asyncInHeaders then
          if asyncBodyLen >= 0 then
            asyncBody = asyncBody .. asyncRead
            asyncRead = ""
            if #asyncBody >= asyncBodyLen then
              local full = asyncBody:sub(1, asyncBodyLen)
              if asyncActive and asyncActive.resp then
                asyncActive.resp[#asyncActive.resp + 1] = full
              end
              -- Response complete: deliver and move to next request.
              if asyncActive then
                local req = asyncActive
                if asyncDeliver(req) then asyncLastSuccess = now end
                asyncActive = nil
                asyncState = "send"
              end
            end
          else
            -- No Content-Length: treat as complete on read.
            if asyncActive and asyncActive.resp and #asyncRead > 0 then
              asyncActive.resp[#asyncActive.resp + 1] = asyncRead
            end
            asyncRead = ""
            if asyncActive then
              local req = asyncActive
              if asyncDeliver(req) then asyncLastSuccess = now end
              asyncActive = nil
              asyncState = "send"
            end
          end
        end
      elseif err then
        if err == "closed" then
          -- Server closed the connection (shouldn't with keep-alive, but handle).
          if asyncRead ~= "" or asyncBody ~= "" then
            if asyncActive and asyncActive.resp then
              if asyncBody ~= "" then asyncActive.resp[#asyncActive.resp + 1] = asyncBody end
              if asyncRead ~= "" then asyncActive.resp[#asyncActive.resp + 1] = asyncRead end
            end
            if asyncActive then asyncDeliver(asyncActive) end
            asyncActive = nil
          end
          asyncClose("server closed connection")
        elseif not asyncWouldBlock(err) then
          asyncClose("recv failed: " .. tostring(err))
        else
          -- Would block (timeout / wantread / etc.): retry on the next poll.
          -- If we've been waiting too long on a reused keep-alive connection,
          -- it's dead. Drop it and reconnect.
          if asyncStallStart > 0 and now - asyncStallStart > 12.0 then
            asyncClose("recv stalled")
          end
        end
      end
      return
    end
  end

  -- Crash-proof wrapper: a Lua error inside the async state machine must never
  -- take down the game loop. Reset to a clean state and keep retrying.
  local function asyncPoll()
    local ok, err = pcall(asyncPollInner)
    if not ok then
      asyncReset("async engine error: " .. tostring(err))
    end
  end

  -- Non-blocking battle-message send (PVP rooms): enqueues a POST to /gts via
  -- the async engine and invokes callback(decodedResponse) when it completes.
  local function pvpBattleSend(payload, callback)
    if not payload then return end
    payload.modVersion = MOD_VERSION
    payload.version = MOD_VERSION
    local gName, rVer = getClientVersionInfo()
    payload.gameVersion = gName
    payload.recompVersion = rVer
    asyncPending[#asyncPending + 1] = {
      url = getServerUrl() .. "/gts",
      body = Json.encode(payload),
      resp = {},
      callback = callback,
    }
    while #asyncPending > 30 do table.remove(asyncPending, 1) end
  end

  -- Generation-aware party pack for the wire: Gen 2 uses packMon2 so both
  -- peers rebuild identical copies with unpackMon2; Gen 1 keeps the vanilla
  -- packParty path.
  local function packPartyForGame(game, party)
    if isGen2 then
      local okP, PvpEngine = pcall(require, "mods.gen1online-gamecorner.pvp.engine")
      if okP and PvpEngine and PvpEngine.packParty then
        return PvpEngine.packParty(party)
      end
    end
    return Protocol.packParty(party)
  end

  -- =========================================================================
  -- ASYNCHRONOUS JOB SYSTEM (Replacement for Lua Threading)
  -- Coordinates non-blocking network polling and overworld remote player placement
  -- while keeping host player movement and menu navigation 100% local.
  -- =========================================================================
  local Jobs = {
    registry = {},
    nextId = 1
  }

  function Jobs.submit(name, stepFn, cancelFn, persist)
    local id = Jobs.nextId
    Jobs.nextId = Jobs.nextId + 1
    local job = {
      id = id,
      name = name or "task",
      status = "running",
      step = stepFn,
      cancel = cancelFn,
      persist = (persist ~= false),
      createdAt = (_G.love and _G.love.timer and _G.love.timer.getTime) and _G.love.timer.getTime() or os.time()
    }
    Jobs.registry[id] = job
    return id
  end

  function Jobs.poll(id)
    return Jobs.registry[id] or { status = "error", err = "unknown job" }
  end

  function Jobs.cancel(id)
    local job = Jobs.registry[id]
    if job and job.status == "running" then
      job.status = "cancelled"
      if job.cancel then pcall(job.cancel, job) end
    end
  end

  function Jobs.step(game, dt)
    dt = dt or (1 / 60)
    for id, job in pairs(Jobs.registry) do
      if job.status == "running" and job.step then
        local ok, res = pcall(job.step, job, game, dt)
        if not ok then
          job.status = "error"
          job.err = tostring(res)
        elseif res == "done" then
          job.status = "done"
        end
      end
      if (job.status == "done" or job.status == "cancelled" or job.status == "error") and not job.persist then
        Jobs.registry[id] = nil
      end
    end
  end

  -- NOTE: Battle responses are drained by GtsNetAdapter:update() directly, not here.
  --       This function only handles position-sync and challenge/trade signals.
  local function processGlobalThreadMessages(game)
    local now = (_G.love and _G.love.timer and _G.love.timer.getTime) and _G.love.timer.getTime() or os.time()

    -- Feed the non-blocking persistent HTTP client (coalescing sync_pos to avoid bufferbloat)
    -- so position syncs stay real-time without building a multi-second backlog over the tunnel.
    if netOutChannel then
      while true do
        local req = netOutChannel:pop()
        if not (req and req.url) then break end
        if req.body then
          local okDec, decoded = pcall(Json.decode, req.body)
          if okDec and type(decoded) == "table" then
            decoded.modVersion = MOD_VERSION
            decoded.version = MOD_VERSION
            local gName, rVer = getClientVersionInfo()
            decoded.gameVersion = gName
            decoded.recompVersion = rVer
            req.body = Json.encode(decoded)

            if decoded.action == "sync_pos" then
              -- Coalesce: if a sync_pos is already waiting in asyncPending, update it with
              -- the latest position in place rather than stacking up behind older requests!
              local replaced = false
              for i = #asyncPending, 1, -1 do
                local pReq = asyncPending[i]
                if pReq and pReq.body and pReq.body:find('"action"%s*:%s*"sync_pos"') then
                  req.resp = {}
                  asyncPending[i] = req
                  replaced = true
                  break
                end
              end
              if not replaced then
                req.resp = {}
                asyncPending[#asyncPending + 1] = req
              end
            else
              req.resp = {}
              asyncPending[#asyncPending + 1] = req
            end
          else
            req.resp = {}
            asyncPending[#asyncPending + 1] = req
          end
        else
          req.resp = {}
          asyncPending[#asyncPending + 1] = req
        end
      end
      -- Cap the queue generously: PVP battle messages share this queue, and
      -- dropping them would deadlock the lockstep battle exchange.
      while #asyncPending > 30 do
        table.remove(asyncPending, 1)
      end
    end

    -- Advance the non-blocking engine here AND every frame in core.update.
    -- Local-first: this path never blocks the game loop. Safety net: if the
    -- engine has not delivered a response in ~8s it is not reaching the server,
    -- so send ONE sync synchronously (throttled to every 8s) to keep the player
    -- on the server and refresh remote players. This only fires while the
    -- smooth path is failing, and a brief block every 8s beats losing
    -- visibility. The engine is NOT reset, so it keeps trying and seamlessly
    -- takes back over the moment it delivers.
    if #asyncPending > 0 then
      asyncPoll()
      -- The synchronous fallback must never fire mid-battle: it blocks the
      -- main thread (fresh connection + handshake) which would freeze the PVP
      -- lockstep. During a battle the async path is the only transport.
      if not inBattle and (now - asyncLastSuccess) > 8.0 and (now - lastFallbackTime) >= 8.0 then
        lastFallbackTime = now
        local req = table.remove(asyncPending, 1)
        if req then
          local resp = {}
          local sent = false
          local ok = makeHttpRequest({
            url = req.url,
            method = "POST",
            timeout = 8.0,
            headers = {
              ["Content-Type"] = "application/json",
              ["Content-Length"] = tostring(#(req.body or "")),
              ["X-Mod-Version"] = MOD_VERSION
            },
            source = function()
              if not sent then sent = true; return req.body end
              return nil
            end,
            sink = function(chunk) if chunk then table.insert(resp, chunk) end end
          })
          if ok and #resp > 0 and netInChannel then
            netInChannel:push(table.concat(resp))
          end
        end
      end
    end

    -- Diagnostic: while the async engine is failing, write its state to a file
    -- every ~5s so the exact failure point can be reported.
    if asyncDiagTime == 0 or now - asyncDiagTime >= 5.0 then
      asyncDiagTime = now
      if (now - asyncLastSuccess) > 5.0 and asyncLastError ~= "" then
        pcall(function()
          local f = _G.love and _G.love.filesystem
          if f and f.write then
            f.write("gts_async_diag.txt", string.format(
              "state=%s lastError=%s lastSuccessAge=%ds pending=%d active=%s sock=%s\n",
              tostring(asyncState), tostring(asyncLastError),
              math.floor(now - asyncLastSuccess), #asyncPending,
              asyncActive and "yes" or "no",
              asyncSock and "yes" or "no"))
          end
        end)
      end
    end
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

          -- 2. Live Network Challenge Receiver (PVP Battle or Trade Popup!)
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
                    game.stack:push(TextBox.new(game, wrapText("YOU NEED AT LEAST 1 POKÃ©MON IN YOUR PARTY TO BATTLE!")))
                  elseif not remotePartyPacked or #remotePartyPacked == 0 then
                    game.stack:push(TextBox.new(game, wrapText(string.format("%s HAS NO POKÃ©MON IN THEIR PARTY!", challengerName or "FOE"))))
                  else
                    game.stack:push(TextBox.new(game, "CHALLENGE ACCEPTED!\nSTARTING PVP BATTLE!"))
                    startPvpBattle(game, challengerName, challengerId, remotePartyPacked, true, sharedSeed, roomId)
                  end
                end
              elseif cType == "ACCEPT_TRADE" then
                isWaitingForChallenge = false
                local myId = getTrainerInfo(game.save)
                gtsApiPost({ action = "clear_challenge", trainerId = myId }, 0.5)
                if not game.save or not game.save.party or #game.save.party == 0 then
                  game.stack:push(TextBox.new(game, wrapText("YOU NEED AT LEAST 1 POKÃ©MON IN YOUR PARTY TO TRADE!")))
                else
                  game.stack:push(TextBox.new(game, wrapText("OFFER ACCEPTED! STARTING LINK TRADE!")))
                  startLinkTrade(game, challengerName, challengerId, false, roomId)
                end
              elseif cType == "DECLINE" then
                isWaitingForChallenge = false
                local myId = getTrainerInfo(game.save)
                gtsApiPost({ action = "clear_challenge", trainerId = myId }, 0.5)
                game.stack:push(TextBox.new(game, wrapText("CHALLENGE DECLINED BY OPPONENT.")))
              elseif cType == "PVP" or cType == "TRADE" then
                local myId, myName = getTrainerInfo(game.save)
                local promptItems = {
                  {
                    label = string.format("ACCEPT %s", cType),
                    onSelect = function()
                      gtsApiPost({ action = "clear_challenge", trainerId = myId }, 0.5)
                      local myPackedParty = packPartyForGame(game, game.save and game.save.party or {})
                      if cType == "PVP" then
                        if not game.save or not game.save.party or #game.save.party == 0 then
                          game.stack:push(TextBox.new(game, wrapText("YOU NEED AT LEAST 1 POKÃ©MON IN YOUR PARTY TO BATTLE!")))
                          return
                        end
                        if not remotePartyPacked or #remotePartyPacked == 0 then
                          game.stack:push(TextBox.new(game, wrapText(string.format("%s HAS NO POKÃ©MON IN THEIR PARTY!", challengerName or "FOE"))))
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
                          game.stack:push(TextBox.new(game, wrapText("YOU NEED AT LEAST 1 POKÃ©MON IN YOUR PARTY TO TRADE!")))
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
      math.randomseed(os.time() + math.floor((os.clock() or 0) * 1000000))
      p.id = math.random(10000, 99999)
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

  -- Calculate Total PokÃ©dex Caught from Save
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

  local function storageRead(key)
    key = tostring(key or ""):gsub("%.lua.*$", "")
    if currentMod and currentMod.storage and currentMod.storage.read then
      local ok, res = pcall(currentMod.storage.read, currentMod.storage, key)
      if ok and res ~= nil then return res end
    end
    return nil
  end

  local function storageWrite(key, value)
    key = tostring(key or ""):gsub("%.lua.*$", "")
    if currentMod and currentMod.storage and currentMod.storage.write then
      local ok, res = pcall(currentMod.storage.write, currentMod.storage, key, value)
      return ok and res
    end
    return false
  end

  local function storageRemove(key)
    key = tostring(key or ""):gsub("%.lua.*$", "")
    if currentMod and currentMod.storage and currentMod.storage.delete then
      pcall(currentMod.storage.delete, currentMod.storage, key)
    end
  end

  loadServerUrl()

  loadOnlineSave = function(game)
    local save = storageRead("online_save")
    if save and type(save) == "table" and save.onlineAccount and save.onlineAccount.token then
      return save
    end
    -- Also read directly from love.filesystem persistence
    local f = _G.love and _G.love.filesystem
    local SaveSerializer = require("src.core.SaveSerializer")
    if f and f.getInfo and f.getInfo("save_online_gold.lua") then
      local raw = f.read("save_online_gold.lua")
      if raw then
        local ok, decoded = pcall(SaveSerializer.decode, raw)
        if ok and decoded and decoded.onlineAccount and decoded.onlineAccount.token then
          return decoded
        end
      end
    end
    local acc = storageRead("online_account")
    if acc and type(acc) == "table" and acc.token then
      local curSave = (game and game.save) or (Game and Game.save) or {}
      curSave.onlineAccount = acc
      return curSave
    end
    if game and game.save and game.save.onlineAccount and game.save.onlineAccount.token then
      return game.save
    end
    return nil
  end

  writeOnlineSave = function(saveTable)
    if not saveTable or type(saveTable) ~= "table" then return false end
    storageWrite("online_save", saveTable)
    if saveTable.onlineAccount then
      storageWrite("online_account", saveTable.onlineAccount)
    end
    -- Also write directly to love.filesystem persistence as save_online_gold.lua
    local f = _G.love and _G.love.filesystem
    local SaveSerializer = require("src.core.SaveSerializer")
    if f and f.write and SaveSerializer and SaveSerializer.encode then
      pcall(function()
        local encoded = SaveSerializer.encode(saveTable)
        if encoded then f.write("save_online_gold.lua", encoded) end
      end)
    end
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
    local acc = storageRead("online_account")
    if not acc and save and save.onlineAccount and save.onlineAccount.token then
      acc = save.onlineAccount
    end
    if acc and type(acc) == "table" then
      if save then save.onlineAccount = acc end
      if acc.name and save and save.player then save.player.name = acc.name end
      if acc.trainerId and save and save.player then save.player.id = acc.trainerId end
      mmoLevel = tonumber(acc.level) or 1
      mmoXp = tonumber(acc.xp) or 0
      mmoToken = acc.token or nil
      localSelectedSprite = acc.spriteId or "SPRITE_RED"
      if acc.title then localTrainerTitle = acc.title end
      if acc.favoriteMon then localFavoriteMon = acc.favoriteMon end
      return acc
    end
    return nil
  end

  saveOnlineAccount = function(save)
    if not save then return end
    save.onlineAccount = save.onlineAccount or {}
    save.onlineAccount.trainerId = (save.player and save.player.id) or save.onlineAccount.trainerId or "100001"
    save.onlineAccount.name = (save.player and save.player.name) or save.onlineAccount.name or "GOLD"
    save.onlineAccount.level = mmoLevel or 1
    save.onlineAccount.xp = mmoXp or 0
    save.onlineAccount.token = mmoToken or save.onlineAccount.token
    save.onlineAccount.spriteId = localSelectedSprite or "SPRITE_RED"
    save.onlineAccount.title = localTrainerTitle or "ACE TRAINER"
    save.onlineAccount.favoriteMon = localFavoriteMon or "PIKACHU"
    storageWrite("online_account", save.onlineAccount)
  end

  syncLocalProfile = function(game, winDelta)
    if not game or not game.save then return end
    loadOnlineAccount(game.save)
    local trainerId, trainerName = getTrainerInfo(game.save)
    gtsApiPost({
      action = "update_profile",
      trainerId = trainerId,
      token = mmoToken,
      name = trainerName,
      title = localTrainerTitle,
      badges = getBadgeCount(game.save),
      pokedexCount = getPokedexCount(game.save),
      pvpWins = winDelta or 0,
      blackouts = (game.save and game.save.blackoutCount) or 0,
      favoriteMon = localFavoriteMon
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
      game.stack:push(TextBox.new(game, wrapText("YOU NEED AT LEAST 1 POKÃ©MON IN YOUR PARTY TO BATTLE!")))
      return
    end
    if not remotePartyPacked or #remotePartyPacked == 0 then
      inBattle = false
      game.stack:push(TextBox.new(game, wrapText(string.format("%s HAS NO POKÃ©MON IN THEIR PARTY!", opponentName or "FOE"))))
      return
    end

    if isGen2 then
      -- Custom Gen 2 PVP engine (pvp/*): both machines run the same
      -- deterministic battle with a shared seed; actions exchange over the
      -- async battle transport. Swap-friendly: when the recomp gains native
      -- PVP, replace this backend (pvp.config.engine = "native").
      local okPvp, PvpEngine = pcall(require, "mods.gen1online-gamecorner.pvp.engine")
      local okSess, PvpSession = pcall(require, "mods.gen1online-gamecorner.pvp.session")
      local okNet, PvpNet = pcall(require, "mods.gen1online-gamecorner.pvp.net")
      local okUi, PvpUi = pcall(require, "mods.gen1online-gamecorner.pvp.ui")
      if not (okPvp and okSess and okNet and okUi) then
        inBattle = false
        game.stack:push(TextBox.new(game, wrapText("PVP MODULE FAILED TO LOAD.")))
        return
      end

      inBattle = true
      local trainerId, myName = getTrainerInfo(game.save)
      local myParty = PvpEngine.clampParty(game.data, packPartyForGame(game, game.save.party))
      local theirParty = PvpEngine.clampParty(game.data, remotePartyPacked)
      if #myParty == 0 or #theirParty == 0 then
        inBattle = false
        game.stack:push(TextBox.new(game, wrapText("BOTH TRAINERS NEED POKÃ©MON TO BATTLE!")))
        return
      end

      local role = isHostPlayer and "host" or "guest"
      local net = PvpNet.new({
        send = pvpBattleSend,
        myId = trainerId,
        theirId = opponentId,
        roomId = roomId,
      })
      local session = PvpSession.new({ net = net, role = role })
      local battle = PvpEngine.new({
        gameData = game.data,
        save = game.save,
        myParty = myParty,
        theirParty = theirParty,
        myName = myName,
        theirName = opponentName or "FOE",
        theirSpriteId = nil, -- localSelectedSprite/their sprite resolved by the UI
        seed = seed or 12345,
        role = role,
      })

      local ui = PvpUi.new(game, {
        battle = battle,
        save = game.save,
        session = session,
        onDone = function()
          -- Return to the map immediately: never leave the battle screen up
          -- (the vanilla Gen 2 onDone pops the battle state, World.lua:5879).
          if game and game.stack then
            pcall(function() game.stack:pop() end)
          end
          pcall(function()
            local Music = require("src.core.Music")
            if Music and Music.restoreMap then Music.restoreMap(game.data) end
          end)
          inBattle = false
          activeBattleAdapter = nil
          pcall(function() session:close() end)
          if netInChannel then while netInChannel:pop() do end end
          local myId = getTrainerInfo(game.save)
          isWaitingForChallenge = false
          lastBattleEndTime = (_G.love and _G.love.timer and _G.love.timer.getTime)
                                and _G.love.timer.getTime() or os.time()
          -- Non-blocking room/challenge cleanup (never freeze on the end screen).
          pvpBattleSend({ action = "clear_challenge", trainerId = myId })
          pvpBattleSend({ action = "clear_challenge", trainerId = opponentId })
          pvpBattleSend({ action = "clear_battle_room", roomId = roomId })
          if battle and battle.outcome == "win" then
            addMmoXp(game, "pvp_win", nil, { opponentName = opponentName or "TRAINER", opponentId = opponentId or "0" })
            syncLocalProfile(game, 1)
            performForcedSave(game)
          elseif battle then
            addMmoXp(game, "pvp_loss", nil, { opponentName = opponentName or "TRAINER", opponentId = opponentId or "0" })
            performForcedSave(game)
          end
        end,
      })
      game.stack:push(ui)
      return
    end

    inBattle = true
    local trainerId, myName = getTrainerInfo(game.save)
    local myPackedParty = packPartyForGame(game, game.save.party)

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

        -- FLUSH netInChannel to eliminate any stale ACCEPT_PVP / challenge
        -- responses that the poll loop queued during the battle. Without this,
        -- a stale ACCEPT_PVP fires a new battle the moment battle.finish
        -- clears the inBattle guard.
        if netInChannel then while netInChannel:pop() do end end

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

    if isGen2 then
      -- The engine's LinkState (link cable trade) is Gen 1 only; a Gen 2
      -- (Gold) trade room is not ported yet, so refuse cleanly instead of
      -- crashing once both sides reach the party selection screen.
      game.stack:push(TextBox.new(game, wrapText("LINK TRADES ARE NOT YET SUPPORTED ON GOLD (GEN 2).")))
      return
    end
    -- A trade needs one mon to offer and one to keep.
    if not game.save or not game.save.party or #game.save.party < 2 then
      game.stack:push(TextBox.new(game, wrapText("YOU NEED AT LEAST 2 POKÃ©MON IN YOUR PARTY TO TRADE!")))
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

  -- Immediate server disconnect when the player quits to the title screen
  -- (QUIT in the START menu -> returnToTitle).  Must run BEFORE the engine
  -- tears down the world, so returnToTitle is wrapped on both classes.  This
  -- is a silent session teardown: no "DISCONNECTED" box and no offline-save
  -- restore, because the player is leaving the game entirely, not losing the
  -- connection mid-play.
  local function disconnectOnTitle(game)
    if not isGtsServerConnected then return end
    if _G.__gtsQuitLogout then pcall(function() _G.__gtsQuitLogout(game) end) end
    if netSession then
      pcall(function() netSession:close() end)
      netSession = nil
    end
    isHost = false
    roomCode = nil
    activeBattleAdapter = nil
    isWaitingForChallenge = false
    if game and game.save then
      writeOnlineSave(game.save)
    end
    isGtsServerConnected = false
    local ow = getWorld(game)
    if ow then
      clearAllNetPlayers(ow)
    end
  end

  local okGame2, Game2Mod = pcall(require, "src.core.Game2")
  for _, cls in ipairs({ Game, (okGame2 and Game2Mod) or nil }) do
    if cls and cls.returnToTitle then
      local origReturnToTitle = cls.returnToTitle
      cls.returnToTitle = function(self, ...)
        disconnectOnTitle(self)
        return origReturnToTitle(self, ...)
      end
    end
  end

  -- REAL-TIME SMOOTH VECTOR INTERPOLATION & AUTHENTIC TILE-STEP ANIMATION
  local function updateNpcMovement(npc, dt)
    if not npc or not npc.targetPx or not npc.targetPy then return end

    dt = math.min(dt or 0.01667, 0.05)
    local now = (_G.love and _G.love.timer and _G.love.timer.getTime) and _G.love.timer.getTime() or os.time()

    local dx = npc.targetPx - npc.px
    local dy = npc.targetPy - npc.py
    local dist = math.sqrt(dx * dx + dy * dy)

    -- If map changed or wildly out of bounds (> 256 px / 16 tiles), snap cleanly
    if dist > 256 then
      npc.px = npc.targetPx
      npc.py = npc.targetPy
      npc.cellX = npc.targetCellX or math.floor((npc.px + 8) / 16)
      npc.cellY = npc.targetCellY or math.floor((npc.py + 8) / 16)
      npc.x = npc.cellX
      npc.y = npc.cellY
      npc.moving = false
      npc.stillTimer = 0
      npc.stepProgress = 0
      npc.animClock = 0
      npc.facing = npc.targetFacing or npc.facing
      return
    end

    if dist > 0.5 then
      -- Dynamic speed calibrated to Game Boy step rates:
      -- 1X normal walk: 64 px/s (16px in 15 frames = ~250ms per tile).
      -- Catch-up speed: if lagging behind (>16px), scale smoothly up to 120-160 px/s so the gap closes naturally.
      local speed = 64
      if dist > 32 then
        speed = math.min(180, dist * 4.0)
      elseif dist > 16 then
        speed = 96
      end

      local maxStep = speed * dt
      local step = math.min(dist, maxStep)

      -- Smooth 2D normalized translation
      local dirX = dx / dist
      local dirY = dy / dist
      npc.px = npc.px + dirX * step
      npc.py = npc.py + dirY * step

      -- Facing direction: orient along the dominant movement vector
      if math.abs(dx) > math.abs(dy) * 1.1 then
        npc.facing = dx > 0 and "right" or "left"
      elseif math.abs(dy) > math.abs(dx) * 1.1 then
        npc.facing = dy > 0 and "down" or "up"
      elseif npc.targetFacing then
        npc.facing = npc.targetFacing
      end

      npc.cellX = math.floor((npc.px + 8) / 16)
      npc.cellY = math.floor((npc.py + 8) / 16)
      npc.x = npc.cellX
      npc.y = npc.cellY

      npc.moving = true
      npc.stillTimer = 0

      -- Leg step animation: advance animClock smoothly at 60Hz and flip legs every 16px of travel
      npc.animClock = (npc.animClock or 0) + (dt * 60)
      npc.stepProgress = (npc.stepProgress or 0) + step
      if npc.stepProgress >= 16 then
        npc.stepProgress = npc.stepProgress - 16
        npc.stepFlip = not npc.stepFlip
      end
    else
      -- Reached destination waypoint
      npc.px = npc.targetPx
      npc.py = npc.targetPy
      npc.cellX = npc.targetCellX or math.floor((npc.px + 8) / 16)
      npc.cellY = npc.targetCellY or math.floor((npc.py + 8) / 16)
      npc.x = npc.cellX
      npc.y = npc.cellY

      if npc.targetFacing then
        npc.facing = npc.targetFacing
      end

      local timeSincePacket = now - (npc.lastPacketTime or now)

      -- CONTINUOUS DEAD RECKONING (capped to ONE tile per packet):
      -- If the remote player was actively moving on their client (serverMoving
      -- == true), the packet was recent (<0.45s), and we have not already
      -- predicted a tile ahead since the last real packet, predictively step
      -- into the next tile instead of stuttering. The `predicting` flag is
      -- reset by syncMultiNetPlayers whenever a fresh server packet arrives,
      -- so this NEVER chains multiple predicted tiles ahead — which is what
      -- made the sprite walk off the map and then teleport back.
      if npc.serverMoving and timeSincePacket < 0.45 and not npc.predicting then
        npc.predicting = true
        local delta = Collision.DELTA[npc.facing] or { 0, 1 }
        npc.targetPx = npc.px + delta[1] * 16
        npc.targetPy = npc.py + delta[2] * 16
        npc.targetCellX = npc.cellX + delta[1]
        npc.targetCellY = npc.cellY + delta[2]
        npc.moving = true
        npc.stillTimer = 0
        npc.animClock = (npc.animClock or 0) + (dt * 60)
        npc.stepProgress = (npc.stepProgress or 0) + (64 * dt)
        if npc.stepProgress >= 16 then
          npc.stepProgress = npc.stepProgress - 16
          npc.stepFlip = not npc.stepFlip
        end
      else
        -- Remote player is genuinely stationary
        npc.stillTimer = (npc.stillTimer or 0) + dt
        if npc.stillTimer >= 0.05 then
          npc.moving = false
          npc.stepProgress = 0
          npc.animClock = 0
        end
      end
    end
  end

  syncMultiNetPlayers = function(game, ow, playersList)
    if not ow or not ow.map then
      clearAllNetPlayers(ow)
      return
    end

    local activeIds = {}
    local currentMapId = tostring(ow.map.id)
    local now = (_G.love and _G.love.timer and _G.love.timer.getTime) and _G.love.timer.getTime() or os.time()

    for _, data in ipairs(playersList or {}) do
      local tid = tostring(data.trainerId)
      local remoteMapId = tostring(data.map)

      if remoteMapId:lower() == currentMapId:lower() then
        activeIds[tid] = true
        netPlayerMap[tid] = data

        local facing = data.facing or "down"
        local isMoving = (data.moving == true)
        local destX = tonumber(data.x) or 5
        local destY = tonumber(data.y) or 5

        -- Accept high-res px/py if provided by sender, fallback to cell * 16
        local targetPx = (type(data.px) == "number" and data.px) or (destX * 16)
        local targetPy = (type(data.py) == "number" and data.py) or (destY * 16)

        if not netNpcs[tid] then
          -- Initial spawn position
          local initPx = targetPx
          local initPy = targetPy
          if isMoving and (type(data.px) ~= "number") then
            local delta = Collision.DELTA[facing] or { 0, 1 }
            initPx = (destX - delta[1]) * 16
            initPy = (destY - delta[2]) * 16
          end

          local pNpc = {
            trainerId = tid,
            isCoopPlayer = true,
            passable = true,
            px = initPx,
            py = initPy,
            targetPx = targetPx,
            targetPy = targetPy,
            cellX = math.floor((initPx + 8) / 16),
            cellY = math.floor((initPy + 8) / 16),
            targetCellX = destX,
            targetCellY = destY,
            facing = facing,
            targetFacing = facing,
            serverMoving = isMoving,
            lastPacketTime = now,
            packetInterval = 0.18,
            moveSpeed = 96,
            name = data.name or "TRAINER",
            animClock = 0,
            stepFlip = false,
            moving = isMoving,
            stepProgress = 0,
            stillTimer = 0,
            walkPhase = function(self)
              if not self.moving then return 0 end
              local p = math.floor(self.animClock or 0) % 16
              return (p >= 4 and p < 12) and 1 or 0
            end,
            draw = function(self, camX, camY)
              if self.sprite then
                -- Drawn through drawPeople / entity pass
                self.sprite:draw(
                  self.px, self.py, camX or 0, camY or 0,
                  self.facing, self:walkPhase(), self.stepFlip)
              end
            end
          }

          local chosenRemoteSprite = data.spriteId or (isGen2 and "SPRITE_CHRIS" or "SPRITE_RED")
          local sprites = ow.sprites or (game and game.data and (game.data.gen2Sprites or game.data.sprites)) or {}
          local spriteDef = sprites[chosenRemoteSprite] or sprites["SPRITE_CHRIS"] or sprites["SPRITE_RED"]
          if spriteDef then
            pNpc.spriteDef = spriteDef
            pNpc.sprite = SpriteRenderer.new(spriteDef, tonumber(tid) or 1)
            if ow.applySpritePalette then
              pcall(ow.applySpritePalette, ow, pNpc)
            end
          end

          -- Write remote-sprite diagnostic once so a missing sprite can be diagnosed
          if not gtsSpriteDiagWritten then
            gtsSpriteDiagWritten = true
            pcall(function()
              local f = _G.love and _G.love.filesystem
              if f and f.write then
                f.write("gts_sprite_diag.txt", string.format(
                  "tid=%s spriteId=%s spriteCreated=%s spriteDef=%s spritesCount=%d\n",
                  tostring(tid), tostring(data.spriteId),
                  (pNpc.sprite and "yes") or "no",
                  (spriteDef and spriteDef.id) or "nil",
                  (type(sprites) == "table") and _G.next(sprites) and 1 or 0))
              end
            end)
          end

          netNpcs[tid] = pNpc
        else
          local pNpc = netNpcs[tid]
          local prevTime = pNpc.lastPacketTime or (now - 0.18)
          local interval = now - prevTime
          if interval > 0.05 and interval < 2.0 then
            pNpc.packetInterval = interval
          end
          pNpc.lastPacketTime = now
          pNpc.targetPx = targetPx
          pNpc.targetPy = targetPy
          pNpc.targetCellX = destX
          pNpc.targetCellY = destY
          pNpc.targetFacing = facing
          pNpc.serverMoving = isMoving
          pNpc.predicting = false

          -- If spriteDef changed dynamically (e.g. avatar change), update sprite
          local chosenRemoteSprite = data.spriteId or (isGen2 and "SPRITE_CHRIS" or "SPRITE_RED")
          if not pNpc.sprite or (pNpc.spriteDef and pNpc.spriteDef.id ~= chosenRemoteSprite) then
            local sprites = ow.sprites or (game and game.data and (game.data.gen2Sprites or game.data.sprites)) or {}
            local spriteDef = sprites[chosenRemoteSprite] or sprites["SPRITE_CHRIS"] or sprites["SPRITE_RED"]
            if spriteDef and (not pNpc.spriteDef or pNpc.spriteDef ~= spriteDef) then
              pNpc.spriteDef = spriteDef
              pNpc.sprite = SpriteRenderer.new(spriteDef, tonumber(tid) or 1)
              if ow.applySpritePalette then pcall(ow.applySpritePalette, ow, pNpc) end
            end
          end
        end
      end
    end

    for tid, pNpc in pairs(netNpcs) do
      if not activeIds[tid] then
        removeNetPlayer(ow, tid)
      end
    end
  end

  -- Register persistent background jobs for asynchronous MMO coordination
  Jobs.submit("network_sync", function(job, game, dt)
    processGlobalThreadMessages(game)
  end, nil, true)

  Jobs.submit("overworld_placement", function(job, game, dt)
    local ow = getWorld(game)
    if ow and isGtsServerConnected then
      for _, pNpc in pairs(netNpcs) do updateNpcMovement(pNpc, dt) end
      for _, fNpc in pairs(netFollowers) do updateNpcMovement(fNpc, dt) end
    end
  end, nil, true)

  local function getRankTitle(level, pvpWins)
    level = tonumber(level) or 1
    if level >= 100 then return "POKÃ©MON LEGEND"
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
            game.stack:push(TextBox.new(game, wrapText("YOU DO NOT HAVE ANY OF THE WANTED POKÃ©MON!")))
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
        Font.draw("WANTED POKÃ©MON:", 8, 68)

        if #wantedList == 0 then
          Font.draw(" - ANY POKÃ©MON", 8, 80)
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
                    game.stack:push(TextBox.new(game, wrapText("NO POKÃ©MON IN THIS RANGE.")))
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
      game.stack:push(TextBox.new(game, wrapText("YOU NEED AT LEAST 2 POKÃ©MON IN PARTY TO DEPOSIT!")))
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
      "ACE TRAINER", "BUG CATCHER", "POKÃ©MANIAC", "LASS", "YOUNGSTER",
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
            game.stack:push(TextBox.new(game, wrapText("YOU HAVE NO POKÃ©MON IN YOUR PARTY!")))
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
                local msg = string.format("FAVORITE POKÃ©MON SET TO:\n%s!", mName)
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
        label = "CREATE NEW PLAYER",
        onSelect = function()
          openFreshOnlinePlayerMenu(game)
        end
      },
      {
        label = "REDEEM RECOVERY TOKEN",
        onSelect = function()
          openRedeemTokenMenu(game)
        end
      },
      {
        label = "DISCONNECT",
        onSelect = function()
          handleDisconnect(game)
        end
      },
      { label = "BACK", onSelect = function() end }
    }

    game.stack:push(Menu.new(game, items, { tx = 0, ty = 0, tw = 20, maxVisible = 7, startCloses = true }))
  end

  -- Apply custom sprite avatar to local player immediately on overworld
  applyPlayerSprite = function(game, spriteId)
    if not game or not spriteId then return end
    local gWorld = getWorld(game)
    if not gWorld or not gWorld.player then return end
    local sprites = gWorld.sprites or (game.data and (game.data.gen2Sprites or game.data.sprites)) or {}
    local sDef = sprites[spriteId] or sprites["SPRITE_CHRIS"] or sprites["SPRITE_RED"]
    if sDef and gWorld.player.setSprite then
      pcall(gWorld.player.setSprite, gWorld.player, sDef)
      if gWorld.applySpritePalette then
        pcall(gWorld.applySpritePalette, gWorld, gWorld.player)
      end
    end
  end

  -- Wrap Player.new to ensure whenever local player is initialized, chosen avatar is used
  -- Player avatar helper (native walking animations preserved)
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
            }, 10.0)

            if res and res.success and res.account then
              local acc = res.account
              local newTid = tonumber(acc.trainerId) or 100001
              mmoLevel = 1
              mmoXp = 0
              mmoToken = acc.token
              localSelectedSprite = chosenSprite
              isGtsServerConnected = true

              -- Use active save or initialize fresh save if none exists
              local activeSave = game.save or {}
              if not activeSave.party then
                if isGen2 then
                  local okGen2Save, Gen2SaveModule = pcall(require, "src.core.gen2.Save")
                  if okGen2Save and Gen2SaveModule and Gen2SaveModule.newGame then
                    activeSave = Gen2SaveModule.newGame({ playerName = chosenName, trainerId = newTid })
                  end
                end
                if not activeSave.player then
                  local SaveDataModule = pcall(require, "src.core.SaveData") and require("src.core.SaveData") or nil
                  local bootCfg = game.bootConfig and game:bootConfig() or nil
                  activeSave = (SaveDataModule and SaveDataModule.newGame and SaveDataModule.newGame(bootCfg)) or {}
                end
              end

              activeSave.player = activeSave.player or {}
              activeSave.player.name = chosenName
              activeSave.player.id = newTid
              activeSave.onlineAccount = {
                trainerId = tostring(newTid),
                name = chosenName,
                level = 1,
                xp = 0,
                token = acc.token,
                spriteId = chosenSprite,
                title = localTrainerTitle,
                favoriteMon = localFavoriteMon
              }

              game.save = activeSave
              if game.adoptSave then game:adoptSave(game.save) end
              saveOnlineAccount(game.save)
              writeOnlineSave(game.save)

              -- Apply sprite to local player immediately with Gen 2 palettes
              applyPlayerSprite(game, chosenSprite)

              local ow = getWorld(game)
              syncLocalProfile(game, 0)
              fetchGtsServerSync(newTid)

              if ow and ow.player and ow.map and netOutChannel then
                local p = ow.player
                local delta = Collision.DELTA[p.facing] or { 0, 1 }
                local followerSpecies = game.save.party and game.save.party[1] and game.save.party[1].species

                netOutChannel:push({
                  url = getServerUrl() .. "/gts",
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
              local err = (res and res.error) or netDiagReport()
              local errMsg = string.format("COULD NOT CREATE PLAYER!\n%s", err)
              game.stack:push(TextBox.new(game, wrapText(errMsg)))
            end
          end
        })
      end
      game.stack:push(Menu.new(game, spriteItems, { tx = 1, ty = 1, tw = 18, maxVisible = 6, startCloses = true }))
    end

    local function startNewCharacterFlow()
      local namingScreen = NamingScreen.new(game, {
        title = Strings("YOUR ONLINE NAME?"),
        maxLen = 7,
        default = "",
        onDone = function(enteredName)
          enteredName = (enteredName or ""):gsub("^%s+", ""):gsub("%s+$", "")
          if #enteredName == 0 then
            game.stack:push(TextBox.new(game, wrapText("PLEASE ENTER A VALID ONLINE NAME!"), function()
              startNewCharacterFlow()
            end))
            return
          end

          if Profanity and Profanity.contains and Profanity.contains(enteredName) then
            game.stack:push(TextBox.new(game, wrapText("NAME CONTAINS INAPPROPRIATE LANGUAGE!\nPLEASE CHOOSE ANOTHER NAME."), function()
              openFreshOnlinePlayerMenu(game)
            end))
            return
          end

          local check = gtsApiGet("/player/check_name?name=" .. enteredName, 1.5)
          if check and check.taken then
            local reasonMsg = string.format("NAME '%s' IS ALREADY TAKEN ON SERVER!", enteredName)
            game.stack:push(TextBox.new(game, wrapText(reasonMsg), function()
              local takenOptions = {
                {
                  label = "ENTER RECOVERY TOKEN",
                  onSelect = function()
                    openRedeemTokenMenu(game)
                  end
                },
                {
                  label = "CHOOSE DIFFERENT NAME",
                  onSelect = function()
                    startNewCharacterFlow()
                  end
                },
                { label = "CANCEL", onSelect = function() end }
              }
              game.stack:push(Menu.new(game, takenOptions, { tx = 1, ty = 1, tw = 18, maxVisible = 5, startCloses = true }))
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
  openServerUrlMenu = function(game)
    loadServerUrl()
    local cur = getServerUrl()
    local info = string.format("CURRENT SERVER:\n%s\n\nTO CHANGE THE SERVER URL:\nEDIT gts_config.txt NEXT TO\nmain.lua, THEN RESTART\nTHE GAME.\n\nFORMAT:\nserver_url=<URL>", cur)
    game.stack:push(TextBox.new(game, wrapText(info)))
  end

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
        label = "SERVER URL",
        onSelect = function() openServerUrlMenu(game) end
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
                local sf, bf, tf = getOnlineSaveFiles()
                storageRemove(sf)
                storageRemove(bf)
                storageRemove(tf)
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
          if game and game.save then
            writeOnlineSave(game.save)
          end
          if offlineSaveBackup then
            game.save = offlineSaveBackup
            if game.adoptSave then game:adoptSave(game.save) end
            local ow = getWorld(game)
            if isGen2 and ow and ow.loadPlayerData then
              pcall(ow.loadPlayerData, ow, game.save)
            end
            local pMap = (game.save.position and game.save.position.map) or (game.save.player and game.save.player.map)
            local px = (game.save.position and game.save.position.x) or (game.save.player and game.save.player.x)
            local py = (game.save.position and game.save.position.y) or (game.save.player and game.save.player.y)
            local pFacing = (game.save.position and game.save.position.facing) or (game.save.player and game.save.player.facing) or "down"
            if ow and ow.setMap and pMap and px and py then
              pcall(ow.setMap, ow, pMap, px, py, pFacing)
            end
            applyPlayerSprite(game, "SPRITE_CHRIS")
          end
          game.stack:push(TextBox.new(game, wrapText("DISCONNECTED FROM ONLINE SERVER.\nLOCAL OFFLINE SAVE RESTORED.")))
        end
      }
    }

    game.stack:push(Menu.new(game, items, { tx = 0, ty = 0, tw = 20, maxVisible = 7, startCloses = true }))
  end

  handleConnectToServer = function(game)
    -- 0. Enforce PokÃ©mon Gold (Gen 2) Only
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

    -- 3. Check for existing online profile or launch Character Creation
    local onlineSave = loadOnlineSave(game)
    local onlineAcc = onlineSave and onlineSave.onlineAccount

    local loginSuccess = false
    if onlineAcc and onlineAcc.token then
      local loginRes = gtsApiPost({ action = "login_player", token = onlineAcc.token, trainerId = tostring(onlineAcc.trainerId) }, 2.0)
      if loginRes and loginRes.success and loginRes.account then
        onlineAcc = loginRes.account
        onlineSave.onlineAccount = onlineAcc
        loginSuccess = true
      end
    end

    if not loginSuccess then
      -- First time connecting or token invalid: Prompt user to create their online character!
      openFreshOnlinePlayerMenu(game)
      return
    end

    -- Adopt online save and restore exact location, map, flags, party, inventory
    mmoLevel = tonumber(onlineAcc.level) or 1
    mmoXp = tonumber(onlineAcc.xp) or 0
    mmoToken = onlineAcc.token
    localSelectedSprite = onlineAcc.spriteId or (isGen2 and "SPRITE_CHRIS" or "SPRITE_RED")
    localTrainerTitle = onlineAcc.title or "ACE TRAINER"
    localFavoriteMon = onlineAcc.favoriteMon or "PIKACHU"

    game.save = onlineSave
    if game.adoptSave then game:adoptSave(game.save) end

    local ow = getWorld(game)
    if isGen2 and ow and ow.loadPlayerData then
      pcall(ow.loadPlayerData, ow, game.save)
    end

    -- Teleport to the exact last recorded online location!
    local pMap = (game.save.position and game.save.position.map) or (game.save.player and game.save.player.map) or defaultStartingOutdoor
    local px = (game.save.position and game.save.position.x) or (game.save.player and game.save.player.x) or defaultStartingOutdoorX
    local py = (game.save.position and game.save.position.y) or (game.save.player and game.save.player.y) or defaultStartingOutdoorY
    local pFacing = (game.save.position and game.save.position.facing) or (game.save.player and game.save.player.facing) or "down"

    if ow and ow.setMap and pMap and px and py then
      pcall(ow.setMap, ow, pMap, px, py, pFacing)
    end

    applyPlayerSprite(game, localSelectedSprite)
    writeOnlineSave(game.save)
    isGtsServerConnected = true

    syncLocalProfile(game, 0)
    local tid, currentName = getTrainerInfo(game.save)

    if ow and ow.player and ow.map and netOutChannel then
      local p = ow.player
      local delta = Collision.DELTA[p.facing] or { 0, 1 }
      local followerSpecies = game and game.save and game.save.party and game.save.party[1] and game.save.party[1].species

      netOutChannel:push({
        url = getServerUrl() .. "/gts",
        body = Json.encode({
          action = "sync_pos",
          modVersion = MOD_VERSION,
          version = MOD_VERSION,
          gameVersion = select(1, getClientVersionInfo()),
          recompVersion = select(2, getClientVersionInfo()),
          trainerId = tid,
          name = onlineAcc.name or currentName,
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
          moving = false,
          species = followerSpecies
        })
      })
    end

    local connMsg = string.format("CONNECTED TO SERVER!\nONLINE SAVE: %s\nLOCATION: %s", onlineAcc.name or currentName, tostring(pMap))
    game.stack:push(TextBox.new(game, wrapText(connMsg), function()
      openOnlineOptionsMenu(game)
    end))
  end
  _G.gtsConnectToServer = handleConnectToServer

  -- Active server logout (used by quit-to-title and the START-menu QUIT item).
  -- Stored on _G so the big returned function below does not need to capture
  -- the extra locals (LuaJIT's 60-upvalue cap on that closure).
  _G.__gtsQuitLogout = function(game)
    if not isGtsServerConnected then return end
    local tid = getTrainerInfo(game and game.save)
    if tid then
      pvpBattleSend({ action = "logout", trainerId = tid })
      pvpBattleSend({ action = "clear_challenge", trainerId = tid })
    end
  end


return function(mod)
  currentMod = mod
  print("[Gen1Online] Initializing Gen1Online Asynchronous Threaded 60FPS MMO Mod...")

  -- Wrap the START-menu QUIT / EXIT item so the player is actively logged out
  -- of the server before the app closes (never leave a ghost online).
  local function wrapQuitItems(game, list)
    if not list then return end
    for i, item in ipairs(list) do
      if item and item.label then
        local lbl = tostring(item.label):upper()
        if lbl == "QUIT" or lbl:find("EXIT") or lbl:find("SHUTDOWN") then
          local origSelect = item.onSelect
          item.onSelect = function(...)
            if _G.__gtsQuitLogout then pcall(function() _G.__gtsQuitLogout(game) end) end
            if origSelect then origSelect(...) end
          end
        end
      end
    end
  end

  -- Hook Start Menu (identical method as DebugMenu)
  mod.hooks:wrap("ui.start_menu.items", function(nextFn, game, items)
    local list = nextFn and nextFn(game, items) or items
    if not list or type(list) ~= "table" then list = items end

    -- While connected to the online server, hide the engine's SAVE row: online
    -- saves are written automatically to the server-backed save, so a manual
    -- save prompt would be misleading (matches the SaveData guards below).
    -- Only a LIVE connection hides it; a restored online profile that is not
    -- connected still shows SAVE.
    if isGtsServerConnected then
      for i = #list, 1, -1 do
        local item = list[i]
        if item then
          local itemValue = tostring(item.value or ""):lower()
          local itemLabel = tostring(item.label or ""):upper()
          if itemValue == "save" or itemLabel == "SAVE" then
            table.remove(list, i)
          end
        end
      end
    end

    local connectItem = {
      label = isGtsServerConnected and "ONLINE" or "CONNECT",
      onSelect = function()
        if isGtsServerConnected then
          openOnlineOptionsMenu(game)
        else
          handleConnectToServer(game)
        end
      end,
    }

    local targetIndex = #list + 1
    for i, item in ipairs(list) do
      if item and item.label and tostring(item.label):upper():find("DEBUG") then
        targetIndex = i
        break
      end
    end

    table.insert(list, targetIndex, connectItem)
    wrapQuitItems(game, list)
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

  -- 2. PokÃ©mon Caught
  onEvent("pokemon.caught", function(payload)
    if Game and Game.save then
      addMmoXp(Game, "catch")
      performForcedSave(Game)
      syncLocalProfile(Game, 0)
    end
  end)

  -- 3. PokÃ©mon Evolved & Move Learned
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

  -- 4. Trades & PokÃ©mon Received
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

  -- 7. PC Box Storage Operations
  local BoxesModule = pcall(require, "src.pokemon.Boxes") and require("src.pokemon.Boxes") or nil
  if BoxesModule and BoxesModule.deposit then
    local origDeposit = BoxesModule.deposit
    BoxesModule.deposit = function(save, mon)
      local res = origDeposit(save, mon)
      if isGtsServerConnected and Game and Game.save then performForcedSave(Game) end
      return res
    end
  end

  -- 8. Bag & Inventory Operations
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
    if isGtsServerConnected and Game and Game.save and Game.save.position then
      Game.save.position.map = mapId
      Game.save.position.x = cellX or Game.save.position.x or 3
      Game.save.position.y = cellY or Game.save.position.y or 6
      Game.save.position.facing = facing or Game.save.position.facing or "down"
    end
    if NPCs and NPCs.spawnForMap then pcall(NPCs.spawnForMap, self) end
    return res
  end

  -- Draw MMO player name tags in WINDOW space, through the sanctioned
  -- render.hud seam (src/core/Game.lua:563, src/core/Game2.lua:1230).  A
  -- world point lands on the window exactly where its sprite does: Gen 2
  -- centers the player in the full window with World:zoomScale (World:draw,
  -- src/world/gen2/World.lua:9947), while Gen 1 letterboxes its 160x144
  -- world canvas at the viewport origin scaled by viewport.scale
  -- (Renderer:endFrame, src/render/Renderer.lua:879).  In both, the camera
  -- already centers the player, so canvas = world - camera.  The old code
  -- added a bogus +80/+72 offset (pinning the tag to the lower right) and
  -- Gen 2's drawWorldBody drew a second copy, doubling every tag.
  mod.hooks:wrap("render.hud", function(nextFn, game, viewport)
    if nextFn then nextFn(game, viewport) end
    local ow = getWorld(game)
    if not (isGtsServerConnected and ow and ow.player and ow.camera and viewport) then
      return
    end
    local isG2 = game.world ~= nil
    local camX = ow.camera.x or (ow.player.cellX * 16)
    local camY = ow.camera.y or (ow.player.cellY * 16)
    local s = isG2
      and ((ow.zoomScale and ow:zoomScale()) or viewport.scale or 1)
      or (viewport.scale or 1)
    local ox = isG2 and 0 or (viewport.gameX or 0)
    local oy = isG2 and 0 or (viewport.gameY or 0)

    -- Canvas-space cull, window-space placement: only tags on the view (with
    -- a margin) are drawn, and each lands just above its sprite.
    local function drawHeaderTag(nameStr, wx, wy)
      local cleanName = tostring(nameStr or "TRAINER"):gsub("_", " ")
      local cx = math.floor(wx - camX)
      local cy = math.floor(wy - camY - 16)
      if cx >= -48 and cx <= 208 and cy >= -48 and cy <= 192 then
        Font.draw(cleanName,
          math.floor(ox + cx * s) - math.floor(#cleanName * 3),
          math.floor(oy + cy * s))
      end
    end

    -- Remote player name tags, directly above each head
    for tid, pNpc in pairs(netNpcs) do
      local rawData = netPlayerMap[tid] or {}
      local name = rawData.name or pNpc.name or "TRAINER"
      drawHeaderTag(name, pNpc.px or 0, pNpc.py or 0)
    end

    -- Local player name tag, directly above the player's sprite
    local myName = (Game.save and Game.save.onlineAccount and Game.save.onlineAccount.name)
      or (Game.save and Game.save.player and Game.save.player.name) or "YOU"
    drawHeaderTag(myName, ow.player.px, ow.player.py)
  end)

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
          url = getServerUrl() .. "/gts",
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

    if self.map and NPCs and NPCs.spawnForMap then
      pcall(NPCs.spawnForMap, self)
    end
    if origOverworldUpdate then origOverworldUpdate(self, dt) end
    if not Game or not isGtsServerConnected then return end

    -- 1. Advance all registered background jobs (network sync & overworld placement)
    Jobs.step(Game, dt)

    -- 2. Push position to background network queue (Rate limited to preserve 60FPS fluid gameplay)
    local ow = self
    local p = ow.player
    if p and ow.map and netOutChannel then
      local now = (_G.love and _G.love.timer and _G.love.timer.getTime) and _G.love.timer.getTime() or os.time()
      local positionChanged = (p.cellX ~= lastPlayerX) or (p.cellY ~= lastPlayerY) or (ow.map.id ~= lastPlayerMap)
      local movingChanged = (p.moving ~= lastPlayerMoving)
      local isMoving = (p.moving == true) or positionChanged

      if movingChanged or (isMoving and now - lastSendTime >= 0.10) or (now - lastSendTime >= 2.0) then
        lastSendTime = now
        lastPlayerX = p.cellX
        lastPlayerY = p.cellY
        lastPlayerMap = ow.map.id
        lastPlayerMoving = p.moving

        if Game and Game.save and Game.save.position then
          Game.save.position.map = ow.map.id
          Game.save.position.x = p.cellX
          Game.save.position.y = p.cellY
          Game.save.position.facing = p.facing
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
          url = getServerUrl() .. "/gts",
          body = Json.encode(payload)
        })

        processGlobalThreadMessages(Game)
      end
    end
  end

  -- Hook Gen 1 Overworld drawWorld to render remote player sprites
  if not isGen2 and type(OverworldState) == "table" then
    local dwKey = "draw" .. "World"
    local origGen1DrawWorld = OverworldState[dwKey]
    if origGen1DrawWorld then
      OverworldState[dwKey] = function(self)
        local res = origGen1DrawWorld(self)
        if isGtsServerConnected and self.camera and next(netNpcs) then
          local cam = self.camera
          for _, pNpc in pairs(netNpcs) do
            if pNpc and pNpc.sprite and pNpc.px and pNpc.py then
              pcall(function()
                pNpc.sprite:draw(
                  pNpc.px, pNpc.py, cam.x or 0, cam.y or 0,
                  pNpc.facing, pNpc:walkPhase(), pNpc.stepFlip)
              end)
            end
          end
        end
        return res
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
                Game.stack:push(TextBox.new(Game, wrapText("YOU NEED AT LEAST 1 POKÃ©MON IN YOUR PARTY TO BATTLE!")))
                return
              end
              local myId, myName = getTrainerInfo(Game.save)
              local myPackedParty = packPartyForGame(Game, Game.save.party)
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
            label = "LINK TRADE",
            onSelect = function()
              if not Game.save or not Game.save.party or #Game.save.party == 0 then
                Game.stack:push(TextBox.new(Game, wrapText("YOU NEED AT LEAST 1 POKÃ©MON IN YOUR PARTY TO TRADE!")))
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
      end
      if NPCs and NPCs.spawnForMap then pcall(NPCs.spawnForMap, self) end
      return res
    end

    -- 2. Gen 2 sprite persistence: map loads / teleports / dismounts run
    -- World:applyPlayerState, which snaps the local sprite back to the
    -- default SPRITE_CHRIS (src/world/gen2/World.lua:5310).  Re-apply the
    -- chosen avatar whenever the player returns to the normal walk state;
    -- bike/surf keep their own state sprites.
    local okFieldMoves, FieldMoves = pcall(require, "src.world.gen2.FieldMoves")
    if okFieldMoves and FieldMoves and Gen2World.applyPlayerState then
      local origApplyPlayerState = Gen2World.applyPlayerState
      Gen2World.applyPlayerState = function(self, state)
        local res = origApplyPlayerState(self, state)
        if isGtsServerConnected
            and (self.playerState or FieldMoves.PLAYER_NORMAL)
              == FieldMoves.PLAYER_NORMAL then
          applyPlayerSprite(self.game or Game, localSelectedSprite)
        end
        return res
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
            url = getServerUrl() .. "/gts",
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
        return
      end

      if self.map and NPCs and NPCs.spawnForMap then
        pcall(NPCs.spawnForMap, self)
      end

      if origGen2Step then origGen2Step(self) end
      if not curGame or not isGtsServerConnected then return end

      local dt = 1 / 60
      -- Advance all registered background jobs (network sync & overworld placement)
      Jobs.step(curGame, dt)

      local p = self.player
      if p and self.map and netOutChannel then
        local now = (_G.love and _G.love.timer and _G.love.timer.getTime) and _G.love.timer.getTime() or os.time()
        local positionChanged = (p.cellX ~= lastPlayerX) or (p.cellY ~= lastPlayerY) or (self.map.id ~= lastPlayerMap)
        local movingChanged = (p.moving ~= lastPlayerMoving)
        local isMoving = (p.moving == true) or positionChanged

        if movingChanged or (isMoving and now - lastSendTime >= 0.10) or (now - lastSendTime >= 2.0) then
          lastSendTime = now
          lastPlayerX = p.cellX
          lastPlayerY = p.cellY
          lastPlayerMap = self.map.id
          lastPlayerMoving = p.moving

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
            url = getServerUrl() .. "/gts",
            body = Json.encode(payload)
          })

          processGlobalThreadMessages(curGame)
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
                  curGame.stack:push(TextBox.new(curGame, wrapText("YOU NEED AT LEAST 1 POKÃ©MON IN YOUR PARTY TO BATTLE!")))
                  return
                end
                local myId, myName = getTrainerInfo(curGame.save)
                local myPackedParty = packPartyForGame(curGame, curGame.save.party)
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
              label = "LINK TRADE",
              onSelect = function()
                if not curGame.save or not curGame.save.party or #curGame.save.party == 0 then
                  curGame.stack:push(TextBox.new(curGame, wrapText("YOU NEED AT LEAST 1 POKÃ©MON IN YOUR PARTY TO TRADE!")))
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

    -- 5. Gen 2 remote player sprite drawing. netNpcs are NOT part of self.npcs,
    -- so the engine never rendered them (name tags drew via render.hud, sprites
    -- were invisible). Hook drawPeople (called by both the flat drawWorldBody
    -- path and the tilt path) and draw each remote sprite using the SAME
    -- transform the local player uses (src/world/gen2/Player.lua:198):
    -- translate by the camera offset, scale by the zoom, then sprite:draw at
    -- the entity's own world px/py. This keeps size, position and animation in
    -- lockstep with the local character.
    if Gen2World.drawPeople then
      local origGen2DrawPeople = Gen2World.drawPeople
      local drawDiagTime = 0
      Gen2World.drawPeople = function(self, s, billboard)
        local res = origGen2DrawPeople(self, s, billboard)
        local drawn = 0
        if isGtsServerConnected and self.camera and next(netNpcs) then
          local cam = self.camera
          local ox = (0 - (cam.x or 0)) * (s or 1)
          local oy = (0 - (cam.y or 0)) * (s or 1)
          local G = love.graphics
          for _, pNpc in pairs(netNpcs) do
            if pNpc and pNpc.sprite and pNpc.px and pNpc.py then
              pcall(function()
                G.push()
                G.translate(ox, oy)
                G.scale(s or 1, s or 1)
                pNpc.sprite:draw(
                  pNpc.px, pNpc.py, 0, 0,
                  pNpc.facing, pNpc:walkPhase(), pNpc.stepFlip)
                G.pop()
              end)
              drawn = drawn + 1
            end
          end
        end
        -- Diagnostic (throttled): confirms this hook fires and how many
        -- remote sprites were drawn. Look for gts_draw_diag.txt next to
        -- gts_sprite_diag.txt.
        local nowD = (_G.love and _G.love.timer and _G.love.timer.getTime) and _G.love.timer.getTime() or os.time()
        if drawDiagTime == 0 or nowD - drawDiagTime >= 3.0 then
          drawDiagTime = nowD
          local nCount = 0
          for _ in pairs(netNpcs) do nCount = nCount + 1 end
          pcall(function()
            local f = _G.love and _G.love.filesystem
            if f and f.write then
              f.write("gts_draw_diag.txt", string.format(
                "fired=yes netNpcs=%d drawn=%d camX=%s camY=%s s=%s\n",
                nCount, drawn,
                tostring(self.camera and self.camera.x or "nil"),
                tostring(self.camera and self.camera.y or "nil"),
                tostring(s)))
            end
          end)
        end
        return res
      end
    end
  end

  -- Wrap Game.update to continuously service active GtsNetAdapter during battle
  mod.hooks:wrap("core.update", function(nextFn, game, dt)
    -- MMO speed lock: while connected, every player runs at 1x (NORMAL) game
    -- speed so the online world stays in sync. Force it BEFORE the update so
    -- the frame itself runs at 1x, and repeat every frame so the speed
    -- hotkey / shoulder buttons / options menu cannot change it.
    if isGtsServerConnected and game and game.options then
      game.options.speed = 1
      if game.options.speedOverworld ~= nil then game.options.speedOverworld = 1 end
      if game.options.speedBattle ~= nil then game.options.speedBattle = 1 end
      if game.options.speedMenu ~= nil then game.options.speedMenu = 1 end
      game.speedOverride = nil
    end

    if nextFn then nextFn(game, dt) end

    -- Continuous frame service for background jobs (sync, placement, and battle messages)
    Jobs.step(game, dt)
    -- Advance the non-blocking sync client every frame (non-blocking and
    -- crash-proof) so it can complete requests and recover from stalls.
    asyncPoll()

    -- Low-rate keepalive ping (only when player is stationary / in menu)
    local gWorld = getWorld(game)
    -- If the session is disconnected, tear down any leftover async connection
    -- so a stale engine can't interfere with a later reconnect.
    if not isGtsServerConnected and asyncSock then
      asyncReset("disconnected")
    end
    if isGtsServerConnected and not isWaitingForChallenge and gWorld
       and gWorld.player and gWorld.map and netOutChannel then
      local ow = gWorld
      local p = ow.player
      local now = (_G.love and _G.love.timer and _G.love.timer.getTime) and _G.love.timer.getTime() or os.time()
      if not p.moving and (now - lastSendTime >= 4.0) then
        lastSendTime = now
        lastPlayerX = p.cellX
        lastPlayerY = p.cellY
        lastPlayerMap = ow.map.id

        local trainerId, trainerName = getTrainerInfo(game.save)
        local followerSpecies = game.save.party and game.save.party[1] and game.save.party[1].species
        local delta = Collision.DELTA[p.facing] or { 0, 1 }

        netOutChannel:push({
          url = getServerUrl() .. "/gts",
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
            if self.oppClass == "OPP_ROUTE2_DAN" or self.oppClass == "OPP_ROUTE2_DAVE" then
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
  end)


  local function loadLocal(mod, relative)
    local source = nil
    if mod and mod.read then pcall(function() source = mod:read(relative) end) end
    if not source then return {} end
    local loadFn = loadstring or load
    local chunk, err = loadFn(source, "@" .. (mod.path or "mod") .. "/" .. tostring(relative))
    if not chunk then return {} end
    local ok, res = pcall(chunk)
    if not ok then return {} end
    return res or {}
  end

  local function safeCall(fn, ...)
    if type(fn) == "function" then
      local ok, res = pcall(fn, ...)
      if ok then return res end
    end
    return fn or {}
  end

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
  local CrashView = safeCall(loadLocal(mod, paths.crash .. "view.lua"), ArcadeUI)
  local TubeView = safeCall(loadLocal(mod, paths.tube .. "view.lua"), ArcadeUI)
  local CaseView = safeCall(loadLocal(mod, paths.case .. "view.lua"), ArcadeUI)
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

  if mod.options and mod.options.define then
    pcall(function()
      mod.options:define({
        { key = "shiny_sparkles", label = "SHINY SPARKLES", type = "toggle", default = true },
      })
    end)
  end
  if mod.content and mod.content.constants and mod.content.constants.patch then
    pcall(function() mod.content.constants:patch("coinCap", config.coinCap) end)
  end
  if type(CoinCase) == "function" then
    local ok, res = pcall(CoinCase, mod)
    if ok and type(res) == "table" then CoinCase = res end
  end
  if type(CoinCase) == "table" and CoinCase.installSlotCompatibility then
    pcall(CoinCase.installSlotCompatibility, config.coinCap)
    pcall(CoinCase.installHiddenCoinCompatibility, config.coinCap)
  end

  local Service = safeCall(Services, mod, Catalog, Pawn, config)
  local UI = safeCall(UIFactory, mod, Service, Catalog, Pawn, config)
  local function playSound(game, name) if Sound and Sound.play and game and game.data then Sound.play(game.data, name) end end
  local common = {
    mod = mod, coins = (Service and Service.coins), coinCap = config.coinCap,
    close = (UI and UI.close), play = playSound,
  }
  local function context(extra)
    local out = {}
    for key, value in pairs(common) do out[key] = value end
    for key, value in pairs(extra or {}) do out[key] = value end
    return out
  end

  local Blackjack = safeCall(loadLocal(mod, paths.blackjack .. "screen.lua"), context({
    rules = Rules, view = BlackjackView, bets = blackjackBets,
  }))
  local Holdem = safeCall(loadLocal(mod, paths.holdem .. "screen.lua"), context({
    rules = HoldemRules, view = HoldemView, cardView = BlackjackView,
    bets = holdemBets,
    gtsApiGet = function(path, to) return gtsApiGet(path, to) end,
    gtsApiPost = function(payload, to) return gtsApiPost(payload, to) end,
    getTrainerInfo = function(save) return getTrainerInfo(save) end,
    isServerConnected = function() return isGtsServerConnected end,
  }))
  local Crash = safeCall(loadLocal(mod, paths.crash .. "screen.lua"), context({
    rules = CrashRules, view = CrashView,
  }))
  local TubeFlyer = safeCall(loadLocal(mod, paths.tube .. "screen.lua"), context({
    rules = FlappyRules, view = TubeView,
  }))
  local PrizeCase = safeCall(loadLocal(mod, paths.case .. "screen.lua"), context({
    rules = CaseRules, view = CaseView,
    rewardPool = function(game) return (Service and Service.caseRewardPool and Service.caseRewardPool(game, CaseRules)) end,
    giveReward = (Service and Service.giveCaseReward),
  }))

  -- Load and wire the (currently empty) Gen 2 NPC and quest registries. Each
  -- module is `return function(loadModFile, mod) ... return api end`. The
  -- overworld hooks call NPCs.spawnForMap / NPCs.talkTo / Quests.* at runtime,
  -- so assigning the top-level locals here (before the factory returns) makes
  -- the real modules visible to them.
  local NPCsModule = loadLocal(mod, "npcs/init.lua")
  local QuestsModule = loadLocal(mod, "quests/init.lua")
  local function installModule(fn, fallback)
    if type(fn) == "function" then
      local ok, res = pcall(fn, loadLocal, mod)
      if ok and type(res) == "table" then return res end
    end
    return fallback
  end
  NPCs = installModule(NPCsModule, NPCs)
  Quests = installModule(QuestsModule, Quests)

  if mod.content and mod.content.screens and mod.content.screens.register then
    for screen, class in pairs({
      [ids.blackjack] = Blackjack, [ids.holdem] = Holdem,
      [ids.crash] = Crash, [ids.tube] = TubeFlyer, [ids.case] = PrizeCase,
    }) do
      pcall(function() mod.content.screens:register(screen, { new = class.new }) end)
    end
    pcall(function() mod.content.screens:register(ids.pokemon, { new = UI.pokemonMenu }) end)
    pcall(function() mod.content.screens:register(ids.item, { new = UI.itemMenu }) end)
  end

  local function getDerivedPath(subpath)
    return "save/mod-derived/" .. tostring(mod.id or "gen1online-gamecorner") .. "/" .. subpath
  end

  if mod.content and mod.content.sprites and mod.content.sprites.register then
    for _, tableDef in ipairs({
      { id = "BLACKJACK", file = "blackjack" },
      { id = "HOLDEM", file = "holdem" },
    }) do
      for piece = 1, 8 do
        local sub = string.format("world/%s_table_%02d.png", tableDef.file, piece)
        pcall(function()
          mod.content.sprites:register(("SPRITE_%s_TABLE_%02d"):format(tableDef.id, piece), {
            image = getDerivedPath(sub), frames = 1, trueColor = true,
          })
        end)
      end
    end
    for _, machine in ipairs({ "crash", "flappy", "case" }) do
      for piece = 1, 2 do
        local sub = string.format("world/%s_machine_%02d.png", machine, piece)
        pcall(function()
          mod.content.sprites:register(("SPRITE_ARCADE_%s_%02d")
            :format(machine:upper(), piece), {
              image = getDerivedPath(sub), frames = 1, trueColor = true,
            })
        end)
      end
    end
  end

  if type(Lounge) == "table" and Lounge.register then
    pcall(Lounge.register, mod, ids.lounge)
  elseif type(Lounge) == "function" then
    pcall(Lounge, mod, ids.lounge)
  end

  local function openCasino(game, message, screen, done)
    UI.openAfterMessage(game, message, screen, done)
  end

  if mod.content and mod.content.map_scripts and mod.content.map_scripts.register then
    pcall(function()
      mod.content.map_scripts:register("GAME_CORNER", { talk = {
        TEXT_GAMECORNER_CLERK1 = UI.coinClerk,
        TEXT_GAMECORNER_CLERK = UI.coinClerk,
        TEXT_PAWN_BROKER = UI.pawnBroker,
        TEXT_PRIZE_CLERK1 = UI.prizeClerk1,
        TEXT_PRIZE_CLERK2 = UI.prizeClerk2,
        TEXT_PRIZE_CLERK3 = UI.prizeClerk3,
        TEXT_BLACKJACK_TABLE = function(game, _, _, done)
          openCasino(game, "BLACKJACK!\fDealer hits on 16,\nstands on 17.\fBlackjack pays 3:2.",
            ids.blackjack, done)
        end,
        TEXT_BLACKJACK_DEALER = function(game, _, _, done)
          openCasino(game, "Place your bet!\fTry to reach 21\nwithout busting.",
            ids.blackjack, done)
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
    end)
  end

  print("[Gen1Online] Asynchronous Threaded 60FPS MMO Mod initialized successfully.")
end
