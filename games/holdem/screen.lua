return function(ctx)
  local mod, Rules, View, CardView = ctx.mod, ctx.rules, ctx.view, ctx.cardView
  local bets, coinCap = ctx.bets, ctx.coinCap
  local Screen = { isOpaque = true }
  Screen.__index = Screen

  local TABLE_TIERS = {
    { id = "table_10", label = "ROOKIE LOUNGE", minBet = 10, buyIn = 100 },
    { id = "table_50", label = "CASINO LOUNGE", minBet = 50, buyIn = 500 },
    { id = "table_100", label = "HIGH ROLLER", minBet = 100, buyIn = 1000 },
    { id = "table_500", label = "CHAMPION TABLE", minBet = 500, buyIn = 5000 },
  }

  function Screen.new(game, opts)
    local isOnlineCapable = (ctx.isServerConnected and ctx.isServerConnected()) or false
    return setmetatable({
      game = game,
      onClose = opts and opts.onClose,
      mode = isOnlineCapable and "select_mode" or "solo",
      modeIndex = 1,
      tableTierIndex = 2,
      phase = "bet",
      betIndex = 1,
      actionIndex = 1,
      settled = false,
      -- Online multiplayer fields
      onlineTableId = "table_50",
      onlineState = nil,
      onlineActionIndex = 1,
      onlineRaiseAmount = 50,
      onlinePollTimer = 0,
      onlineLastActionMsg = nil,
      onlineNotice = nil,
      onlineJoined = false,
    }, Screen)
  end

  function Screen:close()
    if self.mode == "online" and self.onlineJoined then
      self:leaveOnlineTable()
    end
    ctx.close(self.game, self)
    if self.onClose then self.onClose() end
  end

  function Screen:sgbPalettes()
    return { require("src.render.PaletteFX").trueColorZone(0, 0, 19, 17) }
  end

  -- =========================================================================
  -- SOLO POKER ENGINE (Against House Dealer)
  -- =========================================================================
  function Screen:actions()
    if not self.round or self.round.state ~= "playing" then return {} end
    local base = self.round.start
    if self.round.phase == "preflop" then
      return {
        { label = "CHECK", kind = "check", enabled = true },
        { label = "BET 3X", kind = "bet", multiplier = 3,
          enabled = ctx.coins(self.game) >= base * 3 },
        { label = "BET 4X", kind = "bet", multiplier = 4,
          enabled = ctx.coins(self.game) >= base * 4 },
      }
    elseif self.round.phase == "flop" then
      return {
        { label = "CHECK", kind = "check", enabled = true },
        { label = "BET 2X", kind = "bet", multiplier = 2,
          enabled = ctx.coins(self.game) >= base * 2 },
      }
    end
    return {
      { label = "CHECK", kind = "check", enabled = true },
      { label = "BET 1X", kind = "bet", multiplier = 1,
        enabled = ctx.coins(self.game) >= base },
    }
  end

  function Screen:deal()
    local startingBet = bets[self.betIndex]
    if ctx.coins(self.game) < startingBet then
      self.notice = ("NEED %d COINS"):format(startingBet)
      return
    end
    self.notice = nil
    self.game.save.coins = ctx.coins(self.game) - startingBet
    self.round = Rules.newRound(startingBet, Rules.newDeck(function(n)
      return math.random(1, n)
    end))
    self.phase, self.actionIndex, self.settled = "play", 1, false
    ctx.play(self.game, "Slots_New_Spin")
  end

  function Screen:recordRound()
    if self.settled or not self.round or self.round.state ~= "done" then return end
    self.settled = true
    self.game.save.coins = math.min(coinCap, ctx.coins(self.game) + self.round.payout)
    mod.save:set("holdem_hands_played", mod.save:get("holdem_hands_played", 0) + 1)
    if self.round.result == "win" then
      mod.save:set("holdem_hands_won", mod.save:get("holdem_hands_won", 0) + 1)
    end
    if self.round.playerEval and self.round.playerEval.name == "ROYAL FLUSH" then
      mod.save:set("holdem_royals", mod.save:get("holdem_royals", 0) + 1)
    end
    self.phase = "result"
    ctx.play(self.game, self.round.result == "win" and "Slots_Reward" or "Slots_Stop_Wheel")
  end

  function Screen:moveAction(direction)
    local actions = self:actions()
    if #actions == 0 then return end
    local nextIndex = self.actionIndex
    repeat nextIndex = ((nextIndex - 1 + direction) % #actions) + 1
    until actions[nextIndex].enabled ~= false or nextIndex == self.actionIndex
    self.actionIndex = nextIndex
  end

  function Screen:chooseAction(index)
    local action = self:actions()[index or self.actionIndex]
    if not action or action.enabled == false then
      self.notice = "NOT ENOUGH COINS"
      return
    end
    self.notice = nil
    if action.kind == "check" then
      Rules.check(self.round)
    else
      local wager = self.round.start * action.multiplier
      self.game.save.coins = ctx.coins(self.game) - wager
      Rules.bet(self.round, action.multiplier)
    end
    if self.round.state == "playing" then
      self.actionIndex = 1
      ctx.play(self.game, "Slots_Stop_Wheel")
      return
    end
    self:recordRound()
  end

  -- =========================================================================
  -- ONLINE MULTIPLAYER TEXAS HOLD'EM ENGINE
  -- =========================================================================
  function Screen:joinOnlineTable(tierIndex)
    local tier = TABLE_TIERS[tierIndex or self.tableTierIndex]
    self.onlineTableId = tier.id
    local myTid, myName = "12345", "RED"
    if ctx.getTrainerInfo and self.game.save then
      myTid, myName = ctx.getTrainerInfo(self.game.save)
    end

    local buyIn = math.min(ctx.coins(self.game), tier.buyIn)
    if buyIn < tier.minBet then
      self.onlineNotice = string.format("NEED %d COINS TO JOIN!", tier.minBet)
      return
    end

    self.game.save.coins = ctx.coins(self.game) - buyIn

    if ctx.gtsApiPost then
      local res = ctx.gtsApiPost({
        action = "holdem_join",
        trainerId = myTid,
        name = myName,
        tableId = self.onlineTableId,
        buyIn = buyIn
      }, 2.0)
      if res and res.success then
        self.onlineJoined = true
        self.onlineState = res.state
        self.mode = "online"
        self.onlinePollTimer = 0
        ctx.play(self.game, "Slots_New_Spin")
      else
        self.game.save.coins = ctx.coins(self.game) + buyIn
        self.onlineNotice = (res and res.error) or "COULD NOT JOIN TABLE"
      end
    end
  end

  function Screen:leaveOnlineTable()
    if not self.onlineJoined then return end
    local myTid = "12345"
    if ctx.getTrainerInfo and self.game.save then
      myTid = ctx.getTrainerInfo(self.game.save)
    end
    if ctx.gtsApiPost then
      local res = ctx.gtsApiPost({
        action = "holdem_leave",
        trainerId = myTid,
        tableId = self.onlineTableId
      }, 1.5)
      if res and res.chips and res.chips > 0 then
        self.game.save.coins = math.min(coinCap, ctx.coins(self.game) + res.chips)
      end
    end
    self.onlineJoined = false
    self.mode = "select_mode"
  end

  function Screen:pollOnlineState()
    if not self.onlineJoined or not ctx.gtsApiGet then return end
    local myTid = "12345"
    if ctx.getTrainerInfo and self.game.save then
      myTid = ctx.getTrainerInfo(self.game.save)
    end
    local st = ctx.gtsApiGet(string.format("/holdem/state?trainerId=%s&tableId=%s", tostring(myTid), tostring(self.onlineTableId)), 1.5)
    if st and st.success then
      self.onlineState = st
      if st.allowedActions and #st.allowedActions > 0 then
        if self.onlineActionIndex > #st.allowedActions then
          self.onlineActionIndex = 1
        end
      end
    end
  end

  function Screen:sendOnlineAction(actionType, amount)
    if not self.onlineJoined or not ctx.gtsApiPost then return end
    local myTid = "12345"
    if ctx.getTrainerInfo and self.game.save then
      myTid = ctx.getTrainerInfo(self.game.save)
    end
    local res = ctx.gtsApiPost({
      action = "holdem_action",
      trainerId = myTid,
      tableId = self.onlineTableId,
      holdemAction = actionType,
      amount = amount or 0
    }, 1.5)
    if res and res.success then
      self.onlineState = res.state
      ctx.play(self.game, "Press_AB")
    else
      self.onlineNotice = (res and res.message) or "ACTION FAILED"
    end
  end

  -- =========================================================================
  -- INPUT UPDATE
  -- =========================================================================
  function Screen:update(dt)
    local input = self.game.input

    if self.mode == "select_mode" then
      if input:wasPressed("up") or input:wasPressed("left") then
        self.modeIndex = (self.modeIndex == 1) and 2 or 1
        ctx.play(self.game, "Press_AB")
      elseif input:wasPressed("down") or input:wasPressed("right") then
        self.modeIndex = (self.modeIndex == 1) and 2 or 1
        ctx.play(self.game, "Press_AB")
      elseif input:wasPressed("a") then
        if self.modeIndex == 1 then
          self.mode = "solo"
          self.phase = "bet"
          ctx.play(self.game, "Press_AB")
        else
          self.mode = "select_table"
          ctx.play(self.game, "Press_AB")
        end
      elseif input:wasPressed("b") then
        self:close()
      end

    elseif self.mode == "select_table" then
      if input:wasPressed("up") or input:wasPressed("left") then
        self.tableTierIndex = (self.tableTierIndex > 1) and self.tableTierIndex - 1 or #TABLE_TIERS
        ctx.play(self.game, "Press_AB")
      elseif input:wasPressed("down") or input:wasPressed("right") then
        self.tableTierIndex = (self.tableTierIndex < #TABLE_TIERS) and self.tableTierIndex + 1 or 1
        ctx.play(self.game, "Press_AB")
      elseif input:wasPressed("a") then
        self:joinOnlineTable(self.tableTierIndex)
      elseif input:wasPressed("b") then
        self.mode = "select_mode"
        ctx.play(self.game, "Press_AB")
      end

    elseif self.mode == "online" then
      self.onlinePollTimer = (self.onlinePollTimer or 0) + (dt or 0.016)
      if self.onlinePollTimer >= 0.20 then
        self.onlinePollTimer = 0
        self:pollOnlineState()
      end

      local st = self.onlineState
      local actions = (st and st.allowedActions) or {}

      if st and st.myTurn and #actions > 0 then
        if input:wasPressed("left") then
          self.onlineActionIndex = (self.onlineActionIndex > 1) and self.onlineActionIndex - 1 or #actions
          ctx.play(self.game, "Press_AB")
        elseif input:wasPressed("right") then
          self.onlineActionIndex = (self.onlineActionIndex < #actions) and self.onlineActionIndex + 1 or 1
          ctx.play(self.game, "Press_AB")
        elseif input:wasPressed("up") then
          self.onlineRaiseAmount = (self.onlineRaiseAmount or 50) + 50
          ctx.play(self.game, "Press_AB")
        elseif input:wasPressed("down") then
          self.onlineRaiseAmount = math.max(st.minRaiseAmount or 50, (self.onlineRaiseAmount or 50) - 50)
          ctx.play(self.game, "Press_AB")
        elseif input:wasPressed("a") then
          local chosen = actions[self.onlineActionIndex]
          if chosen == "bet" or chosen == "raise" then
            self:sendOnlineAction(chosen, self.onlineRaiseAmount)
          else
            self:sendOnlineAction(chosen, 0)
          end
        end
      end

      if input:wasPressed("b") then
        self:leaveOnlineTable()
        ctx.play(self.game, "Press_AB")
      end

    elseif self.mode == "solo" then
      if self.phase == "bet" then
        if input:wasPressed("left") then
          self.betIndex = self.betIndex > 1 and self.betIndex - 1 or #bets
          self.notice = nil
          ctx.play(self.game, "Press_AB")
        elseif input:wasPressed("right") then
          self.betIndex = self.betIndex < #bets and self.betIndex + 1 or 1
          self.notice = nil
          ctx.play(self.game, "Press_AB")
        elseif input:wasPressed("a") then self:deal()
        elseif input:wasPressed("b") then
          if ctx.isServerConnected and ctx.isServerConnected() then
            self.mode = "select_mode"
          else
            self:close()
          end
        end
      elseif self.phase == "play" then
        if input:wasPressed("left") then self:moveAction(-1); ctx.play(self.game, "Press_AB")
        elseif input:wasPressed("right") then self:moveAction(1); ctx.play(self.game, "Press_AB")
        elseif input:wasPressed("a") then self:chooseAction()
        elseif input:wasPressed("b") then self:chooseAction(1) end
      elseif self.phase == "result" then
        if input:wasPressed("a") then
          self.phase, self.round, self.notice, self.actionIndex = "bet", nil, nil, 1
          ctx.play(self.game, "Press_AB")
        elseif input:wasPressed("b") then self:close() end
      end
    end
  end

  -- =========================================================================
  -- RENDER DRAW
  -- =========================================================================
  function Screen:draw()
    if self.mode == "select_mode" then
      View.drawModeSelect(self.modeIndex, mod.ui.Font, CardView, ctx.coins(self.game))
    elseif self.mode == "select_table" then
      View.drawTableSelect(self.tableTierIndex, TABLE_TIERS, mod.ui.Font, CardView, ctx.coins(self.game), self.onlineNotice)
    elseif self.mode == "online" then
      View.drawOnlineTable(self.onlineState, self.onlineActionIndex, self.onlineRaiseAmount, mod.ui.Font, CardView, ctx.coins(self.game), self.onlineNotice)
    else
      View.draw({
        phase = self.phase,
        betIndex = self.betIndex,
        actionIndex = self.actionIndex,
        round = self.round,
        actions = self:actions(),
        notice = self.notice
      }, mod.ui.Font, Rules, CardView, ctx.coins(self.game), bets)
    end
  end

  return Screen
end
