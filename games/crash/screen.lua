return function(ctx)
  local mod, Rules, View = ctx.mod, ctx.rules, ctx.view
  local Screen = { isOpaque = true }
  Screen.__index = Screen

  function Screen.new(game, opts)
    return setmetatable({ game = game, onClose = opts and opts.onClose,
      phase = "bet", betIndex = 1, multiplier = 1, elapsed = 0 }, Screen)
  end

  function Screen:sgbPalettes()
    return { require("src.render.PaletteFX").trueColorZone(0, 0, 19, 17) }
  end

  function Screen:close()
    ctx.close(self.game, self)
    if self.onClose then self.onClose() end
  end

  function Screen:launch()
    local bet = Rules.BETS[self.betIndex]
    if ctx.coins(self.game) < bet then self.notice = "NOT ENOUGH COINS"; return end
    self.game.save.coins = ctx.coins(self.game) - bet
    self.bet = bet
    self.crashPoint = Rules.crashPoint(love.math.random())
    self.elapsed, self.multiplier, self.payout = 0, 1, nil
    self.phase, self.notice = "running", nil
    mod.save:set("crash_rounds", mod.save:get("crash_rounds", 0) + 1)
    ctx.play(self.game, "Slots_New_Spin")
  end

  function Screen:cashOut()
    if self.phase ~= "running" then return end
    self.payout = math.min(ctx.coinCap - ctx.coins(self.game),
      Rules.payout(self.bet, self.multiplier))
    self.game.save.coins = ctx.coins(self.game) + self.payout
    self.phase = "cashed"
    mod.save:set("crash_wins", mod.save:get("crash_wins", 0) + 1)
    mod.save:set("crash_best_x100", math.max(
      mod.save:get("crash_best_x100", 100), math.floor(self.multiplier * 100)))
    ctx.play(self.game, "Slots_Reward")
  end

  function Screen:update(dt)
    local input = self.game.input
    if self.phase == "bet" then
      if input:wasPressed("left") then
        self.betIndex = self.betIndex > 1 and self.betIndex - 1 or #Rules.BETS
        self.notice = nil
        ctx.play(self.game, "Press_AB")
      elseif input:wasPressed("right") then
        self.betIndex = self.betIndex < #Rules.BETS and self.betIndex + 1 or 1
        self.notice = nil
        ctx.play(self.game, "Press_AB")
      elseif input:wasPressed("a") then self:launch()
      elseif input:wasPressed("b") then self:close() end
    elseif self.phase == "running" then
      self.elapsed = self.elapsed + math.min(0.05, dt or 1 / 60)
      self.multiplier = Rules.multiplier(self.elapsed)
      if self.multiplier >= self.crashPoint then
        self.multiplier, self.phase = self.crashPoint, "crashed"
        ctx.play(self.game, "Slots_Stop_Wheel")
      elseif input:wasPressed("a") then self:cashOut() end
    elseif input:wasPressed("a") then
      self.phase, self.notice = "bet", nil
      ctx.play(self.game, "Press_AB")
    elseif input:wasPressed("b") then self:close() end
  end

  function Screen:draw()
    View.draw(self, mod.ui.Font, ctx.coins(self.game), Rules.BETS)
  end

  return Screen
end
