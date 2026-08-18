-- PVP battle UI: the vanilla Gen 2 battle screen, with the two additions a
-- remote opponent needs:
--   * move/switch submissions are exchanged through the session (wait for BOTH
--     players to choose before resolving/animation);
--   * the battle is polled every frame so the opponent's actions arrive.

local BattleState = require("src.ui.gen2.BattleState")
local Session = require("mods.gen1online-gamecorner.pvp.session")

local PvpUi = {}
PvpUi.__index = PvpUi
setmetatable(PvpUi, { __index = BattleState })

local function pvpDiag(line)
  pcall(function()
    local f = _G.love and _G.love.filesystem
    if f and f.write then
      f.write("gts_pvp_diag.txt", tostring(line) .. "\n")
    end
  end)
end

-- opts: the vanilla BattleState opts (battle, save, onDone, ...) PLUS
--   session = PvpSession
function PvpUi.new(game, opts)
  opts = opts or {}
  local self = BattleState.new(game, opts)
  setmetatable(self, PvpUi)
  self.session = opts.session
  self.pvpPhase = "normal"  -- normal | waiting

  -- The battle engine reads the opponent's action from the session.
  if self.battle then
    self.battle.pvpRemoteAction = function()
      return self.session and self.session.theirAction or nil
    end
  end

  -- When both actions are in, run the real turn resolution (pcall'd so any
  -- engine error is captured instead of hard-freezing the game).
  if self.session then
    self.session.onResolve = function(myAction, theirAction)
      self.pvpPhase = "normal"
      pvpDiag(string.format("resolve turn=%d my=%s their=%s",
        self.session.turn or 0,
        (myAction and (myAction.move or ("idx" .. tostring(myAction.index)))) or "nil",
        (theirAction and (theirAction.move or ("idx" .. tostring(theirAction.index)))) or "nil"))
      local ok, err = pcall(function()
        BattleState.submit(self, myAction)
      end)
      if not ok then
        pvpDiag("RESOLVE ERROR: " .. tostring(err))
      end
    end
  end
  return self
end

function PvpUi:submit(action)
  if self.pvpPhase == "waiting" then return end
  if not self.session then return BattleState.submit(self, action) end
  self.pvpPhase = "waiting"
  self.pvpWaitStart = nil
  self.message = "Waiting for opponent..."
  self.messageTimer = 9999
  pvpDiag(string.format("submit turn=%d act=%s",
    (self.session.turn or 0) + 1,
    (action and (action.move or ("idx" .. tostring(action.index)))) or "nil"))
  self.session:submitMyAction(action)
end

function PvpUi:update(dt)
  -- Poll the network + resolve turns, but never block or mutate during a
  -- mid-frame resolve; defer actual turn submission to the next update call.
  if self.session then self.session:update() end
  if self.pvpPhase == "waiting" then
    -- Keep the "Waiting..." line up; no battle input until we resolve.
    local now = (_G.love and _G.love.timer and _G.love.timer.getTime) and _G.love.timer.getTime() or os.time()
    self.pvpWaitStart = self.pvpWaitStart or now
    if now - self.pvpWaitStart > 8.0 then
      pvpDiag(string.format("STILL WAITING turn=%d their=%s netPending=%s",
        tostring(self.session and self.session.turn),
        (self.session and self.session.theirAction) and "yes" or "no",
        tostring(self.session and self.session.net
          and self.session.net.hasPending
          and self.session.net:hasPending())))
    end
    if now - self.pvpWaitStart > 20.0 then
      self.pvpPhase = "normal"
      self.message = "Connection lost."
      self.messageTimer = 120
      if self.battle and not self.battle.over then
        self.battle:endBattle("draw")
      end
      if self.session then self.session:close() end
    end
    return
  end
  BattleState.update(self, dt)
end

function PvpUi:closeBattle()
  if self.session then
    self.session:send({ type = "pvp_end" })
    self.session:close()
  end
  if self.onFinished then self.onFinished(self) end
end

return PvpUi
