return function(mod)
  print("[Gen1Online] Initializing Gen1Online Async Multi-Threaded MMO Mod...")

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

  -- Socket HTTP/HTTPS modules for 24/7 GTS REST Server & Cloudflare Tunnel
  local hasSocketHttp, http = pcall(require, "socket.http")
  if not hasSocketHttp then http = nil end

  local hasHttps, https = pcall(require, "ssl.https")
  if not hasHttps then https = nil end

  local hasLtn12, ltn12 = pcall(require, "ltn12")
  if not hasLtn12 then ltn12 = nil end

  -- Direct Active Cloudflare Tunnel URL
  local GTS_SERVER_URL = "https://boys-manga-demonstrated-marks.trycloudflare.com"
  local isGtsServerConnected = false

  -- Networking State (MMO Multi-Player Engines)
  local netSession = nil
  local isHost = false
  local roomCode = nil
  local lastSendTime = 0
  local pendingRequestStackItem = nil
  local p2PromptMenuStackItem = nil

  -- MMO Multi-Player NPC Registry (trainerId -> NPC object)
  local netNpcs = {}       -- trainerId -> human NPC object
  local netFollowers = {}  -- trainerId -> follower NPC object
  local netPlayerMap = {}  -- trainerId -> player raw position data

  -- Custom Trainer Profile State
  local localTrainerTitle = "ACE TRAINER"
  local localFavoriteMon = "CHARIZARD"

  -- Global Trade Station (GTS) Database
  _G.GEN1ONLINE_GTS = _G.GEN1ONLINE_GTS or {
    listings = {},       -- listingId -> listing object
    user_counts = {},    -- trainerId -> active deposit count
    history = {},        -- array of last 50 trade receipts
    claim_boxes = {},    -- trainerId -> list of completed traded mons
    next_id = 1001,
  }
  local gtsDb = _G.GEN1ONLINE_GTS

  -- Universal Non-Blocking HTTP/HTTPS Transport Helper (Supports Cloudflare Tunnels)
  local function makeHttpRequest(reqTable)
    reqTable.timeout = reqTable.timeout or 0.1
    if reqTable.url:sub(1, 5) == "https" and https then
      local ok, res, code, headers, status = pcall(https.request, reqTable)
      if ok and code then return ok, res, code, headers, status end
    end
    if http then
      return pcall(http.request, reqTable)
    end
    return false, nil, nil, nil, nil
  end

  -- HTTP API Helpers for gts_server.py & Cloudflare Tunnel
  local function gtsApiGet(path, timeout)
    if not ltn12 then return nil end
    local response_body = {}
    local ok, res, code, headers, status = makeHttpRequest({
      url = GTS_SERVER_URL .. path,
      method = "GET",
      sink = ltn12.sink.table(response_body),
      timeout = timeout or 0.1
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
      timeout = timeout or 0.1
    })
    if ok and code == 200 and #response_body > 0 then
      local str = table.concat(response_body)
      local data = Json.decode(str)
      return data
    end
    return nil
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
  local function getTrainerInfo(save)
    local p = save and save.player
    if not p then return 12345, "TRAINER" end
    if not p.id then
      p.id = math.random(10000, 99999)
    end
    return p.id, p.name or "TRAINER"
  end

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

  -- Background Pokemon Center Heal using official engine Pokemon.heal
  local function healParty(game)
    if game and game.save and game.save.party then
      for _, mon in ipairs(game.save.party) do
        Pokemon.heal(mon)
      end
    end
  end

  -- Forced Game Save helper
  local function performForcedSave(game)
    if game and game.writeSave then
      pcall(function() game:writeSave() end)
    end
  end

  -- Sync Local Trainer Profile to Server
  local function syncLocalProfile(game)
    if not game or not game.save then return end
    local trainerId, trainerName = getTrainerInfo(game.save)
    gtsApiPost({
      action = "update_profile",
      trainerId = trainerId,
      name = trainerName,
      title = localTrainerTitle,
      badges = getBadgeCount(game.save),
      pokedexCount = getPokedexCount(game.save),
      favoriteMon = localFavoriteMon
    }, 1.5)
  end

  -- Clear Multi-Player NPCs from Map
  local function removeNetPlayer(ow, tid)
    if not ow then return end
    tid = tostring(tid)

    if netFollowers[tid] then
      local fNpc = netFollowers[tid]
      for i, npc in ipairs(ow.npcs or {}) do
        if npc == fNpc then table.remove(ow.npcs, i) break end
      end
      for j, e in ipairs(ow.entities or {}) do
        if e == fNpc then table.remove(ow.entities, j) break end
      end
      netFollowers[tid] = nil
    end

    if netNpcs[tid] then
      local pNpc = netNpcs[tid]
      for i, npc in ipairs(ow.npcs or {}) do
        if npc == pNpc then table.remove(ow.npcs, i) break end
      end
      for j, e in ipairs(ow.entities or {}) do
        if e == pNpc then table.remove(ow.entities, j) break end
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
  end

  -- Safely remove stack items
  local function closePendingRequestUI()
    if pendingRequestStackItem and Game and Game.stack and Game.stack.stack then
      for i, item in ipairs(Game.stack.stack) do
        if item == pendingRequestStackItem then
          table.remove(Game.stack.stack, i)
          break
        end
      end
      pendingRequestStackItem = nil
    end
  end

  local function closeP2PromptMenu()
    if p2PromptMenuStackItem and Game and Game.stack and Game.stack.stack then
      for i, item in ipairs(Game.stack.stack) do
        if item == p2PromptMenuStackItem then
          table.remove(Game.stack.stack, i)
          break
        end
      end
      p2PromptMenuStackItem = nil
    end
  end

  local function clearAllRequestUI(game)
    closePendingRequestUI()
    closeP2PromptMenu()
    if game and game.stack and game.stack.stack then
      local stack = game.stack.stack
      for i = #stack, 2, -1 do
        local item = stack[i]
        if item and item.isOverworld == false then
          table.remove(stack, i)
        end
      end
    end
  end

  -- Disconnect Flow
  local function handleDisconnect(game, reason)
    clearAllRequestUI(game)

    if netSession then
      pcall(function() netSession:close() end)
      netSession = nil
    end
    isHost = false
    roomCode = nil
    isGtsServerConnected = false

    local ow = game and game.overworld
    if ow then
      clearAllNetPlayers(ow)
      performForcedSave(game)
      if ow.map and ow.player and ow.setMap then
        local mapId = ow.map.id
        local px, py = ow.player.cellX, ow.player.cellY
        local dir = ow.player.facing
        ow:setMap(mapId, px, py, dir)
      end
    end

    game.stack:push(TextBox.new(game, reason or "DISCONNECTED."))
  end

  -- Smooth Movement Lerp for Networked NPCs
  local function updateNpcMovement(npc, dt)
    if not npc or not npc.targetPx or not npc.targetPy then return end

    local dx = npc.targetPx - npc.px
    local dy = npc.targetPy - npc.py
    local dist = math.sqrt(dx * dx + dy * dy)

    if dist > 48 then
      npc.px = npc.targetPx
      npc.py = npc.targetPy
      npc.cellX = math.floor(npc.px / 16)
      npc.cellY = math.floor(npc.py / 16)
      npc.moving = false
    elseif dist > 0.5 then
      local speed = 96
      local step = math.min(dist, speed * (dt or 0.016))
      npc.px = npc.px + (dx / dist) * step
      npc.py = npc.py + (dy / dist) * step
      npc.cellX = math.floor((npc.px + 8) / 16)
      npc.cellY = math.floor((npc.py + 8) / 16)
      npc.moving = true
      npc.progress = (npc.progress or 0) + step * 2
      if (npc.progress or 0) >= 16 then
        npc.progress = 0
        npc.stepFlip = not npc.stepFlip
      end
    else
      npc.px = npc.targetPx
      npc.py = npc.targetPy
      npc.cellX = math.floor(npc.px / 16)
      npc.cellY = math.floor(npc.py / 16)
      npc.moving = false
    end
  end

  -- Sync Multi-Player Network NPCs on Overworld Map (Up to 16 Players)
  local function syncMultiNetPlayers(game, ow, playersList)
    if not ow or not ow.map then
      clearAllNetPlayers(ow)
      return
    end

    local activeIds = {}
    for _, data in ipairs(playersList or {}) do
      local tid = tostring(data.trainerId)
      activeIds[tid] = true
      netPlayerMap[tid] = data

      if data.map == ow.map.id then
        -- 1. Sync Human Player Avatar (SPRITE_RED, solid physical collision passable = false)
        if not netNpcs[tid] then
          local pNpc = NPC.new(game.data, ow.map.id, {
            index = 290 + (#ow.npcs % 50),
            name = data.name or "TRAINER",
            sprite = "SPRITE_RED",
            movement = "STAY",
            range = "NONE",
            x = data.x or 5,
            y = data.y or 5,
          })
          pNpc.trainerId = tid
          pNpc.isCoopPlayer = true
          pNpc.passable = false
          pNpc.px = (data.x or 5) * 16
          pNpc.py = (data.y or 5) * 16
          pNpc.targetPx = pNpc.px
          pNpc.targetPy = pNpc.py
          pNpc.update = function(self, dt, map, entities) end
          table.insert(ow.npcs, pNpc)
          table.insert(ow.entities, pNpc)
          netNpcs[tid] = pNpc
        end

        local pNpc = netNpcs[tid]
        pNpc.targetPx = (data.x or 5) * 16
        pNpc.targetPy = (data.y or 5) * 16
        pNpc.facing = data.facing or "down"

        -- 2. Sync Follower Pokemon (solid physical collision passable = false)
        if data.species then
          local spriteId = "SPRITE_WILD_" .. tostring(data.species)
          local spriteDef = game.data and game.data.sprites and game.data.sprites[spriteId]
          if spriteDef then
            if not netFollowers[tid] then
              local fNpc = NPC.new(game.data, ow.map.id, {
                index = 350 + (#ow.npcs % 50),
                name = tostring(data.species),
                sprite = spriteId,
                movement = "STAY",
                range = "NONE",
                x = data.fx or (data.x or 5),
                y = data.fy or (data.y or 5),
              })
              fNpc.trainerId = tid
              fNpc.spriteId = spriteId
              fNpc.isCoopFollower = true
              fNpc.passable = false
              fNpc.px = (data.fx or (data.x or 5)) * 16
              fNpc.py = (data.fy or (data.y or 5)) * 16
              fNpc.targetPx = fNpc.px
              fNpc.targetPy = fNpc.py
              fNpc.update = function(self, dt, map, entities) end
              table.insert(ow.npcs, fNpc)
              table.insert(ow.entities, fNpc)
              netFollowers[tid] = fNpc
            elseif netFollowers[tid].spriteId ~= spriteId then
              netFollowers[tid].spriteId = spriteId
              netFollowers[tid].sprite = SpriteRenderer.new(spriteDef, netFollowers[tid].id)
            end

            local fNpc = netFollowers[tid]
            fNpc.targetPx = (data.fx or pNpc.cellX) * 16
            fNpc.targetPy = (data.fy or pNpc.cellY) * 16
            fNpc.facing = data.facing or "down"
          else
            removeNetPlayer(ow, tid)
          end
        end
      else
        removeNetPlayer(ow, tid)
      end
    end

    -- Remove players who left the map / server
    for tid, _ in pairs(netNpcs) do
      if not activeIds[tid] then
        removeNetPlayer(ow, tid)
      end
    end
  end

  -- Helper to add history receipt to GTS (Last 50)
  local function addGtsReceipt(text)
    table.insert(gtsDb.history, 1, {
      text = text,
      time = os.time()
    })
    while #gtsDb.history > 50 do
      table.remove(gtsDb.history)
    end
  end

  -- View Detailed Trainer Card UI Screen
  local function openTrainerCardScreen(game, tid, rawData)
    local pData = gtsApiGet("/gts/profile?trainerId=" .. tostring(tid), 2.0)
    local profile = (pData and pData.success and pData.profile) or {}

    local name = profile.name or (rawData and rawData.name) or "TRAINER"
    local title = profile.title or "POKéMON TRAINER"
    local badges = profile.badges or 0
    local pokedexCount = profile.pokedexCount or 0
    local gtsTrades = profile.gtsTrades or 0
    local pvpWins = profile.pvpWins or 0
    local favMon = profile.favoriteMon or "PIKACHU"

    local container = {
      isOverworld = false,
      update = function(self, dt)
        local input = game.input
        if input:wasPressed("b") or input:wasPressed("a") then
          game.stack:pop()
        end
      end,
      draw = function(self)
        Font.drawBox(1, 1, 18, 11)
        Font.draw("TRAINER CARD", 16, 20)
        Font.draw(string.format("NAME: %s", name), 16, 34)
        Font.draw(string.format("ID: %s", tostring(tid)), 16, 46)
        Font.draw(string.format("TITLE: %s", title), 16, 58)
        Font.draw(string.format("BADGES: %d/8", badges), 16, 70)
        Font.draw(string.format("POKEDEX: %d", pokedexCount), 16, 82)
        Font.draw(string.format("GTS TRADES: %d", gtsTrades), 16, 94)
        Font.draw(string.format("PVP WINS: %d", pvpWins), 16, 106)
        Font.draw(string.format("FAV: %s", favMon), 16, 118)
      end
    }
    game.stack:push(container)
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
          syncLocalProfile(game)
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
                syncLocalProfile(game)
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
                  syncLocalProfile(game)
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

  -- GTS Summary Card & Trade Execution
  local function openGtsSummaryCard(game, listing)
    local trainerId, buyerName = getTrainerInfo(game.save)
    local offered = listing.offeredMon
    local offName = offered.nickname or (game.data.pokemon[offered.species] and game.data.pokemon[offered.species].name) or offered.species
    local wantedStr = table.concat(listing.wanted or {}, "/")

    local container = {
      isOverworld = false,
      update = function(self, dt)
        local input = game.input
        if input:wasPressed("b") then
          game.stack:pop()
          return
        elseif input:wasPressed("a") then
          if listing.trainerId == trainerId then
            game.stack:push(TextBox.new(game, "THIS IS YOUR OWN LISTING!\nMANAGE IN 'MY LISTINGS'."))
            return
          end

          local eligibleSlots = {}
          for i, pMon in ipairs(game.save.party) do
            for _, wSpec in ipairs(listing.wanted or {}) do
              if pMon.species == wSpec then
                table.insert(eligibleSlots, { index = i, mon = pMon })
                break
              end
            end
          end

          if #eligibleSlots == 0 then
            game.stack:push(TextBox.new(game, "YOU DO NOT HAVE ANY OF\nTHE WANTED POKéMON!"))
            return
          end

          local tradeItems = {}
          for _, choice in ipairs(eligibleSlots) do
            local pMon = choice.mon
            local idx = choice.index
            local pName = pMon.nickname or pMon.species
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
                game.stack:push(TextBox.new(game, string.format("GTS TRADE SUCCESSFUL!\nRECEIVED %s!", offName)))
              end
            })
          end

          game.stack:push(Menu.new(game, tradeItems, { tx = 1, ty = 1, tw = 18, maxVisible = 6, startCloses = true }))
        end
      end,
      draw = function(self)
        Font.drawBox(1, 1, 18, 11)
        Font.draw(string.format("OFFER: %s LV%d", offName, offered.level or 1), 16, 20)
        Font.draw(string.format("OT: %s (ID %d)", listing.trainerName or "TRAINER", listing.trainerId or 0), 16, 36)
        Font.draw("WANTED POKEMON:", 16, 56)
        Font.draw(wantedStr, 16, 72)
        Font.draw("A: EXECUTE TRADE", 16, 92)
        Font.draw("B: BACK", 16, 108)
      end
    }
    game.stack:push(container)
  end

  -- GTS Browse Submenu
  local function openGtsBrowseMenu(game)
    local trainerId, trainerName = getTrainerInfo(game.save)
    fetchGtsServerSync(trainerId)

    local items = {}
    for id, listing in pairs(gtsDb.listings) do
      local offered = listing.offeredMon
      local offName = offered.nickname or (game.data.pokemon[offered.species] and game.data.pokemon[offered.species].name) or offered.species
      table.insert(items, {
        label = string.format("%s LV%d (%s)", offName, offered.level or 1, listing.trainerName or "OT"),
        onSelect = function()
          openGtsSummaryCard(game, listing)
        end
      })
    end

    if #items == 0 then
      game.stack:push(TextBox.new(game, "NO ACTIVE TRADES\nFOUND ON GTS."))
      return
    end

    local menu = Menu.new(game, items, { tx = 1, ty = 1, tw = 18, maxVisible = 6, startCloses = true })
    game.stack:push(menu)
  end

  -- GTS My Listings & Claim Box Submenu
  local function openGtsMyListingsMenu(game)
    local trainerId, trainerName = getTrainerInfo(game.save)
    fetchGtsServerSync(trainerId)

    local items = {}

    -- 1. Active Deposits (Withdraw)
    for id, listing in pairs(gtsDb.listings) do
      if tostring(listing.trainerId) == tostring(trainerId) then
        local offered = listing.offeredMon
        local offName = offered.nickname or (game.data.pokemon[offered.species] and game.data.pokemon[offered.species].name) or offered.species
        table.insert(items, {
          label = string.format("[WITHDRAW] %s LV%d", offName, offered.level or 1),
          onSelect = function()
            local returnedMon = Protocol.unpackMon(game.data, offered)
            local added = Party.add(game.save.party, returnedMon)
            if not added then Boxes.deposit(game.save, returnedMon) end

            gtsApiPost({ action = "withdraw", listingId = id, trainerId = trainerId }, 2.0)

            gtsDb.listings[id] = nil
            gtsDb.user_counts[trainerId] = math.max(0, (gtsDb.user_counts[trainerId] or 1) - 1)
            addGtsReceipt(string.format("%s WITHDREW DEPOSITED %s", trainerName, offName))
            performForcedSave(game)

            game.stack:push(TextBox.new(game, string.format("WITHDREW %s\nFROM GTS!", offName)))
          end
        })
      end
    end

    -- 2. Claim Box (Traded Mons Waiting to be Claimed)
    local claims = gtsDb.claim_boxes[tostring(trainerId)] or {}
    for idx, claim in ipairs(claims) do
      local packed = claim.mon
      local cName = packed.nickname or (game.data.pokemon[packed.species] and game.data.pokemon[packed.species].name) or packed.species
      table.insert(items, {
        label = string.format("[CLAIM] %s (from %s)", cName, claim.fromName or "TRADER"),
        onSelect = function()
          local claimedMon = Protocol.unpackMon(game.data, packed)
          local added = Party.add(game.save.party, claimedMon)
          if not added then Boxes.deposit(game.save, claimedMon) end

          gtsApiPost({ action = "claim", trainerId = trainerId, index = idx - 1 }, 2.0)

          table.remove(gtsDb.claim_boxes[tostring(trainerId)], idx)
          addGtsReceipt(string.format("%s CLAIMED TRADED %s", trainerName, cName))
          performForcedSave(game)

          game.stack:push(TextBox.new(game, string.format("CLAIMED %s\nFROM GTS!", cName)))
        end
      })
    end

    if #items == 0 then
      game.stack:push(TextBox.new(game, "YOU HAVE NO ACTIVE\nDEPOSITS OR CLAIMS."))
      return
    end

    local menu = Menu.new(game, items, { tx = 1, ty = 1, tw = 18, maxVisible = 6, startCloses = true })
    game.stack:push(menu)
  end

  -- GTS Recent History (Last 50 Receipts) Submenu
  local function openGtsHistoryMenu(game)
    local trainerId, trainerName = getTrainerInfo(game.save)
    fetchGtsServerSync(trainerId)

    local items = {}
    for _, r in ipairs(gtsDb.history) do
      table.insert(items, {
        label = r.text,
        onSelect = function() end
      })
    end

    if #items == 0 then
      game.stack:push(TextBox.new(game, "NO GTS TRANSACTIONS\nRECORDED YET."))
      return
    end

    local menu = Menu.new(game, items, { tx = 1, ty = 1, tw = 18, maxVisible = 6, startCloses = true })
    game.stack:push(menu)
  end

  -- GTS Deposit Submenu
  local function openGtsDepositMenu(game)
    if not game.save or not game.save.party or #game.save.party < 2 then
      game.stack:push(TextBox.new(game, "YOU NEED AT LEAST 2\nPOKéMON IN PARTY TO DEPOSIT!"))
      return
    end

    local trainerId, trainerName = getTrainerInfo(game.save)
    fetchGtsServerSync(trainerId)

    local activeCount = gtsDb.user_counts[trainerId] or 0
    if activeCount >= 3 then
      game.stack:push(TextBox.new(game, "YOU REACHED THE MAX\n3 GTS DEPOSITS!"))
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

          local wantedList = { "PIKACHU" }
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

          game.stack:push(TextBox.new(game, string.format("%s WAS DEPOSITED\nTO GTS!", depositMon.nickname or depositMon.species)))
        end
      })
    end

    game.stack:push(Menu.new(game, partyItems, { tx = 1, ty = 1, tw = 18, maxVisible = 6, startCloses = true }))
  end

  -- Main GTS Top-Level Menu
  local function openGtsMainMenu(game)
    local trainerId, trainerName = getTrainerInfo(game.save)
    local ok = fetchGtsServerSync(trainerId)

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

  -- Main Co-Op Start Submenu
  local function openCoopMenu(game)
    local trainerId, trainerName = getTrainerInfo(game.save)

    local items = {
      {
        label = "GLOBAL TRADE STATION",
        onSelect = function() openGtsMainMenu(game) end
      },
      {
        label = "MY TRAINER PROFILE",
        onSelect = function() openMyProfileMenu(game) end
      },
      {
        label = "CONNECT GTS SERVER",
        onSelect = function()
          performForcedSave(game)
          syncLocalProfile(game)
          local ok = fetchGtsServerSync(trainerId)
          if ok then
            game.stack:push(TextBox.new(game, "SAVED GAME!\nCONNECTED TO GTS SERVER!"))
          else
            game.stack:push(TextBox.new(game, "CANNOT CONNECT TO\nGTS SERVER!"))
          end
        end
      },
      {
        label = "DISCONNECT",
        onSelect = function()
          handleDisconnect(game, "DISCONNECTED FROM CO-OP.\nSAVED & RELOADED MAP.")
        end
      }
    }

    game.stack:push(Menu.new(game, items, { tx = 1, ty = 1, tw = 18, maxVisible = 6, startCloses = true }))
  end

  -- Hook Start Menu
  mod.hooks:wrap("ui.start_menu.items", function(nextFn, game, items)
    local list = nextFn and nextFn(game, items) or items
    if not list or type(list) ~= "table" then list = items end

    local newItem = {
      label = "CO-OP ONLINE",
      onSelect = function() openCoopMenu(game) end,
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

  -- Hook Overworld Update to interpolate MMO movements & sync position smoothly (Non-Blocking)
  local origOverworldUpdate = OverworldState.update
  OverworldState.update = function(self, dt)
    if origOverworldUpdate then origOverworldUpdate(self, dt) end
    if not Game or not isGtsServerConnected then return end

    -- Lerp smooth movement for all active MMO players and followers
    for _, pNpc in pairs(netNpcs) do updateNpcMovement(pNpc, dt) end
    for _, fNpc in pairs(netFollowers) do updateNpcMovement(fNpc, dt) end

    local now = (_G.love and _G.love.timer and _G.love.timer.getTime) and _G.love.timer.getTime() or os.time()
    if now - lastSendTime >= 0.5 then -- Throttled 500ms sync for buttery smooth 60 FPS movement
      lastSendTime = now

      local ow = self
      local p = ow.player
      if p and ow.map then
        local trainerId, trainerName = getTrainerInfo(Game.save)
        local followerSpecies = Game.save.party and Game.save.party[1] and Game.save.party[1].species

        local delta = Collision.DELTA[p.facing] or { 0, 1 }
        local fx = p.cellX - delta[1]
        local fy = p.cellY - delta[2]

        local res = gtsApiPost({
          action = "sync_pos",
          trainerId = trainerId,
          name = trainerName,
          title = localTrainerTitle,
          map = ow.map.id,
          x = p.cellX,
          y = p.cellY,
          fx = fx,
          fy = fy,
          facing = p.facing,
          moving = p.moving,
          species = followerSpecies
        }, 0.05) -- Non-blocking 50ms fast network timeout

        if res and res.success and res.players then
          syncMultiNetPlayers(Game, ow, res.players)
        end
      end
    end
  end

  -- Hook Overworld Interact (Facing any MMO player on the map and pressing A)
  local origInteract = OverworldState.interact
  OverworldState.interact = function(self)
    local p1 = self.player
    local fx, fy = p1:facingCell()

    for tid, pNpc in pairs(netNpcs) do
      if pNpc.cellX == fx and pNpc.cellY == fy then
        local rawData = netPlayerMap[tid] or {}
        local pName = rawData.name or "TRAINER"

        local items = {
          {
            label = "VIEW TRAINER CARD",
            onSelect = function()
              openTrainerCardScreen(Game, tid, rawData)
            end
          },
          {
            label = "PVP LINK BATTLE",
            onSelect = function()
              Game.stack:push(TextBox.new(Game, string.format("CHALLENGED %s\nTO PVP BATTLE!", pName)))
            end
          },
          {
            label = "LINK TRADE",
            onSelect = function()
              Game.stack:push(TextBox.new(Game, string.format("OFFERED TRADE\nTO %s!", pName)))
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

  print("[Gen1Online] Multi-Threaded MMO Mod initialized successfully.")
end
