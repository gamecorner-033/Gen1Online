return function(ctx)
  local mod, Rules, View = ctx.mod, ctx.rules, ctx.view
  local bets, coinCap = ctx.bets, ctx.coinCap
  local Screen = { isOpaque = true }
  Screen.__index = Screen

  function Screen.new(game, opts)
    return setmetatable({
      game = game,
      onClose = opts and opts.onClose,
      phase = "bet",
      betIndex = 1,
      actionIndex = 1,
      settled = false,
      cardAnim = 0,
      resultAge = 0,
    }, Screen)
  end

  function Screen:close()
    ctx.close(self.game, self)
    if self.onClose then self.onClose() end
  end

  function Screen:sgbPalettes()
    return { require("src.render.PaletteFX").trueColorZone(0, 0, 19, 17) }
  end

  function Screen:recordRound()
    if self.settled or not self.round or self.round.state ~= "done" then return end
    self.settled = true
    self.game.save.coins = math.min(coinCap,
      ctx.coins(self.game) + self.round.payout)
    mod.save:set("hands_played", mod.save:get("hands_played", 0) + 1)
    if self.round.result == "win" or self.round.result == "blackjack" then
      mod.save:set("hands_won", mod.save:get("hands_won", 0) + 1)
    end
    if self.round.result == "blackjack" then
      mod.save:set("blackjacks", mod.save:get("blackjacks", 0) + 1)
    end
    self.phase, self.resultAge = "result", 0
    ctx.play(self.game,
      (self.round.result == "win" or self.round.result == "blackjack")
        and "Slots_Reward" or "Slots_Stop_Wheel")
  end

  function Screen:deal()
    local bet = bets[self.betIndex]
    if ctx.coins(self.game) < bet then
      self.notice = "NOT ENOUGH COINS"
      return
    end
    self.notice = nil
    ctx.play(self.game, "Slots_New_Spin")
    self.game.save.coins = ctx.coins(self.game) - bet
    self.round = Rules.newRound(bet, Rules.newDeck(function(n)
      return love.math.random(1, n)
    end))
    self.actionIndex, self.settled, self.cardAnim, self.phase = 1, false, 0.18, "play"
    self:recordRound()
  end

  function Screen:canDouble()
    return Rules.canDouble(self.round) and ctx.coins(self.game) >= self.round.bet
  end

  function Screen:moveAction(direction)
    local nextIndex = self.actionIndex
    repeat nextIndex = ((nextIndex - 1 + direction) % 3) + 1
    until nextIndex ~= 3 or self:canDouble()
    self.actionIndex = nextIndex
  end

  function Screen:chooseAction()
    if self.actionIndex == 1 then
      Rules.hit(self.round)
      self.cardAnim = 0.18
    elseif self.actionIndex == 2 then
      Rules.stand(self.round)
    elseif self.actionIndex == 3 and self:canDouble() then
      self.game.save.coins = ctx.coins(self.game) - self.round.bet
      Rules.double(self.round)
      self.cardAnim = 0.18
    else
      self.notice = "DOUBLE UNAVAILABLE"
      return
    end
    if self.round.state == "playing" then ctx.play(self.game, "Slots_Stop_Wheel") end
    self:recordRound()
  end

  function Screen:update(dt)
    dt = dt or 1 / 60
    self.cardAnim = math.max(0, self.cardAnim - dt)
    if self.phase == "result" then self.resultAge = self.resultAge + dt end
    local input = self.game.input
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
      elseif input:wasPressed("b") then self:close() end
    elseif self.phase == "play" then
      if input:wasPressed("left") then self:moveAction(-1); ctx.play(self.game, "Press_AB")
      elseif input:wasPressed("right") then self:moveAction(1); ctx.play(self.game, "Press_AB")
      elseif input:wasPressed("a") then self:chooseAction()
      elseif input:wasPressed("b") then Rules.stand(self.round); self:recordRound() end
    elseif self.phase == "result" then
      if input:wasPressed("a") then
        self.phase, self.round, self.notice, self.resultAge = "bet", nil, nil, 0
        ctx.play(self.game, "Press_AB")
      elseif input:wasPressed("b") then self:close() end
    end
  end

  function Screen:draw()
    local lift = self.cardAnim > 0 and -math.max(1, math.ceil(self.cardAnim * 22)) or 0
    View.draw({
      phase = self.phase, betIndex = self.betIndex, actionIndex = self.actionIndex,
      round = self.round, notice = self.notice,
      doubleEnabled = self.round and self:canDouble() or false,
      cardLift = lift,
      resultPulse = self.resultAge < 0.7 and ((self.resultAge * 10) % 2) or 0,
    }, mod.ui.Font, Rules, ctx.coins(self.game), bets)
  end

  return Screen
end
