return function(mod)
  print("[Gen1Online] Initializing Gen1Online Mod...")

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

  -- Dedicated GTS Server & Cloudflare Tunnel Configuration
  local GTS_SERVER_URL = "https://merger-create-souls-reactions.trycloudflare.com"
  local isGtsServerConnected = false

  -- Networking State
  local netSession = nil
  local isHost = false
  local roomCode = nil
  local p2Data = nil
  local p2Npc = nil
  local p2FollowerNpc = nil
  local lastSendTime = 0
  local pendingRequestStackItem = nil
  local p2PromptMenuStackItem = nil

  -- Global Trade Station (GTS) Database
  _G.GEN1ONLINE_GTS = _G.GEN1ONLINE_GTS or {
    listings = {},       -- listingId -> listing object
    user_counts = {},    -- trainerId -> active deposit count
    history = {},        -- array of last 50 trade receipts
    claim_boxes = {},    -- trainerId -> list of completed traded mons
    next_id = 1001,
  }
  local gtsDb = _G.GEN1ONLINE_GTS

  -- Universal HTTP/HTTPS Transport Helper (Supports Cloudflare Tunnels)
  local function makeHttpRequest(reqTable)
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
  local function gtsApiGet(path)
    if not ltn12 then return nil end
    local response_body = {}
    local ok, res, code, headers, status = makeHttpRequest({
      url = GTS_SERVER_URL .. path,
      method = "GET",
      sink = ltn12.sink.table(response_body),
      timeout = 3
    })
    if ok and code == 200 and #response_body > 0 then
      local str = table.concat(response_body)
      local data = Json.decode(str)
      return data
    end
    return nil
  end

  local function gtsApiPost(payload)
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
      timeout = 3
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
    local data = gtsApiGet("/gts/browse")
    if data and data.success then
      isGtsServerConnected = true
      gtsDb.listings = data.listings or {}
      gtsDb.history = data.history or {}

      if trainerId then
        local claimData = gtsApiGet("/gts/claims?trainerId=" .. tostring(trainerId))
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

  -- Utility deepcopy
  local function deepcopy(orig)
    local copy
    if type(orig) == 'table' then
      copy = {}
      for k, v in pairs(orig) do copy[k] = deepcopy(v) end
    else
      copy = orig
    end
    return copy
  end

  -- Trainer ID & Name Helper
  local function getTrainerInfo(save)
    local p = save and save.player
    if not p then return 12345, "TRAINER" end
    if not p.id then
      p.id = math.random(10000, 99999)
    end
    return p.id, p.name or "TRAINER"
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

  -- Clear P2 Human & Follower NPCs
  local function removeP2FollowerNpc(ow)
    if not ow or not p2FollowerNpc then return end
    for i, npc in ipairs(ow.npcs or {}) do
      if npc == p2FollowerNpc then
        table.remove(ow.npcs, i)
        break
      end
    end
    for j, e in ipairs(ow.entities or {}) do
      if e == p2FollowerNpc then
        table.remove(ow.entities, j)
        break
      end
    end
    p2FollowerNpc = nil
  end

  local function removeP2Npc(ow)
    if not ow then return end
    removeP2FollowerNpc(ow)
    if p2Npc then
      for i, npc in ipairs(ow.npcs or {}) do
        if npc == p2Npc then
          table.remove(ow.npcs, i)
          break
        end
      end
      for j, e in ipairs(ow.entities or {}) do
        if e == p2Npc then
          table.remove(ow.entities, j)
          break
        end
      end
      p2Npc = nil
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

  -- Disconnect Flow: Notice -> Save -> Reload Map Single Player
  local function handleDisconnect(game, reason)
    clearAllRequestUI(game)

    if netSession then
      pcall(function() netSession:close() end)
      netSession = nil
    end
    isHost = false
    roomCode = nil

    local ow = game and game.overworld
    if ow then
      removeP2Npc(ow)
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

  -- Persistent Pending Request UI (Ignores A / Z, B opens Cancel confirmation)
  local function openPendingRequestUI(game, reqType, headerText)
    closePendingRequestUI()

    local container = {
      isOverworld = false,
      update = function(self, dt)
        if not netSession or netSession.closed then
          clearAllRequestUI(game)
          handleDisconnect(game, "CONNECTION LOST!\nSAVING & RELOADING MAP...")
          return
        end

        local input = game.input
        -- B button opens explicit cancel confirmation menu
        if input:wasPressed("b") then
          local confirmItems = {
            {
              label = "YES, CANCEL",
              onSelect = function()
                if netSession then
                  netSession:send({ type = (reqType == "battle" and "link_battle_cancel" or "link_trade_cancel") })
                  if netSession.update then netSession:update() end
                end
                clearAllRequestUI(game)
                game.stack:push(TextBox.new(game, "REQUEST CANCELLED."))
              end
            },
            {
              label = "NO, KEEP WAITING",
              onSelect = function() end
            }
          }
          game.stack:push(Menu.new(game, confirmItems, { tx = 1, ty = 1, tw = 16, th = 6 }))
        end
      end,
      draw = function(self)
        Font.drawBox(1, 1, 18, 6)
        Font.draw(headerText, 16, 20)
        Font.draw("WAITING FOR P2...", 16, 36)
        Font.draw("B: CANCEL REQUEST", 16, 52)
      end
    }

    pendingRequestStackItem = container
    game.stack:push(container)
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

  -- Request full GTS database sync from peer/server
  local function requestGtsSync()
    if netSession then
      netSession:send({ type = "gts_full_sync_req" })
      if netSession.update then netSession:update() end
    end
  end

  -- ===================================================================
  -- GLOBAL TRADE STATION (GTS) SUBMENU & ENGINE
  -- ===================================================================

  -- Species Selection Submenu for Wanted Pokemon (1 to 151)
  local function openSpeciesPickerMenu(game, title, includeNone, onPicked)
    local byDex = {}
    if game.data and game.data.pokemon then
      for species, def in pairs(game.data.pokemon) do
        if def.dex then byDex[def.dex] = def end
      end
    end

    local items = {}
    if includeNone then
      table.insert(items, {
        label = "- NONE -",
        onSelect = function()
          onPicked(nil)
        end
      })
    end

    local dexSize = (game.data and game.data.constants and game.data.constants.dexSize) or 151
    for n = 1, dexSize do
      local def = byDex[n]
      if def then
        local label = string.format("#%03d %s", n, def.name or def.id)
        table.insert(items, {
          label = label,
          onSelect = function()
            onPicked(def.id)
          end
        })
      end
    end

    local menu = Menu.new(game, items, {
      tx = 1, ty = 1, tw = 18, maxVisible = 6, startCloses = true,
      onCancel = function()
        onPicked(nil)
      end
    })
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

    -- 1. Select Party Pokemon to Deposit
    local partyItems = {}
    for idx, mon in ipairs(game.save.party) do
      local monName = mon.nickname or (game.data.pokemon[mon.species] and game.data.pokemon[mon.species].name) or mon.species
      table.insert(partyItems, {
        label = string.format("%s LV%d", monName, mon.level),
        onSelect = function()
          local chosenSlot = idx
          local chosenMon = mon

          -- 2. Pick Wanted Pokemon #1
          openSpeciesPickerMenu(game, "WANTED #1", false, function(want1)
            if not want1 then return end

            -- 3. Pick Wanted Pokemon #2 (Optional)
            openSpeciesPickerMenu(game, "WANTED #2", true, function(want2)

              -- 4. Pick Wanted Pokemon #3 (Optional)
              openSpeciesPickerMenu(game, "WANTED #3", true, function(want3)

                local wantedList = { want1 }
                if want2 then table.insert(wantedList, want2) end
                if want3 then table.insert(wantedList, want3) end

                -- 5. Confirmation Screen
                local wantedStr = table.concat(wantedList, "/")
                local confirmItems = {
                  {
                    label = "CONFIRM DEPOSIT",
                    onSelect = function()
                      -- Remove mon from party
                      local depositMon = table.remove(game.save.party, chosenSlot)
                      local packedMon = Protocol.packMon(depositMon)

                      -- Send deposit payload to 24/7 GTS REST Server
                      local res = gtsApiPost({
                        action = "deposit",
                        trainerId = trainerId,
                        trainerName = trainerName,
                        offeredMon = packedMon,
                        wanted = wantedList
                      })

                      if res and res.success then
                        gtsDb.listings[res.listing.id] = res.listing
                      else
                        local listId = "GTS_" .. tostring(gtsDb.next_id)
                        gtsDb.next_id = gtsDb.next_id + 1
                        local listing = {
                          id = listId,
                          trainerId = trainerId,
                          trainerName = trainerName,
                          offeredMon = packedMon,
                          wanted = wantedList,
                          timestamp = os.time()
                        }
                        gtsDb.listings[listId] = listing
                      end

                      gtsDb.user_counts[trainerId] = (gtsDb.user_counts[trainerId] or 0) + 1
                      addGtsReceipt(string.format("%s (ID %d) DEPOSITED %s LV%d", trainerName, trainerId, depositMon.nickname or depositMon.species, depositMon.level))
                      performForcedSave(game)

                      if netSession then
                        netSession:send({ type = "gts_deposit_sync", listing = gtsDb.listings[res and res.listing and res.listing.id or "GTS_1001"] })
                        if netSession.update then netSession:update() end
                      end

                      game.stack:push(TextBox.new(game, string.format("%s WAS DEPOSITED\nTO GTS!", depositMon.nickname or depositMon.species)))
                    end
                  },
                  { label = "CANCEL", onSelect = function() end }
                }

                local confirmMenu = Menu.new(game, confirmItems, { tx = 1, ty = 1, tw = 18, maxVisible = 6, startCloses = true })
                game.stack:push(confirmMenu)
              end)
            end)
          end)
        end
      })
    end

    local partyMenu = Menu.new(game, partyItems, { tx = 1, ty = 1, tw = 18, maxVisible = 6, startCloses = true })
    game.stack:push(partyMenu)
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
          -- Check if player is owner of listing
          if listing.trainerId == trainerId then
            game.stack:push(TextBox.new(game, "THIS IS YOUR OWN LISTING!\nMANAGE IN 'MY LISTINGS'."))
            return
          end

          -- Find eligible party mons matching listing.wanted
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

          -- Select which wanted mon from party to send
          local tradeItems = {}
          for _, choice in ipairs(eligibleSlots) do
            local pMon = choice.mon
            local idx = choice.index
            local pName = pMon.nickname or pMon.species
            table.insert(tradeItems, {
              label = string.format("SEND %s LV%d", pName, pMon.level),
              onSelect = function()
                -- Execute Trade
                local sentMon = table.remove(game.save.party, idx)
                local packedSent = Protocol.packMon(sentMon)

                -- Send trade payload to 24/7 GTS REST Server
                local res = gtsApiPost({
                  action = "trade",
                  listingId = listing.id,
                  buyerId = trainerId,
                  buyerName = buyerName,
                  sentMon = packedSent
                })

                local receivedMon = Protocol.unpackMon(game.data, offered)
                local addedToParty = Party.add(game.save.party, receivedMon)
                if not addedToParty then
                  Boxes.deposit(game.save, receivedMon)
                end

                -- Add sent mon to seller's claim box locally
                gtsDb.claim_boxes[listing.trainerId] = gtsDb.claim_boxes[listing.trainerId] or {}
                table.insert(gtsDb.claim_boxes[listing.trainerId], {
                  mon = packedSent,
                  fromName = buyerName,
                  fromId = trainerId,
                  originalOffered = offName
                })

                -- Remove listing & decrement seller's count
                gtsDb.listings[listing.id] = nil
                gtsDb.user_counts[listing.trainerId] = math.max(0, (gtsDb.user_counts[listing.trainerId] or 1) - 1)

                addGtsReceipt(string.format("%s TRADED %s TO %s FOR %s", buyerName, sentMon.nickname or sentMon.species, listing.trainerName, offName))
                performForcedSave(game)

                if netSession then
                  netSession:send({ type = "gts_trade_sync", listingId = listing.id, buyerId = trainerId, buyerName = buyerName, sentMon = packedSent })
                  if netSession.update then netSession:update() end
                end

                local Sound = require("src.core.Sound")
                pcall(function() Sound.play(game.data, "Trade_Machine") end)

                game.stack:pop() -- Pop summary container
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
    requestGtsSync()

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
    requestGtsSync()

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

            gtsApiPost({ action = "withdraw", listingId = id, trainerId = trainerId })

            gtsDb.listings[id] = nil
            gtsDb.user_counts[trainerId] = math.max(0, (gtsDb.user_counts[trainerId] or 1) - 1)
            addGtsReceipt(string.format("%s WITHDREW DEPOSITED %s", trainerName, offName))
            performForcedSave(game)

            if netSession then
              netSession:send({ type = "gts_withdraw_sync", listingId = id, trainerId = trainerId })
              if netSession.update then netSession:update() end
            end

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

          gtsApiPost({ action = "claim", trainerId = trainerId, index = idx - 1 })

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
    requestGtsSync()

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

  -- Main GTS Top-Level Menu
  local function openGtsMainMenu(game)
    local trainerId, trainerName = getTrainerInfo(game.save)
    local ok = fetchGtsServerSync(trainerId)

    local items = {
      {
        label = "BROWSE TRADES",
        onSelect = function()
          openGtsBrowseMenu(game)
        end
      },
      {
        label = "DEPOSIT POKEMON",
        onSelect = function()
          openGtsDepositMenu(game)
        end
      },
      {
        label = "MY LISTINGS/WITHDRAW",
        onSelect = function()
          openGtsMyListingsMenu(game)
        end
      },
      {
        label = "RECENT HISTORY (50)",
        onSelect = function()
          openGtsHistoryMenu(game)
        end
      },
      { label = "EXIT", onSelect = function() end }
    }

    local menu = Menu.new(game, items, { tx = 1, ty = 1, tw = 18, maxVisible = 6, startCloses = true })
    game.stack:push(menu)
  end

  -- Find next immediate free walkable cell for same-tile spawn nudge
  local function findAdjacentFreeTile(ow, cx, cy)
    local dirs = { { 0, 1 }, { 1, 0 }, { 0, -1 }, { -1, 0 } }
    local map = ow.map
    for _, d in ipairs(dirs) do
      local tx, ty = cx + d[1], cy + d[2]
      if map and map:inBounds(tx, ty) and (map:isWalkableCell(tx, ty) or map:isGrassCell(tx, ty)) then
        if not Collision.occupied(ow.entities, tx, ty, nil) then
          return tx, ty
        end
      end
    end
    return cx + 1, cy
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

  -- Sync P2 Human Player + Follower Pokemon on Overworld Map
  local function syncP2Npc(game, ow, data)
    if not ow or not ow.map or not data then
      removeP2Npc(ow)
      return
    end

    if data.map ~= ow.map.id then
      removeP2Npc(ow)
      return
    end

    -- Same-Tile Spawn Nudge Check
    local p1 = ow.player
    if p1 and not p2Npc then
      if p1.cellX == data.x and p1.cellY == data.y then
        local nx, ny = findAdjacentFreeTile(ow, data.x, data.y)
        data.x, data.y = nx, ny
      end
    end

    -- 1. Sync Human Player 2 Trainer Avatar (SPRITE_RED, solid physical collision passable = false)
    if not p2Npc then
      p2Npc = NPC.new(game.data, ow.map.id, {
        index = 298,
        name = data.name or "PLAYER 2",
        sprite = "SPRITE_RED",
        movement = "STAY",
        range = "NONE",
        x = data.x or 5,
        y = data.y or 5,
      })
      p2Npc.isCoopPlayer = true
      p2Npc.passable = false
      p2Npc.px = (data.x or 5) * 16
      p2Npc.py = (data.y or 5) * 16
      p2Npc.targetPx = p2Npc.px
      p2Npc.targetPy = p2Npc.py
      p2Npc.update = function(self, dt, map, entities) end
      table.insert(ow.npcs, p2Npc)
      table.insert(ow.entities, p2Npc)
    end

    p2Npc.targetPx = (data.x or 5) * 16
    p2Npc.targetPy = (data.y or 5) * 16
    p2Npc.facing = data.facing or "down"

    -- 2. Sync Player 2 Follower Pokemon (solid physical collision passable = false)
    if data.species then
      local spriteId = "SPRITE_WILD_" .. tostring(data.species)
      local spriteDef = game.data and game.data.sprites and game.data.sprites[spriteId]
      if spriteDef then
        if not p2FollowerNpc then
          p2FollowerNpc = NPC.new(game.data, ow.map.id, {
            index = 299,
            name = tostring(data.species),
            sprite = spriteId,
            movement = "STAY",
            range = "NONE",
            x = data.fx or (data.x or 5),
            y = data.fy or (data.y or 5),
          })
          p2FollowerNpc.spriteId = spriteId
          p2FollowerNpc.isCoopFollower = true
          p2FollowerNpc.passable = false
          p2FollowerNpc.px = (data.fx or (data.x or 5)) * 16
          p2FollowerNpc.py = (data.fy or (data.y or 5)) * 16
          p2FollowerNpc.targetPx = p2FollowerNpc.px
          p2FollowerNpc.targetPy = p2FollowerNpc.py
          p2FollowerNpc.update = function(self, dt, map, entities) end
          table.insert(ow.npcs, p2FollowerNpc)
          table.insert(ow.entities, p2FollowerNpc)
        elseif p2FollowerNpc.spriteId ~= spriteId then
          p2FollowerNpc.spriteId = spriteId
          p2FollowerNpc.sprite = SpriteRenderer.new(spriteDef, p2FollowerNpc.id)
        end

        p2FollowerNpc.targetPx = (data.fx or p2Npc.cellX) * 16
        p2FollowerNpc.targetPy = (data.fy or p2Npc.cellY) * 16
        p2FollowerNpc.facing = data.facing or "down"
      else
        removeP2FollowerNpc(ow)
      end
    else
      removeP2FollowerNpc(ow)
    end
  end

  -- Start Recomp Online Link Battle
  local function startOnlineLinkBattle(game, isHostRole, seed, p2PartyPacked)
    clearAllRequestUI(game)

    if not game or not netSession then return end

    healParty(game)

    local myPartyPacked = Protocol.packParty(game.save.party)
    local opts = {
      myParty = myPartyPacked,
      theirParty = p2PartyPacked or myPartyPacked,
      theirName = (p2Data and p2Data.name) or "PLAYER 2",
      seed = seed or 12345,
      verdict = "full",
      strict = false,
      forceLevel = nil,
      keepNetOpen = true,
    }

    local battle, why = nil, nil
    if isHostRole then
      battle, why = LinkBattle.newHost(game, netSession, opts)
    else
      battle, why = LinkBattle.newGuest(game, netSession, opts)
    end

    if battle then
      game.stack:push(battle)
    else
      game.stack:push(TextBox.new(game, "COULD NOT START LINK BATTLE!\n" .. tostring(why or "")))
    end
  end

  -- Start Recomp Online Link Trade
  local function startOnlineLinkTrade(game, isHostRole)
    clearAllRequestUI(game)

    if not game or not netSession then return end

    local tradeSession = Protocol.TradeSession.new(game.data, game.save.party, {
      subset = false,
      strict = false,
      peerName = (p2Data and p2Data.name) or "PLAYER 2",
    })

    netSession:send(tradeSession:opening())

    local container = {
      isOverworld = false,
      trade = tradeSession,
      index = 1,
      update = function(self, dt)
        if not netSession then
          game.stack:pop()
          return
        end
        netSession:update()
        for _, msg in ipairs(netSession:poll()) do
          local reply = self.trade:handle(msg)
          if reply then netSession:send(reply) end
        end

        local t = self.trade
        if t.stage == "cancelled" then
          game.stack:pop()
          game.stack:push(TextBox.new(game, t.error or "THE TRADE WAS CANCELLED."))
          return
        end

        if t.stage == "done" then
          game.stack:pop()
          local sent = t.party[t.myPick]
          local received, evoTo = t:apply(game)
          performForcedSave(game)

          local Sound = require("src.core.Sound")
          local Screens = require("src.ui.Screens")
          pcall(function() Sound.play(game.data, "Trade_Machine") end)

          Screens.push(game, "TradeAnim", {
            sent = sent,
            received = received,
            enemyName = (p2Data and p2Data.name) or "TRAINER",
            playerOt = game.save.player.name,
            playerOtId = sent.otId or game.save.player.id,
            enemyOtId = received.otId,
            onDone = function()
              local recName = received.nickname or (game.data.pokemon[received.species] and game.data.pokemon[received.species].name) or received.species
              game.stack:push(TextBox.new(game, string.format("Trade completed!\n%s received\n%s!", game.save.player.name, recName), function()
                if evoTo then
                  local Evolution = require("src.pokemon.Evolution")
                  Evolution.evolve(game, received, evoTo, function() performForcedSave(game) end, "TRADE")
                end
              end))
            end
          })
          return
        end

        -- Handle D-Pad input during trade selection UI
        local input = game.input
        if t.stage == "pick" or t.stage == "init" then
          if input:wasPressed("up") then
            self.index = math.max(1, self.index - 1)
          elseif input:wasPressed("down") then
            self.index = math.min(#game.save.party, self.index + 1)
          elseif input:wasPressed("a") then
            if t:canPick(self.index) then
              t:pick(self.index)
              netSession:send(t:wireIndex(self.index))
            end
          elseif input:wasPressed("b") then
            t.stage = "cancelled"
            netSession:send({ type = "cancel" })
          end
        elseif t.stage == "confirm" then
          if input:wasPressed("a") then
            t:confirm(true)
            netSession:send({ type = "confirm", ok = true })
          elseif input:wasPressed("b") then
            t:confirm(false)
            netSession:send({ type = "confirm", ok = false })
          end
        end
      end,
      draw = function(self)
        local t = self.trade
        Font.drawBox(1, 1, 18, 11)
        Font.draw(string.format("TRADE WITH %s", (p2Data and p2Data.name) or "P2"), 16, 20)

        if t.stage == "pick" or t.stage == "init" then
          Font.draw("SELECT POKEMON:", 16, 36)
          for i, mon in ipairs(game.save.party) do
            local name = mon.nickname or (game.data.pokemon[mon.species] and game.data.pokemon[mon.species].name) or mon.species
            local y = 48 + (i - 1) * 12
            Font.draw(string.format("%s LV%d", name, mon.level), 28, y)
            if i == self.index then
              Font.drawCode(0xEE, 16, y)
            end
          end
          Font.draw("A: SELECT  B: CANCEL", 16, 120)
        elseif t.stage == "confirm" then
          local myMon = game.save.party[t.myPick]
          local myName = myMon and (myMon.nickname or myMon.species) or "MON"
          Font.draw(string.format("TRADE %s?", myName), 16, 44)
          Font.draw("A: CONFIRM TRADE", 16, 68)
          Font.draw("B: CANCEL TRADE", 16, 84)
        else
          Font.draw("WAITING FOR P2...", 16, 60)
        end
      end
    }

    game.stack:push(container)
  end

  -- Network Poll & Packet Dispatcher (Must run continuously on love.update)
  local function pollNetwork(game)
    if not netSession then return end
    netSession:update()

    -- Room Code Assignment for Online Host
    if isHost and not roomCode and netSession.code then
      roomCode = netSession.code
    end

    -- Detect lost connection
    if netSession.closed then
      handleDisconnect(game, "CONNECTION LOST!\nSAVING & RELOADING MAP...")
      return
    end

    local msgs = netSession:poll()
    for _, msg in ipairs(msgs or {}) do
      if msg.type == "pos" then
        p2Data = msg
        local ow = game and game.overworld
        if ow then syncP2Npc(game, ow, p2Data) end

      elseif msg.type == "link_battle_req" then
        local items = {
          {
            label = "ACCEPT BATTLE",
            onSelect = function()
              clearAllRequestUI(game)
              local seed = math.random(1, 1000000)
              healParty(game)
              local myPacked = Protocol.packParty(game.save.party)
              netSession:send({ type = "link_battle_accept", seed = seed, party = myPacked })
              netSession:update()
              startOnlineLinkBattle(game, false, seed, msg.party)
            end
          },
          {
            label = "DECLINE",
            onSelect = function()
              clearAllRequestUI(game)
              netSession:send({ type = "link_battle_decline" })
              netSession:update()
            end
          }
        }
        local m = Menu.new(game, items, { tx = 1, ty = 1, tw = 16, th = 6 })
        p2PromptMenuStackItem = m
        game.stack:push(m)

      elseif msg.type == "link_battle_accept" then
        startOnlineLinkBattle(game, true, msg.seed or 12345, msg.party)

      elseif msg.type == "link_battle_decline" then
        clearAllRequestUI(game)
        game.stack:push(TextBox.new(game, "PLAYER 2 DECLINED THE BATTLE."))

      elseif msg.type == "link_battle_cancel" then
        clearAllRequestUI(game)
        game.stack:push(TextBox.new(game, "PLAYER 1 CANCELLED THE BATTLE."))

      elseif msg.type == "link_trade_req" then
        if not game.save or not game.save.party or #game.save.party < 2 then
          netSession:send({ type = "link_trade_decline" })
          netSession:update()
          game.stack:push(TextBox.new(game, "PLAYER 2 OFFERED A TRADE,\nBUT YOU NEED 2 POKéMON!"))
        else
          local items = {
            {
              label = "ACCEPT TRADE",
              onSelect = function()
                clearAllRequestUI(game)
                netSession:send({ type = "link_trade_accept" })
                netSession:update()
                startOnlineLinkTrade(game, false)
              end
            },
            {
              label = "DECLINE",
              onSelect = function()
                clearAllRequestUI(game)
                netSession:send({ type = "link_trade_decline" })
                netSession:update()
              end
            }
          }
          local m = Menu.new(game, items, { tx = 1, ty = 1, tw = 16, th = 6 })
          p2PromptMenuStackItem = m
          game.stack:push(m)
        end

      elseif msg.type == "link_trade_accept" then
        startOnlineLinkTrade(game, true)

      elseif msg.type == "link_trade_decline" then
        clearAllRequestUI(game)
        game.stack:push(TextBox.new(game, "PLAYER 2 DECLINED THE TRADE."))

      elseif msg.type == "link_trade_cancel" then
        clearAllRequestUI(game)
        game.stack:push(TextBox.new(game, "PLAYER 1 CANCELLED THE TRADE."))

      elseif msg.type == "gts_full_sync_req" then
        netSession:send({
          type = "gts_full_sync_resp",
          listings = gtsDb.listings,
          history = gtsDb.history,
          user_counts = gtsDb.user_counts,
          claim_boxes = gtsDb.claim_boxes
        })
        if netSession.update then netSession:update() end

      elseif msg.type == "gts_full_sync_resp" then
        if msg.listings then
          for id, lst in pairs(msg.listings) do
            gtsDb.listings[id] = lst
          end
        end
        if msg.history then gtsDb.history = msg.history end
        if msg.user_counts then gtsDb.user_counts = msg.user_counts end
        if msg.claim_boxes then gtsDb.claim_boxes = msg.claim_boxes end

      elseif msg.type == "gts_deposit_sync" then
        if msg.listing and msg.listing.id then
          gtsDb.listings[msg.listing.id] = msg.listing
          gtsDb.user_counts[msg.listing.trainerId] = (gtsDb.user_counts[msg.listing.trainerId] or 0) + 1
        end

      elseif msg.type == "gts_withdraw_sync" then
        if msg.listingId then
          gtsDb.listings[msg.listingId] = nil
          if msg.trainerId then
            gtsDb.user_counts[msg.trainerId] = math.max(0, (gtsDb.user_counts[msg.trainerId] or 1) - 1)
          end
        end

      elseif msg.type == "gts_trade_sync" then
        if msg.listingId and gtsDb.listings[msg.listingId] then
          local lst = gtsDb.listings[msg.listingId]
          gtsDb.claim_boxes[lst.trainerId] = gtsDb.claim_boxes[lst.trainerId] or {}
          table.insert(gtsDb.claim_boxes[lst.trainerId], {
            mon = msg.sentMon,
            fromName = msg.buyerName,
            fromId = msg.buyerId
          })
          gtsDb.listings[msg.listingId] = nil
          gtsDb.user_counts[lst.trainerId] = math.max(0, (gtsDb.user_counts[lst.trainerId] or 1) - 1)
        end
      end
    end
  end

  -- Hook love.update safely so pollNetwork ALWAYS runs continuously regardless of UI stack state
  if _G.love then
    local origLoveUpdate = _G.love.update
    _G.love.update = function(dt)
      if origLoveUpdate then origLoveUpdate(dt) end
      if Game then
        pollNetwork(Game)
      end
    end
  end

  -- Broadcast local player position + trailing follower coordinates
  local function sendPosition(game, ow)
    if not netSession or not ow or not ow.player or not ow.map then return end

    local p = ow.player
    local followerSpecies = nil
    if game.save and game.save.party and game.save.party[1] then
      followerSpecies = game.save.party[1].species
    end

    local delta = Collision.DELTA[p.facing] or { 0, 1 }
    local fx = p.cellX - delta[1]
    local fy = p.cellY - delta[2]

    netSession:send({
      type = "pos",
      map = ow.map.id,
      x = p.cellX,
      y = p.cellY,
      fx = fx,
      fy = fy,
      facing = p.facing,
      moving = p.moving,
      species = followerSpecies,
      name = (game.save and game.save.player and game.save.player.name) or "PLAYER",
    })
  end

  -- Code Entry Screen for Joining Online Server
  local function openCodeEntryMenu(game)
    local entry = CodeEntry.new()
    local container = {
      isOverworld = false,
      update = function(self, dt)
        local input = game.input
        if input:wasPressed("b") then
          game.stack:pop()
          return
        elseif input:wasPressed("up") then
          CodeEntry.up(entry)
        elseif input:wasPressed("down") then
          CodeEntry.down(entry)
        elseif input:wasPressed("left") then
          CodeEntry.left(entry)
        elseif input:wasPressed("right") then
          CodeEntry.right(entry)
        elseif input:wasPressed("a") then
          local code = CodeEntry.text(entry)
          performForcedSave(game)
          netSession = Net.new()
          if netSession:joinOnline(nil, code) then
            isHost = false
            roomCode = code
            requestGtsSync()
            game.stack:pop()
            game.stack:push(TextBox.new(game, string.format("SAVED GAME!\nJOINED ROOM: %s", code)))
          else
            game.stack:push(TextBox.new(game, "FAILED TO JOIN ROOM!"))
          end
        end
      end,
      draw = function(self)
        Font.drawBox(1, 2, 18, 10)
        Font.draw("ENTER ROOM CODE:", 24, 24)
        for i = 1, CodeEntry.LENGTH do
          local x = 32 + (i - 1) * 16
          local ch = CodeEntry.CHARSET:sub(entry.chars[i], entry.chars[i])
          Font.draw(ch, x, 48)
          if i == entry.pos then
            Font.drawCode(0xEE, x, 60)
          end
        end
        Font.draw("DPAD: SCRUB  A: JOIN", 16, 80)
      end
    }
    game.stack:push(container)
  end

  -- 12-Digit IP Entry Screen for Joining LAN Host
  local function openLanEntryMenu(game)
    local addr = { 1, 9, 2, 1, 6, 8, 0, 0, 1, 0, 0, 1 }
    local addrPos = 1
    local container = {
      isOverworld = false,
      update = function(self, dt)
        local input = game.input
        if input:wasPressed("b") then
          game.stack:pop()
          return
        elseif input:wasPressed("up") then
          addr[addrPos] = (addr[addrPos] + 1) % 10
        elseif input:wasPressed("down") then
          addr[addrPos] = (addr[addrPos] - 1) % 10
        elseif input:wasPressed("left") then
          addrPos = math.max(1, addrPos - 1)
        elseif input:wasPressed("right") then
          addrPos = math.min(12, addrPos + 1)
        elseif input:wasPressed("a") then
          local octets = {}
          for i = 1, 4 do
            local base = (i - 1) * 3
            octets[i] = math.min(255, addr[base + 1] * 100 + addr[base + 2] * 10 + addr[base + 3])
          end
          local ipStr = table.concat(octets, ".")
          local target = ipStr .. ":7777"
          performForcedSave(game)
          netSession = Net.new()
          if netSession:join(target) then
            isHost = false
            requestGtsSync()
            game.stack:pop()
            game.stack:push(TextBox.new(game, string.format("SAVED GAME!\nJOINED LAN: %s", target)))
          else
            game.stack:push(TextBox.new(game, "LAN JOIN FAILED!"))
          end
        end
      end,
      draw = function(self)
        Font.drawBox(1, 1, 18, 11)
        Font.draw("ENTER HOST LAN IP:", 16, 20)
        for i = 1, 12 do
          local octet = math.floor((i - 1) / 3)
          local x = 16 + (i - 1) * 8 + octet * 8
          Font.draw(tostring(addr[i]), x, 44)
          if i == addrPos then
            Font.drawCode(0xEE, x, 56)
          end
        end
        for octet = 1, 3 do
          Font.draw(".", 16 + octet * 32 - 8, 44)
        end
        Font.draw("PORT: 7777", 16, 72)
        Font.draw("DPAD: SCRUB  A: JOIN", 8, 88)
      end
    }
    game.stack:push(container)
  end

  -- Main Co-Op Start Submenu
  local function openCoopMenu(game)
    local trainerId, trainerName = getTrainerInfo(game.save)

    local items = {
      {
        label = "GLOBAL TRADE STATION",
        onSelect = function()
          openGtsMainMenu(game)
        end
      },
      {
        label = "CONNECT GTS SERVER",
        onSelect = function()
          performForcedSave(game)
          local ok = fetchGtsServerSync(trainerId)
          if ok then
            game.stack:push(TextBox.new(game, "SAVED GAME!\nCONNECTED TO GTS SERVER!"))
          else
            game.stack:push(TextBox.new(game, "CANNOT CONNECT TO\nGTS SERVER!"))
          end
        end
      },
      {
        label = "HOST SERVER",
        onSelect = function()
          performForcedSave(game)
          netSession = Net.new()
          if netSession:hostOnline() then
            isHost = true
            requestGtsSync()
            game.stack:push(TextBox.new(game, "SAVED GAME!\nHOSTING SERVER..."))
          else
            game.stack:push(TextBox.new(game, "CANNOT CONNECT TO SERVER!"))
          end
        end
      },
      {
        label = "JOIN SERVER",
        onSelect = function()
          openCodeEntryMenu(game)
        end
      },
      {
        label = "HOST LAN",
        onSelect = function()
          performForcedSave(game)
          netSession = Net.new()
          if netSession:host(7777) then
            isHost = true
            requestGtsSync()
            local ip = netSession.address or "127.0.0.1:7777"
            game.stack:push(TextBox.new(game, string.format("SAVED GAME!\nHOSTING LAN: %s", ip)))
          else
            game.stack:push(TextBox.new(game, "LAN HOST FAILED!"))
          end
        end
      },
      {
        label = "JOIN LAN",
        onSelect = function()
          openLanEntryMenu(game)
        end
      },
      {
        label = "DISCONNECT",
        onSelect = function()
          handleDisconnect(game, "DISCONNECTED FROM CO-OP.\nSAVED & RELOADED MAP.")
        end
      }
    }

    local menu = Menu.new(game, items, {
      tx = 1, ty = 1, tw = 18, maxVisible = 6, startCloses = true
    })
    game.stack:push(menu)
  end

  -- Hook Start Menu
  mod.hooks:wrap("ui.start_menu.items", function(nextFn, game, items)
    local list = nextFn and nextFn(game, items) or items
    if not list or type(list) ~= "table" then list = items end

    local newItem = {
      label = "CO-OP ONLINE",
      onSelect = function()
        openCoopMenu(game)
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

  -- Hook Overworld Update to interpolate P2 movement & send position
  local origOverworldUpdate = OverworldState.update
  OverworldState.update = function(self, dt)
    if origOverworldUpdate then origOverworldUpdate(self, dt) end
    if not Game then return end

    -- Smooth linear interpolation and leg walking animation for P2 Trainer and Follower
    if p2Npc then updateNpcMovement(p2Npc, dt) end
    if p2FollowerNpc then updateNpcMovement(p2FollowerNpc, dt) end

    local now = (_G.love and _G.love.timer and _G.love.timer.getTime) and _G.love.timer.getTime() or os.time()
    if now - lastSendTime >= 0.05 then
      lastSendTime = now
      sendPosition(Game, self)
    end
  end

  -- Hook Overworld Interact (Facing P2 and pressing A)
  local origInteract = OverworldState.interact
  OverworldState.interact = function(self)
    if netSession and p2Npc then
      local p1 = self.player
      local fx, fy = p1:facingCell()
      if p2Npc.cellX == fx and p2Npc.cellY == fy then
        local items = {
          {
            label = "PVP LINK BATTLE",
            onSelect = function()
              healParty(Game)
              local myPacked = Protocol.packParty(Game.save.party)
              netSession:send({ type = "link_battle_req", party = myPacked })
              if netSession.update then netSession:update() end
              openPendingRequestUI(Game, "battle", "CHALLENGED P2 TO BATTLE!")
            end
          },
          {
            label = "LINK TRADE",
            onSelect = function()
              if not Game.save or not Game.save.party or #Game.save.party < 2 then
                Game.stack:push(TextBox.new(Game, "You need at least 2\nPOKéMON to trade!"))
                return
              end
              netSession:send({ type = "link_trade_req" })
              if netSession.update then netSession:update() end
              openPendingRequestUI(Game, "trade", "OFFERED TRADE TO P2!")
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

  -- HUD Status Overlay for Room Code / Pairing State (Clean Game Boy Box Frame)
  local origOverworldDrawUI = OverworldState.drawUI
  OverworldState.drawUI = function(self)
    if origOverworldDrawUI then origOverworldDrawUI(self) end

    if netSession then
      if _G.love and _G.love.graphics then
        _G.love.graphics.setColor(1, 1, 1, 1)
      end
      Font.drawBox(10, 0, 10, 3)
      if roomCode then
        Font.draw("ROOM", 88, 4)
        Font.draw(roomCode, 88, 12)
      elseif netSession.paired then
        Font.draw("CO-OP", 88, 4)
        Font.draw("ONLINE", 88, 12)
      else
        Font.draw("CO-OP", 88, 4)
        Font.draw("CONNECTING", 88, 12)
      end
    end
  end

  print("[Gen1Online] Mod initialized successfully.")
end
