return function(ctx)
  local mod, Rules, View = ctx.mod, ctx.rules, ctx.view
  local Screen = { isOpaque = true }
  Screen.__index = Screen

  function Screen.new(game, opts)
    return setmetatable({ game = game, onClose = opts and opts.onClose,
      phase = "ready", duration = Rules.SPIN_DURATION,
      winnerIndex = Rules.WINNER_INDEX }, Screen)
  end

  function Screen:sgbPalettes()
    return { require("src.render.PaletteFX").trueColorZone(0, 0, 19, 17) }
  end

  function Screen:close()
    ctx.close(self.game, self)
    if self.onClose then self.onClose() end
  end

  function Screen:open()
    if ctx.coins(self.game) < Rules.COST then self.notice = "NEED 500 COINS"; return end
    local pool = ctx.rewardPool(self.game)
    local random = function(maximum) return love.math.random(1, maximum) end
    self.winner = Rules.choose(pool, random)
    self.strip = Rules.strip(pool, self.winner, random)
    self.game.save.coins = ctx.coins(self.game) - Rules.COST
    self.elapsed, self.reelOffset = 0, 0
    self.phase, self.notice, self.message, self.refunded = "spinning", nil, nil, false
    mod.save:set("cases_opened", mod.save:get("cases_opened", 0) + 1)
    ctx.play(self.game, "Slots_New_Spin")
  end

  function Screen:settle()
    if self.phase ~= "spinning" then return end
    local ok, message = ctx.giveReward(self.game, self.winner)
    self.refunded = not ok
    if not ok then
      self.game.save.coins = math.min(ctx.coinCap,
        ctx.coins(self.game) + Rules.COST)
    end
    self.message, self.phase = message, "result"
    ctx.play(self.game, ok and "Slots_Reward" or "Slots_Stop_Wheel")
  end

  function Screen:update(dt)
    local input = self.game.input
    if self.phase == "ready" then
      if input:wasPressed("a") then self:open()
      elseif input:wasPressed("b") then self:close() end
    elseif self.phase == "spinning" then
      self.elapsed = math.min(self.duration,
        self.elapsed + math.min(0.05, dt or 1 / 60))
      local progress = self.elapsed / self.duration
      self.reelOffset = Rules.REEL_STOP_OFFSET * (1 - (1 - progress) ^ 4)
      if progress >= 1 then self:settle() end
    elseif input:wasPressed("a") then
      self.phase, self.notice = "ready", nil
      ctx.play(self.game, "Press_AB")
    elseif input:wasPressed("b") then self:close() end
  end

  function Screen:draw()
    View.draw(self, mod.ui.Font, ctx.coins(self.game))
  end

  return Screen
end
