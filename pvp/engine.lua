-- PVP battle engine (custom, Gen 2 mechanics) for gen1online-gamecorner.
--
-- Wraps the recomp's native Gen 2 battle simulator (src/battle/gen2/Battle.lua)
-- so that BOTH machines run the SAME deterministic simulation from mirrored
-- perspectives:
--   * a shared seeded PRNG (Park-Miller) makes every RNG draw identical;
--   * turn order is canonicalized through the HOST's perspective so both peers
--     agree on who actually moves first;
--   * the enemy side's actions come from the remote player (via remoteAction())
--     instead of the local AI.
--
-- This is the "custom" backend behind the pvp interface. When the recomp gains
-- a native PVP path, a second backend implementing the same shape can be
-- dropped in and selected instead (pvp.config.engine).

local Battle = require("src.battle.gen2.Battle")
local Mon = require("src.battle.gen2.Mon")
local Protocol = require("src.link.Protocol")
local Runtime = require("src.mods.Runtime")

local PvpEngine = {}

-- Deterministic PRNG (Park-Miller, the same generator the Gen 1 link battle
-- uses). random(n) -> integer in 0..n-1, which is what Battle's rand helper
-- expects from opts.random (src/battle/gen2/Battle.lua:85).
function PvpEngine.makeRng(seed)
  seed = tonumber(seed) or 12345
  local s = seed % 2147483647
  if s <= 0 then s = s + 2147483646 end
  return function(n)
    s = (s * 16807) % 2147483647
    return s % (n or 1)
  end
end

