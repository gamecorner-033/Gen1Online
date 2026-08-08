-- zip test2

return function(mod)
  print("[Gen1Online] Initializing Gen1Online Asynchronous Threaded 60FPS MMO Mod...")

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

  -- Direct Cloudflare Tunnel URL
  local GTS_SERVER_URL = "https://highest-luxury-constructed-switch.trycloudflare.com"
  local isGtsServerConnected = false -- Explicit manual connection required via menu

  -- Lock Game Speed strictly to 1X whenever online and connected to the server to prevent desyncs
  local origLogicSpeed = Game.logicSpeed
  Game.logicSpeed = function(self)
    if isGtsServerConnected then
      return 1
    end
    if origLogicSpeed then return origLogicSpeed(self) end
    return 1
  end

  -- Networking State
  local netSession = nil
  local isHost = false
  local roomCode = nil
  local lastSendTime = 0
  local lastPlayerX = nil
  local lastPlayerY = nil
  local lastPlayerMap = nil
  local activeBattleAdapter = nil -- Active GtsNetAdapter instance
  local isWaitingForChallenge = false -- Locks player movement while waiting for challenge response
  local challengeWaitTimer = 0
  local lastBattleEndTime = -999 -- Cooldown: ignore challenges for 5s after battle ends
  local inBattle = false          -- Guard: prevents double-starting a battle from duplicate messages

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
      local fn = (url:sub(1,5)=="https" and https) and https.request or (http and http.request)
      if fn and ltn12 then
        local ok, err = pcall(fn, {
          url = url, method = "POST",
          headers = { ["Content-Type"]="application/json",
                      ["Content-Length"]=tostring(#body) },
          source = ltn12.source.string(body),
          sink   = ltn12.sink.table(resp_body),
          timeout = 3.5
        })
        if not ok then
          debugChan:push("HTTP POST error: " .. tostring(err))
          return ""
        end
      else
        debugChan:push("HTTP libraries not loaded (http=" .. tostring(http) .. ", https=" .. tostring(https) .. ", ltn12=" .. tostring(ltn12) .. ")")
        return ""
      end
      return table.concat(resp_body)
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

  -- Universal Transport Helper
  local function makeHttpRequest(reqTable)
    reqTable.timeout = reqTable.timeout or 0.5
    if reqTable.url:sub(1, 5) == "https" and https then
      local ok, res, code, headers, status = pcall(https.request, reqTable)
      if ok and code then return ok, res, code, headers, status end
    end
    if http then
      return pcall(http.request, reqTable)
    end
    return false, nil, nil, nil, nil
  end

  local function gtsApiGet(path, timeout)
    if not ltn12 then return nil end
    local response_body = {}
    local ok, res, code, headers, status = makeHttpRequest({
      url = GTS_SERVER_URL .. path,
      method = "GET",
      sink = ltn12.sink.table(response_body),
      timeout = timeout or 0.5
    })
    if ok and code == 200 and #response_body > 0 then
      local str = table.concat(response_body)
      local data = Json.decode(str)
      return data
    end
    return nil
  end

  local function gtsApiPost(payload, timeout)
    if not ltn12 then return nil end
    local jsonStr = Json.encode(payload)
    local response_body = {}
    local ok, res, code, headers, status = makeHttpRequest({
      url = GTS_SERVER_URL .. "/gts",
      method = "POST",
      headers = {
        ["Content-Type"] = "application/json",
        ["Content-Length"] = tostring(#jsonStr)
      },
      source = ltn12.source.string(jsonStr),
      sink = ltn12.sink.table(response_body),
      timeout = timeout or 0.5
    })
    if ok and code == 200 and #response_body > 0 then
      local str = table.concat(response_body)
      local data = Json.decode(str)
      return data
    end
    return nil
  end

  -- Text Auto-Wrapping Helper (fits Gen 1 TextBox width of 18 chars)
  local function wrapText(str, maxLen)
    maxLen = maxLen or 18
    if not str or #str <= maxLen then return str or "" end
    local lines = {}
    for paragraph in tostring(str):gmatch("[^\r\n]+") do
      local currentLine = ""
      for word in paragraph:gmatch("%S+") do
        if #currentLine == 0 then
          currentLine = word
        elseif #currentLine + 1 + #word <= maxLen then
          currentLine = currentLine .. " " .. word
        else
          table.insert(lines, currentLine)
          currentLine = word
        end
      end
      if #currentLine > 0 then
        table.insert(lines, currentLine)
      end
    end
    return table.concat(lines, "\n")
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
      if ok and res and res.success then
        -- 1. Route multi-player positions if overworld active
        if res.players and game.overworld then
          syncMultiNetPlayers(game, game.overworld, res.players)
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
                  game.stack:push(TextBox.new(game, "CHALLENGE ACCEPTED!\nSTARTING PVP BATTLE!"))
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
                    local myPackedParty = Protocol.packParty(game.save and game.save.party or {})
                    if cType == "PVP" then
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
          end -- end cooldown guard
        end
      end
      -- Continue draining — don't leave stale frames in the queue
      respStr = netInChannel:pop()
    end
  end

  -- Sync GTS Database with 24/7 Server
  local function fetchGtsServerSync(trainerId)
    local data = gtsApiGet("/gts/browse", 1.5)
    if data and data.success then
      isGtsServerConnected = true
      gtsDb.listings = data.listings or {}
      gtsDb.history = data.history or {}

      if trainerId then
        local claimData = gtsApiGet("/gts/claims?trainerId=" .. tostring(trainerId), 1.5)
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

  -- Dual Save State Storage: Dedicated Online MMO Save File
  local ONLINE_SAVE_FILE = "save_online.lua"
  local ONLINE_BAK_FILE = "save_online.lua.bak"
  local ONLINE_TMP_FILE = "save_online.lua.tmp"
  local offlineSaveBackup = nil

  local function loadOnlineSave()
    local SaveSerializer = require("src.core.SaveSerializer")
    local fs = love.filesystem
    if not fs then return nil end
    local content = fs.read(ONLINE_SAVE_FILE)
    if not content then
      content = fs.read(ONLINE_BAK_FILE) or fs.read(ONLINE_TMP_FILE)
    end
    if not content then return nil end
    local ok, data = pcall(SaveSerializer.decode, content)
    if ok and data and type(data) == "table" then
      return data
    end
    return nil
  end

  local function writeOnlineSave(saveTable)
    if not saveTable or type(saveTable) ~= "table" then return false end
    local SaveSerializer = require("src.core.SaveSerializer")
    local fs = love.filesystem
    if not fs then return false end
    local encoded = SaveSerializer.encode(saveTable)
    if fs.getInfo(ONLINE_SAVE_FILE) then
      local prev = fs.read(ONLINE_SAVE_FILE)
      if prev then fs.write(ONLINE_BAK_FILE, prev) end
    end
    fs.write(ONLINE_TMP_FILE, encoded)
    fs.remove(ONLINE_SAVE_FILE)
    fs.write(ONLINE_SAVE_FILE, encoded)
    fs.remove(ONLINE_TMP_FILE)
    return true
  end

  -- Forced Game Save helper (Routes to save_online.lua when online, else normal local save.lua)
  local function performForcedSave(game)
    if isGtsServerConnected and game and game.save then
      writeOnlineSave(game.save)
    elseif game and game.writeSave then
      pcall(function() game:writeSave() end)
    end
  end

  -- Sync Local Trainer Profile & Online Account to Server
  local function loadOnlineAccount(save)
    if not save then return end
    save.onlineAccount = save.onlineAccount or {}
    local acc = save.onlineAccount
    mmoLevel = acc.level or 1
    mmoXp = acc.xp or 0
    mmoToken = acc.token or nil
    localSelectedSprite = acc.spriteId or "SPRITE_RED"
    if acc.title then localTrainerTitle = acc.title end
  end

  local function saveOnlineAccount(save)
    if not save then return end
    save.onlineAccount = save.onlineAccount or {}
    save.onlineAccount.level = mmoLevel
    save.onlineAccount.xp = mmoXp
    save.onlineAccount.token = mmoToken
    save.onlineAccount.spriteId = localSelectedSprite
    save.onlineAccount.title = localTrainerTitle
  end

  local function syncLocalProfile(game, winDelta)
    if not game or not game.save then return end
    loadOnlineAccount(game.save)
    local trainerId, trainerName = getTrainerInfo(game.save)
    gtsApiPost({
      action = "update_profile",
      trainerId = trainerId,
      name = trainerName,
      title = localTrainerTitle,
      badges = getBadgeCount(game.save),
      pokedexCount = getPokedexCount(game.save),
      pvpWins = winDelta or 0,
      favoriteMon = localFavoriteMon
    }, 1.5)
  end

  local function addMmoXp(game, xpType, extraAmount)
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
      gtsApiPost({
        action = "sync_xp",
        trainerId = tid,
        token = mmoToken,
        xpType = xpType,
        badges = getBadgeCount(game.save),
        pokedexCount = getPokedexCount(game.save)
      }, 1.5)

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
          addMmoXp(game, "pvp_win")
          syncLocalProfile(game, 1)
          performForcedSave(game)
          game.stack:push(TextBox.new(game, string.format("VICTORY!\nDEFEATED %s IN PVP!\n(+100 MMO XP)", opponentName or "TRAINER")))
        else
          addMmoXp(game, "pvp_loss")
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
  local function handleDisconnect(game, reason)
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

    local ow = game and game.overworld
    if ow then
      clearAllNetPlayers(ow)
    end

    -- 2. Restore local offline save from backup or disk (save.lua)
    local SaveDataModule = pcall(require, "src.core.SaveData") and require("src.core.SaveData") or nil
    local localSave = offlineSaveBackup
    if not localSave and SaveDataModule and SaveDataModule.load then
      localSave = SaveDataModule.load()
    end

    if localSave and game then
      game.save = localSave
      if game.adoptSave then game:adoptSave(game.save) end
      localSelectedSprite = "SPRITE_RED"
      applyPlayerSprite(game, "SPRITE_RED")
      if ow and game.save.map and ow.setMap then
        local m = game.save.map
        pcall(function() ow:setMap(m.id or "PALLET_TOWN", m.x or 3, m.y or 6, m.facing or "down") end)
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
                pNpc.passable = false
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
                local chosenRemoteSprite = data.spriteId or "SPRITE_RED"
                local spriteDef = game.data.sprites and (game.data.sprites[chosenRemoteSprite] or game.data.sprites["SPRITE_RED"])
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
                        fNpc.passable = false
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
  local function openTrainerCardScreen(game, tid, rawData)
    local pData = gtsApiGet("/gts/profile?trainerId=" .. tostring(tid), 1.5)
    local profile = (pData and pData.success and pData.profile) or {}

    local name = profile.name or (rawData and rawData.name) or "TRAINER"
    local level = tonumber(profile.level or (rawData and rawData.level) or mmoLevel or 1)
    local pvpWins = tonumber(profile.pvpWins or (rawData and rawData.pvpWins) or 0)
    local pvpLosses = tonumber(profile.pvpLosses or 0)
    local gtsTrades = tonumber(profile.gtsTrades or 0)
    local serverRank = tonumber(profile.serverRank or 1)
    local totalPlayers = tonumber(profile.totalPlayers or 1)
    local rank = profile.rank or getRankTitle(level, pvpWins)
    local badges = profile.badges or 0
    local pokedexCount = profile.pokedexCount or 0
    local favMon = profile.favoriteMon or "PIKACHU"

    if #name > 10 then name = name:sub(1, 10) end
    if #rank > 14 then rank = rank:sub(1, 14) end
    if #favMon > 10 then favMon = favMon:sub(1, 10) end

    local container = {
      isOverworld = false,
      update = function(self, dt)
        local input = game.input
        if input:wasPressed("b") or input:wasPressed("a") then
          game.stack:pop()
        end
      end,
      draw = function(self)
        Font.drawBox(1, 0, 18, 17)
        Font.draw("TRAINER CARD", 24, 10)
        Font.draw(string.format("NAME: %s", name), 16, 22)
        Font.draw(string.format("LEVEL: %d/100", level), 16, 34)
        Font.draw(string.format("RANK: %s", rank), 16, 46)
        Font.draw(string.format("SERVER: #%d/%d", serverRank, totalPlayers), 16, 58)
        Font.draw(string.format("PVP: %dW / %dL", pvpWins, pvpLosses), 16, 70)
        Font.draw(string.format("TRADES: %d", gtsTrades), 16, 82)
        Font.draw(string.format("BADGES: %d/8", badges), 16, 94)
        Font.draw(string.format("POKEDEX: %d", pokedexCount), 16, 106)
        Font.draw(string.format("FAV: %s", favMon), 16, 118)
        Font.draw("PRESS A/B TO CLOSE", 16, 130)
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
            if #pName > 8 then pName = pName:sub(1, 8) end
            table.insert(tradeItems, {
              label = string.format("SEND %s LV%d", pName, pMon.level),
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
                game.stack:push(TextBox.new(game, wrapText(string.format("GTS TRADE DONE! RECEIVED %s!", offName))))
              end
            })
          end

          game.stack:push(Menu.new(game, tradeItems, { tx = 1, ty = 1, tw = 18, maxVisible = 6, startCloses = true }))
        end
      end,
      draw = function(self)
        Font.drawBox(1, 0, 18, 17)
        Font.draw("GTS LISTING DETAILS", 16, 10)
        Font.draw(string.format("OFFER: %s", offName), 16, 24)
        Font.draw(string.format("LEVEL: %d", offered.level or 1), 16, 36)
        Font.draw(string.format("OT: %s (ID %d)", otName, listing.trainerId or 0), 16, 48)
        Font.draw("WANTED POKÉMON:", 16, 62)

        if #wantedList == 0 then
          Font.draw(" - ANY POKéMON", 16, 74)
        else
          local curY = 74
          for _, wSpec in ipairs(wantedList) do
            local wName = (game.data.pokemon[wSpec] and game.data.pokemon[wSpec].name) or wSpec
            if #wName > 12 then wName = wName:sub(1, 12) end
            Font.draw(string.format(" - %s", wName), 16, curY)
            curY = curY + 12
          end
        end

        Font.draw("A: TRADE  B: BACK", 16, 124)
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
      if #offName > 8 then offName = offName:sub(1, 8) end
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

    local menu = Menu.new(game, items, { tx = 1, ty = 1, tw = 18, maxVisible = 6, startCloses = true })
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
          label = string.format("WITHDRAW %s L%d", offName, offered.level or 1),
          onSelect = function()
            local returnedMon = Protocol.unpackMon(game.data, offered)
            local added = Party.add(game.save.party, returnedMon)
            if not added then Boxes.deposit(game.save, returnedMon) end

            gtsApiPost({ action = "withdraw", listingId = id, trainerId = trainerId }, 2.0)

            gtsDb.listings[id] = nil
            gtsDb.user_counts[trainerId] = math.max(0, (gtsDb.user_counts[trainerId] or 1) - 1)
            addGtsReceipt(string.format("%s WITHDREW DEPOSITED %s", trainerName, offName))
            performForcedSave(game)

            game.stack:push(TextBox.new(game, wrapText(string.format("WITHDREW %s FROM GTS!", offName))))
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
        label = string.format("CLAIM %s (%s)", cName, fromStr),
        onSelect = function()
          local claimedMon = Protocol.unpackMon(game.data, packed)
          local added = Party.add(game.save.party, claimedMon)
          if not added then Boxes.deposit(game.save, claimedMon) end

          gtsApiPost({ action = "claim", trainerId = trainerId, index = idx - 1 }, 2.0)

          table.remove(gtsDb.claim_boxes[tostring(trainerId)], idx)
          addGtsReceipt(string.format("%s CLAIMED TRADED %s", trainerName, cName))
          performForcedSave(game)

          game.stack:push(TextBox.new(game, wrapText(string.format("CLAIMED %s FROM GTS!", cName))))
        end
      })
    end

    if #items == 0 then
      game.stack:push(TextBox.new(game, wrapText("YOU HAVE NO ACTIVE DEPOSITS OR CLAIMS.")))
      return
    end

    local menu = Menu.new(game, items, { tx = 1, ty = 1, tw = 18, maxVisible = 6, startCloses = true })
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
      if #lbl > 15 then lbl = lbl:sub(1, 15) end
      table.insert(items, {
        label = lbl,
        onSelect = function() end
      })
    end

    if #items == 0 then
      game.stack:push(TextBox.new(game, wrapText("NO GTS TRANSACTIONS RECORDED YET.")))
      return
    end

    local menu = Menu.new(game, items, { tx = 1, ty = 1, tw = 18, maxVisible = 6, startCloses = true })
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
          label = string.format("+ ADD WANTED (%d/3)", #wanted + 1),
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
                        label = spec.name,
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
                    game.stack:push(Menu.new(game, monItems, { tx = 1, ty = 1, tw = 18, maxVisible = 6, startCloses = true }))
                  end
                end
              })
            end
            game.stack:push(Menu.new(game, rangeItems, { tx = 1, ty = 1, tw = 18, maxVisible = 6, startCloses = true }))
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

      game.stack:push(Menu.new(game, items, { tx = 1, ty = 1, tw = 18, maxVisible = 6, startCloses = true }))
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
      table.insert(partyItems, {
        label = string.format("%s LV%d", monName, mon.level),
        onSelect = function()
          local chosenSlot = idx
          local chosenMon = mon

          openWantedSpeciesSelector(game, function(wantedList)
            if not wantedList or #wantedList == 0 then return end

            local depositMon = table.remove(game.save.party, chosenSlot)
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

            game.stack:push(TextBox.new(game, wrapText(string.format("%s WAS DEPOSITED TO GTS!", depositMon.nickname or depositMon.species))))
          end)
        end
      })
    end

    game.stack:push(Menu.new(game, partyItems, { tx = 1, ty = 1, tw = 18, maxVisible = 6, startCloses = true }))
  end

  -- Main GTS Top-Level Menu (WITH STRICT CONNECTION GUARD)
  local function openGtsMainMenu(game)
    if not isGtsServerConnected then
      game.stack:push(TextBox.new(game, "YOU ARE NOT CONNECTED\nTO GTS SERVER!\nSELECT 'CONNECT GTS SERVER' FIRST."))
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
        label = "DEPOSIT POKEMON",
        onSelect = function() openGtsDepositMenu(game) end
      },
      {
        label = "MY LISTINGS/WITHDRAW",
        onSelect = function() openGtsMyListingsMenu(game) end
      },
      {
        label = "RECENT HISTORY (50)",
        onSelect = function() openGtsHistoryMenu(game) end
      },
      { label = "EXIT", onSelect = function() end }
    }

    game.stack:push(Menu.new(game, items, { tx = 1, ty = 1, tw = 18, maxVisible = 6, startCloses = true }))
  end

  -- Customize Local Trainer Profile Submenu
  local function openMyProfileMenu(game)
    local titles = {
      "ACE TRAINER", "BUG CATCHER", "POKéMANIAC", "LASS", "YOUNGSTER",
      "POKéMON CHAMPION", "GYM LEADER", "BLACKBELT", "SUPER NERD", "COOLTRAINER"
    }

    local items = {
      {
        label = "VIEW MY TRAINER CARD",
        onSelect = function()
          syncLocalProfile(game, 0)
          local tid, tName = getTrainerInfo(game.save)
          openTrainerCardScreen(game, tid, { name = tName })
        end
      },
      {
        label = "SELECT TRAINER TITLE",
        onSelect = function()
          local titleItems = {}
          for _, t in ipairs(titles) do
            table.insert(titleItems, {
              label = t,
              onSelect = function()
                localTrainerTitle = t
                syncLocalProfile(game, 0)
                game.stack:push(TextBox.new(game, string.format("TITLE UPDATED TO:\n%s!", t)))
              end
            })
          end
          game.stack:push(Menu.new(game, titleItems, { tx = 1, ty = 1, tw = 18, maxVisible = 6, startCloses = true }))
        end
      },
      {
        label = "SELECT FAVORITE POKÉMON",
        onSelect = function()
          if game.save and game.save.party and #game.save.party > 0 then
            local favItems = {}
            for _, mon in ipairs(game.save.party) do
              local mName = mon.nickname or (game.data.pokemon[mon.species] and game.data.pokemon[mon.species].name) or mon.species
              table.insert(favItems, {
                label = mName,
                onSelect = function()
                  localFavoriteMon = mName
                  syncLocalProfile(game, 0)
                  game.stack:push(TextBox.new(game, string.format("FAVORITE POKéMON:\n%s!", mName)))
                end
              })
            end
            game.stack:push(Menu.new(game, favItems, { tx = 1, ty = 1, tw = 18, maxVisible = 6, startCloses = true }))
          end
        end
      },
      { label = "EXIT", onSelect = function() end }
    }

    game.stack:push(Menu.new(game, items, { tx = 1, ty = 1, tw = 18, maxVisible = 6, startCloses = true }))
  end

  -- Apply custom sprite avatar to local player immediately on overworld
  local function applyPlayerSprite(game, spriteId)
    if not game or not spriteId then return end
    local sDef = game.data and game.data.sprites and (game.data.sprites[spriteId] or game.data.sprites["SPRITE_RED"])
    if sDef and game.overworld and game.overworld.player then
      game.overworld.player.sprite = SpriteRenderer.new(sDef, "player")
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

  -- Fresh Online Player Creation & Authentic Naming Screen
  local function openFreshOnlinePlayerMenu(game)
    local NamingScreen = require("src.ui.NamingScreen")

    local function pickCharacterSprite(chosenName)
      local spriteItems = {}
      for _, av in ipairs(AVAILABLE_AVATARS) do
        table.insert(spriteItems, {
          label = av.label,
          onSelect = function()
            local chosenSprite = av.id
            local tid = getTrainerInfo(game.save)

            local res = gtsApiPost({
              action = "register_player",
              trainerId = tid,
              name = chosenName,
              spriteId = chosenSprite,
              title = localTrainerTitle,
              badges = 0,
              pokedexCount = 0
            }, 2.0)

            if res and res.success and res.account then
              local acc = res.account
              mmoLevel = acc.level or 1
              mmoXp = acc.xp or 0
              mmoToken = acc.token
              localSelectedSprite = chosenSprite
              isGtsServerConnected = true

              -- Initialize Fresh Player Save via SaveData.newGame (Clean vanilla flags so Oak stops you at Route 1 grass)
              local SaveDataModule = pcall(require, "src.core.SaveData") and require("src.core.SaveData") or nil
              local bootCfg = game.bootConfig and game:bootConfig() or nil
              local newSave = (SaveDataModule and SaveDataModule.newGame and SaveDataModule.newGame(bootCfg)) or {}

              newSave.player = newSave.player or {}
              newSave.player.name = chosenName
              newSave.player.id = tid
              newSave.flags = {} -- Clean fresh event flags: Oak will stop you before entering Route 1 tall grass!
              newSave.party = {}
              newSave.badges = {}
              newSave.pokedex = { owned = {}, seen = {} }
              newSave.money = 3000
              newSave.items = { { item = "POTION", count = 1 } }
              newSave.pcItems = { { item = "POTION", count = 1 } }
              newSave.map = { id = "REDS_HOUSE_2F", x = 3, y = 6, facing = "up" }
              newSave.onlineAccount = {
                level = 1,
                xp = 0,
                token = acc.token,
                spriteId = chosenSprite,
                name = chosenName
              }

              game.save = newSave
              if game.adoptSave then game:adoptSave(game.save) end
              saveOnlineAccount(game.save)
              writeOnlineSave(game.save) -- Dedicated save_online.lua (leaves save.lua untouched!)

              -- Apply sprite to local player immediately
              applyPlayerSprite(game, chosenSprite)

              -- Warp/load starting map in Red's bedroom
              if game.overworld and game.overworld.setMap then
                pcall(function() game.overworld:setMap("REDS_HOUSE_2F", 3, 6, "up") end)
              end

              syncLocalProfile(game, 0)
              fetchGtsServerSync(tid)

              if game.overworld and game.overworld.player and game.overworld.map and netOutChannel then
                local ow = game.overworld
                local p = ow.player
                local delta = Collision.DELTA[p.facing] or { 0, 1 }
                local followerSpecies = game.save.party and game.save.party[1] and game.save.party[1].species

                netOutChannel:push({
                  url = GTS_SERVER_URL .. "/gts",
                  body = Json.encode({
                    action = "sync_pos",
                    trainerId = tid,
                    name = chosenName,
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
              end

              game.stack:push(TextBox.new(game, wrapText(string.format("WELCOME %s!\nSTARTING ONLINE ADVENTURE!\nTOKEN: %s", chosenName, mmoToken))))
            else
              local err = (res and res.error) or "NETWORK_ERROR"
              if err == "NAME_TAKEN" then
                game.stack:push(TextBox.new(game, wrapText("NAME ALREADY TAKEN! PLEASE CHOOSE ANOTHER."), function()
                  openFreshOnlinePlayerMenu(game)
                end))
              else
                game.stack:push(TextBox.new(game, wrapText("CANNOT REGISTER ACCOUNT ON SERVER!")))
              end
            end
          end
        })
      end
      game.stack:push(Menu.new(game, spriteItems, { tx = 1, ty = 1, tw = 18, maxVisible = 6, startCloses = true }))
    end

    -- Launch Authentic Vanilla NamingScreen directly (letter grid)
    local defaultName = (game.save and game.save.player and game.save.player.name) or "RED"
    local namingScreen = NamingScreen.new(game, {
      title = Strings("YOUR NAME?"),
      maxLen = 7,
      default = defaultName,
      onDone = function(enteredName)
        enteredName = (enteredName or ""):gsub("^%s+", ""):gsub("%s+$", "")
        if #enteredName == 0 then enteredName = "RED" end

        local check = gtsApiGet("/player/check_name?name=" .. enteredName, 1.5)
        if check and check.taken then
          game.stack:push(TextBox.new(game, wrapText(string.format("NAME '%s' IS TAKEN ON SERVER! CHOOSE ANOTHER.", enteredName)), function()
            openFreshOnlinePlayerMenu(game)
          end))
        else
          pickCharacterSprite(enteredName)
        end
      end
    })
    game.stack:push(namingScreen)
  end

  -- In-Game Global & Local MMO Chat Menu
  local function openMmoChatMenu(game)
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
                local res = gtsApiPost({
                  action = "send_chat",
                  trainerId = trainerId,
                  name = trainerName,
                  text = msgText,
                  scope = "global"
                }, 1.5)
                if res and res.success then
                  game.stack:push(TextBox.new(game, wrapText(string.format("CHAT BROADCAST:\n%s", msgText))))
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

  -- Online Options Menu (Shown in Start Menu once connected)
  local function openOnlineOptionsMenu(game)
    local trainerId, trainerName = getTrainerInfo(game.save)
    loadOnlineAccount(game.save)

    local items = {
      {
        label = "MY TRAINER PROFILE",
        onSelect = function()
          syncLocalProfile(game, 0)
          openTrainerCardScreen(game, trainerId, { name = trainerName })
        end
      },
      {
        label = "GLOBAL MMO CHAT",
        onSelect = function() openMmoChatMenu(game) end
      },
      {
        label = "ONLINE SETTINGS",
        onSelect = function() openMyProfileMenu(game) end
      },
      {
        label = "RESET / SWITCH SAVE",
        onSelect = function()
          local confirmMenu = {
            {
              label = "NO, KEEP CURRENT",
              onSelect = function() end
            },
            {
              label = "YES, RESET CHARACTER",
              onSelect = function()
                local fs = love.filesystem
                if fs then
                  pcall(function() fs.remove(ONLINE_SAVE_FILE) end)
                  pcall(function() fs.remove(ONLINE_BAK_FILE) end)
                  pcall(function() fs.remove(ONLINE_TMP_FILE) end)
                end
                openFreshOnlinePlayerMenu(game)
              end
            }
          }
          game.stack:push(TextBox.new(game, wrapText("WARNING: THIS WILL OVERWRITE YOUR ONLINE CHARACTER! LOCAL SAVE IS UNTOUCHED. PROCEED?"), function()
            game.stack:push(Menu.new(game, confirmMenu, { tx = 1, ty = 1, tw = 18, maxVisible = 6, startCloses = true }))
          end))
        end
      },
      {
        label = "DISCONNECT",
        onSelect = function()
          handleDisconnect(game, "DISCONNECTED FROM SERVER.\nLOCAL SAVE RESTORED.")
        end
      }
    }

    game.stack:push(Menu.new(game, items, { tx = 1, ty = 1, tw = 18, maxVisible = 6, startCloses = true }))
  end

  -- Connect to Server Flow (Dual Save State: Checks save_online.lua vs creating fresh online character)
  local function handleConnectToServer(game)
    -- 1. Backup the local offline save in memory
    if game and game.save and not isGtsServerConnected then
      offlineSaveBackup = game.save
    end

    -- 2. Check if a dedicated online save (save_online.lua) exists on disk
    local onlineSave = loadOnlineSave()
    if onlineSave and onlineSave.onlineAccount and onlineSave.onlineAccount.token and onlineSave.onlineAccount.name then
      game.save = onlineSave
      if game.adoptSave then game:adoptSave(game.save) end

      local acc = game.save.onlineAccount
      local tid, currentName = getTrainerInfo(game.save)
      loadOnlineAccount(game.save)
      isGtsServerConnected = true
      performForcedSave(game)
      syncLocalProfile(game, 0)
      applyPlayerSprite(game, localSelectedSprite)

      local ow = game.overworld
      if ow and game.save.map and ow.setMap then
        local m = game.save.map
        pcall(function() ow:setMap(m.id or "REDS_HOUSE_2F", m.x or 3, m.y or 6, m.facing or "up") end)
      end

      local ok = fetchGtsServerSync(tid)
      if ok and ow and ow.player and ow.map and netOutChannel then
        local p = ow.player
        local delta = Collision.DELTA[p.facing] or { 0, 1 }
        local followerSpecies = game.save.party and game.save.party[1] and game.save.party[1].species

        netOutChannel:push({
          url = GTS_SERVER_URL .. "/gts",
          body = Json.encode({
            action = "sync_pos",
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
        game.stack:push(TextBox.new(game, wrapText(string.format("CONNECTED TO SERVER!\nONLINE SAVE: %s", acc.name or currentName)), function()
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

    local newItem = {
      label = menuLabel,
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
    if not inserted then table.insert(list, newItem) end
    return list
  end)

  -- Hook Map Transition to clear and re-sync overworld entities
  local origSetMap = OverworldState.setMap
  OverworldState.setMap = function(self, mapId, cellX, cellY, facing)
    clearAllNetPlayers(self)
    local res = origSetMap(self, mapId, cellX, cellY, facing)
    lastPlayerMap = mapId
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

        local trainerId, trainerName = getTrainerInfo(Game.save)
        local followerSpecies = Game.save.party and Game.save.party[1] and Game.save.party[1].species

        local delta = Collision.DELTA[p.facing] or { 0, 1 }
        local fx = p.cellX - delta[1]
        local fy = p.cellY - delta[2]

        local payload = {
          action = "sync_pos",
          trainerId = trainerId,
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
            label = "PVP LINK BATTLE",
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
              Game.stack:push(TextBox.new(Game, string.format("WAITING FOR %s\nTO ACCEPT PVP...", pName)))
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
    if isGtsServerConnected and not isWaitingForChallenge and game.overworld
       and game.overworld.player and game.overworld.map and netOutChannel then
      local ow = game.overworld
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

    -- Hook Catch XP reward
    if Party and Party.add and not Party._mmoHooked then
      Party._mmoHooked = true
      local origPartyAdd = Party.add
      Party.add = function(party, mon)
        local res = origPartyAdd(party, mon)
        if res and Game then
          addMmoXp(Game, "catch")
        end
        return res
      end
    end

    -- Hook Wild / Trainer Battle XP reward
    if BattleState and BattleState.finish and not BattleState._mmoHooked then
      BattleState._mmoHooked = true
      local origBattleFinish = BattleState.finish
      BattleState.finish = function(self)
        if self.result == "win" and Game then
          if self.trainer then
            addMmoXp(Game, "trainer_battle")
          elseif self.wild then
            addMmoXp(Game, "wild_battle")
          end
        end
        if origBattleFinish then origBattleFinish(self) end
      end
    end

    -- Optional: print any debug messages from the thread
    printThreadDebug()
  end)

  print("[Gen1Online] Asynchronous Threaded 60FPS MMO Mod initialized successfully.")
end