-- Rebuild one side's party identically on both machines from packed packets
-- (Protocol.packMon2 / unpackMon2 clamp). A mon that cannot be rebuilt is
-- dropped so both peers hold identical copies.
function PvpEngine.clampParty(gameData, packedParty)
  local out = {}
  for _, p in ipairs(packedParty or {}) do
    local ok, mon = pcall(Protocol.unpackMon2, gameData, p, {})
    if ok and mon then out[#out + 1] = mon end
  end
  return out
end

-- Pack a Gen 2 party for the wire (packMon2), used by both peers so the
-- packets and the unpack clamp are the same generation.
function PvpEngine.packParty(party)
  local out = {}
  for _, mon in ipairs(party or {}) do
    local ok, packed = pcall(Protocol.packMon2, mon)
    if ok and packed then out[#out + 1] = packed end
  end
  return out
end

-- Canonical "does the HOST's mon move first?" for the current turn. Referenced
-- against the host/guest mons directly (never self.player/self.enemy), so the
-- same answer comes out on both machines. Only priority, speed and a single
-- canonical tie-break draw; held-item quick-claw ordering is intentionally
-- omitted in v1 (rare in Gen 2 PVP) to keep the stream symmetric.
function PvpEngine.hostActsFirst(battle, hostMon, hostMove, guestMon, guestMove)
  local hp = battle:movePriority(hostMove)
  local gp = battle:movePriority(guestMove)
  if hp ~= gp then return hp > gp end
  local hs = battle:effectiveSpeed(hostMon)
  local gs = battle:effectiveSpeed(guestMon)
  if hs ~= gs then return hs > gs end
  -- Speed tie: draw ONCE; 0 means the host goes first on both machines.
  return (battle.random(2) or 0) == 0
end

-- Build a PVP battle from MY perspective. opts:
--   gameData, save,
--   myParty / theirParty   (already clamped/unpacked mon tables)
--   myName, theirName, theirSpriteId
--   seed                   (shared with the opponent)
--   role                   ("host" | "guest")
--   remoteAction           (function() -> the remote player's latest action, or nil)
function PvpEngine.new(opts)
  opts = opts or {}
  local battle = Battle.new({
    data = opts.gameData,
    save = opts.save,
    party = opts.myParty or {},
    trainer = {
      classId = "PVP",
      name = opts.theirName or "OPPONENT",
      party = opts.theirParty or {},
      spriteId = opts.theirSpriteId,
    },
    random = PvpEngine.makeRng(opts.seed),
  })
  battle.pvp = true
  battle.pvpRole = (opts.role == "guest") and "guest" or "host"
  battle.pvpRemoteAction = opts.remoteAction  -- function() -> remote action or nil

  -- Link-battle rule: no experience, no money, no items. This also keeps the
  -- two machines deterministic: each side only ever mutates ITS OWN party, so
  -- an in-battle level-up would change stats (speed!) on one machine only and
  -- desync the match. MMO XP/rewards are handled separately on battle end.
  battle.awardExperience = function() end
  battle.awardPrizeMoney = function() end

  -- Canonical turn order: evaluate from the host's perspective, then translate
  -- back to THIS machine's player/enemy naming so runTurn resolves the same
  -- actual mon order on both peers.
  battle.orderOf = function(self, playerMove, enemyMove)
    local hostIsMe = (self.pvpRole == "host")
    local hostMon, guestMon
    local hostMove, guestMove
    if hostIsMe then
      hostMon, guestMon = self.player, self.enemy
      hostMove, guestMove = playerMove, enemyMove
    else
      hostMon, guestMon = self.enemy, self.player
      hostMove, guestMove = enemyMove, playerMove
    end
    local hostFirst = PvpEngine.hostActsFirst(self, hostMon, hostMove, guestMon, guestMove)
    if hostFirst then
      return (self.player == hostMon) and "player" or "enemy"
    end
    return (self.player == guestMon) and "player" or "enemy"
  end

  -- Enemy actions come from the remote player.
  battle.enemyMove = function(self)
    local a = self.pvpRemoteAction and self.pvpRemoteAction()
    if a and a.kind == "move" then return a.move end
    return Battle.vanillaEnemyMove(self)
  end

  battle.enemyTrySwitchOrItem = function(self)
    local a = self.pvpRemoteAction and self.pvpRemoteAction()
    if a and a.kind == "switch" then
      local target = a.index
      local mon = self.enemyParty[target]
      if not mon or (mon.hp or 0) <= 0 or target == self.enemyIndex then return false end
      -- Mirror the vanilla enemy rotation (Battle:enemyTrySwitchOrItem's AI
      -- arm): swap the enemy active mon, reset its area state, announce it.
      self:clearVolatile(self.enemy)
      local outgoing = self.enemy
      self:emit({ kind = "message",
        text = (self.trainer.name or "TRAINER") .. " withdrew "
          .. self:monName(outgoing) .. "!" })
      self.enemyIndex = target
      self.enemy = self.enemyParty[target]
      self:clearVolatile(self.enemy)
      self.stages.enemy = Battle.newStages()
      self:emit({ kind = "send", side = "enemy", mon = self.enemy,
        text = (self.trainer.name or "TRAINER") .. " sent out "
          .. self:monName(self.enemy) .. "!" })
      Runtime.emit("battle.battler_switched", {
        battle = self, side = self:sideRecord(self.enemy),
        battler = self.enemy, previous = outgoing,
      })
      self:breakTrapsOnSend(self.enemy)
      self:spikesDamage(self.enemy)
      return true
    end
    return false
  end

  -- Deterministic faint handling: the vanilla engine prompts the local player
  -- to pick a replacement on a faint (`pendingSwitch` + `choose-switch` event),
  -- which would desync the two machines in PVP (each side only has its own
  -- prompt). v1 auto-picks the first healthy mon on BOTH sides (identical
  -- clamped parties + identical HP => identical firstHealthy), so no extra
  -- network round-trip is needed and the match stays in lockstep.
  local origResolveFaints = battle.resolveFaints
  battle.resolveFaints = function(self)
    -- Handle a fainted PLAYER fully here so the vanilla choose-switch prompt
    -- never fires.
    if (self.player.hp or 0) <= 0 and not self.over then
      if self.faintAnnounced ~= self.player then
        self.faintAnnounced = self.player
        self:emit({ kind = "faint", side = "player",
          text = self:monName(self.player) .. " fainted!" })
        Runtime.emit("battle.fainted", { battle = self, battler = self.player,
          side = self:sideRecord(self.player) })
      end
      local nextIndex = Battle.firstHealthy(self.party)
      if not nextIndex then
        self:emit({ kind = "message", text = "You have no more POKéMON!" })
        self:endBattle("lose")
        return true
      end
      self.pendingSwitch = nil
      self.faintAnnounced = nil
      local previous = self.player
      self:clearVolatile(self.player)
      self:clearVolatile(self.party[nextIndex])
      self.playerIndex = nextIndex
      self.player = self.party[nextIndex]
      self.stages.player = Battle.newStages()
      self:emit({ kind = "send", side = "player", mon = self.player,
        text = "Go! " .. self:monName(self.player) .. "!" })
      self:breakTrapsOnSend(self.player)
      self:spikesDamage(self.player)
      self.faintInterrupt = true
      return false
    end
    return origResolveFaints(self)
  end

  return battle
end

-- A small state hash for desync detection, exchanged each turn. Both machines
-- must agree; a mismatch means a clean draw, not a crash.
function PvpEngine.stateHash(battle)
  local function sig(mon)
    if not mon then return "?" end
    local st = mon.status
    if type(st) == "table" then st = st.id or tostring(st) end
    return ("%s:%d:%s"):format(tostring(mon.species), tonumber(mon.hp) or 0, tostring(st or ""))
  end
  return sig(battle.player) .. "|" .. sig(battle.enemy)
end

return PvpEngine
