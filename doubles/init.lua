-- Double Battles: wild battles against two Pokémon at once, and with a
-- partner of your own out beside you.
--
-- A stock wild BattleState is decorated in place, the way the engine's
-- own LinkBattle reshapes one.  Extra battlers join both sides, every
-- battler is ordered by the engine's own speed rules each turn, and the
-- pure battle modules (damage, effects, status, experience) are reused
-- untouched.  When a lead battler falls its partner steps up, so the
-- endgame of every fight is the vanilla 1v1 the engine knows best.
--
-- Link play is deliberately untouched: the manifest declares
-- affects_link, so the handshake refuses mixed matches cleanly.
return function(loadModFile, mod)
  -- Self-contained helper utilities
  local function grassSlots(data, mapId)
    local encDef = data and data.encounters and data.encounters[mapId]
    local slots = encDef and encDef.grass and encDef.grass.slots
    return slots or {}
  end

  local function monName(data, mon)
    if not mon then return "POKéMON" end
    if mon.nickname and mon.nickname ~= "" then return mon.nickname end
    local def = data and data.pokemon and data.pokemon[mon.species]
    return (def and def.name) or tostring(mon.species or "POKéMON")
  end


  local log = mod and mod.log or {
    warn = function(...) print("[Double Battles WARN]", ...) end,
    error = function(...) print("[Double Battles ERROR]", ...) end,
    info = function(...) print("[Double Battles INFO]", ...) end
  }
  local options = mod and mod.options or {
    get = function(_, k)
      if k == "wild_doubles" then return "off" end
      if k == "your_side" then return "pair" end
      if k == "trainer_doubles" then return true end
      if k == "double_exp" then return "full" end
      return nil
    end,
    define = function() end
  }


  options:define({
    { key = "wild_doubles", label = "WILD DOUBLES", type = "choice",
      default = "off",
      choices = { { "OFF", "off" }, { "SOMETIMES", "sometimes" },
                  { "ALWAYS", "always" } } },
    { key = "your_side", label = "YOUR SIDE", type = "choice",
      default = "pair",
      choices = { { "PAIR", "pair" }, { "SOLO", "solo" } } },
    { key = "trainer_doubles", label = "TRAINER 2V2", type = "toggle",
      default = true },
    { key = "double_exp", label = "DOUBLES EXP", type = "choice",
      default = "full",
      choices = { { "FULL", "full" }, { "HALF", "half" } } },
  })

  local function doubleChance()
    local v = options:get("wild_doubles")
    if v == "always" then return 1 end
    if v == "sometimes" then return 0.3 end
    return 0
  end

  -- is the player airborne right now?  ANY enabled mod that exports
  -- isFlying answers (free_fly, Dramatic Sky Ride), with the field
  -- free_fly stamps on the player as the last resort
  local function airborne(game)
    local exportsAll = game and game.mods and game.mods.exports
    if type(exportsAll) == "table" then
      for _, ex in pairs(exportsAll) do
        local fn = type(ex) == "table" and ex.isFlying
        if type(fn) == "function" then
          local ok, v = pcall(fn)
          if ok and v then return true end
        end
      end
    end
    local p = game and game.overworld and game.overworld.player
    return (p and p.freeFlying) and true or false
  end

  -- once the doubles roll has passed, a partner ALWAYS joins: whatever
  -- the sources and the encounter list failed to provide (slotless map,
  -- refused species), a stand-in near the lead foe's level fills in
  -- rather than the fight quietly going 1v1.  On the ground that is a
  -- plain RATTATA; in the air a rat cannot join, so a PIDGEY does.
  local decorateFwd
  local function ensurePartner(game, battle, sp, lv)
    if sp then decorateFwd(game, battle, sp, lv) end
    if battle.__double then return end
    local e = battle.enemy
    local base = (e and e.mon and e.mon.level) or 5
    decorateFwd(game, battle, airborne(game) and "PIDGEY" or "RATTATA",
                math.max(2, base + love.math.random(-2, 2)))
    if not battle.__double then
      log.warn("doubles declined: even the fallback partner refused")
    end
  end

  -- the partner foe comes from the map's own grass slots, like any
  -- other encounter; a slotless map sends the lead foe's twin
  local function rollPartner(game, battle)
    local ow = game.overworld
    local slots = ow and ow.map
      and grassSlots(game.data, ow.map.id) or {}
    if #slots > 0 then
      local s = slots[love.math.random(#slots)]
      return s.species, s.level
    end
    local e = battle.enemy
    if not (e and e.mon) then return nil end
    return e.mon.species,
           math.max(2, (e.mon.level or 5) + love.math.random(-2, 2))
  end

  -- partner sources: other mods can supply the second wild foe.
  -- Sources run in priority order (lower first); the built-in
  -- wild_skies bird sits at 50 and the encounter list at 100, so a
  -- registered source's priority picks its place in that chain.
  -- provide(game, battle) returns species, level or nil to pass.
  local partnerSources = {}
  mod.exports.registerPartnerSource = function(source)
    if type(source) ~= "table" or type(source.provide) ~= "function"
       or source.id == nil then
      return false, "source with id and provide required"
    end
    mod.exports.unregisterPartnerSource(source.id)
    source.priority = tonumber(source.priority) or 75
    table.insert(partnerSources, source)
    table.sort(partnerSources, function(a, b)
      return a.priority < b.priority
    end)
    return true
  end
  mod.exports.unregisterPartnerSource = function(id)
    for i = #partnerSources, 1, -1 do
      if partnerSources[i].id == id then
        table.remove(partnerSources, i)
        return true
      end
    end
    return false
  end
  local function providerPartner(game, battle, minP, maxP)
    for _, src in ipairs(partnerSources) do
      if src.priority >= minP and src.priority < maxP then
        local ok, sp, lv = pcall(src.provide, game, battle)
        if ok and sp then return sp, lv end
      end
    end
  end

  -- trainer pair sources: a mod can put a second trainer beside an
  -- organically started one (two sight lines crossing at once, an
  -- ambush NPC).  provide(game, battle) returns oppClassB, partyIndexB
  -- or nil to pass; the battle becomes a full trainer pair, each slot
  -- backed by its own trainer's bench.  Firing is the source mod's
  -- deliberate choice, so the TRAINER 2V2 option does not gate it.
  local pairSources = {}
  mod.exports.unregisterTrainerPairSource = function(id)
    for i = #pairSources, 1, -1 do
      if pairSources[i].id == id then
        table.remove(pairSources, i)
        return true
      end
    end
    return false
  end
  mod.exports.registerTrainerPairSource = function(source)
    if type(source) ~= "table" or type(source.provide) ~= "function"
       or source.id == nil then
      return false, "source with id and provide required"
    end
    mod.exports.unregisterTrainerPairSource(source.id)
    source.priority = tonumber(source.priority) or 75
    table.insert(pairSources, source)
    table.sort(pairSources, function(a, b)
      return a.priority < b.priority
    end)
    return true
  end
  local function providerPair(game, battle)
    for _, src in ipairs(pairSources) do
      local ok, opp, idx = pcall(src.provide, game, battle)
      if ok and opp then return opp, idx end
    end
    return nil
  end

  -- doubles vetoes: a mod can keep specific wild encounters strictly
  -- 1v1 (wild_skies uses this for its legendary sightings, where a
  -- partner would spoil the catch).  veto(game, battle) returns true
  -- to block the decoration; vetoes never affect trainer battles.
  local doubleVetoes = {}
  mod.exports.unregisterDoubleVeto = function(id)
    for i = #doubleVetoes, 1, -1 do
      if doubleVetoes[i].id == id then
        table.remove(doubleVetoes, i)
        return true
      end
    end
    return false
  end
  mod.exports.registerDoubleVeto = function(v)
    if type(v) ~= "table" or v.id == nil or type(v.veto) ~= "function" then
      return false, "veto with id and veto(game, battle) required"
    end
    mod.exports.unregisterDoubleVeto(v.id)
    doubleVetoes[#doubleVetoes + 1] = v
    return true
  end
  local function vetoedBy(game, battle)
    for _, v in ipairs(doubleVetoes) do
      local ok, hit = pcall(v.veto, game, battle)
      if ok and hit then return v.id end
    end
    return nil
  end

  -- built-in veto: legendaries an overhaul stages on its own terms.
  -- Crystal 251's Raikou and Entei roam and flee through a class
  -- chain our turn loop replaces, and its sanctuary encounters (Lugia,
  -- Ho-Oh, Celebi) are one-shot catches a partner would spoil, the
  -- same reasoning wild_skies applies to its legendary sightings.
  -- Species-keyed and inert on a dex that never rolls these wild.
  local SOLITARY_LEGENDS = {
    RAIKOU = true, ENTEI = true, SUICUNE = true,
    LUGIA = true, HO_OH = true, CELEBI = true, MEW = true,
  }
  doubleVetoes[#doubleVetoes + 1] = {
    id = "double_battles_solitary_legends",
    veto = function(game, battle)
      local mon = battle and battle.enemy and battle.enemy.mon
      return mon and SOLITARY_LEGENDS[mon.species] or false
    end,
  }

  -- ally sources: a mod can pick WHICH party mon fights beside your
  -- lead (free_fly puts the mount there mid-air).  provide(game,
  -- battle) returns a party mon or nil to pass; the default is the
  -- next healthy bench mon.  The pick must be a healthy party member
  -- that is not already the lead, or it falls through.
  local allySources = {}
  mod.exports.unregisterAllySource = function(id)
    for i = #allySources, 1, -1 do
      if allySources[i].id == id then
        table.remove(allySources, i)
        return true
      end
    end
    return false
  end
  mod.exports.registerAllySource = function(source)
    if type(source) ~= "table" or type(source.provide) ~= "function"
       or source.id == nil then
      return false, "source with id and provide required"
    end
    mod.exports.unregisterAllySource(source.id)
    source.priority = tonumber(source.priority) or 75
    table.insert(allySources, source)
    table.sort(allySources, function(a, b)
      return a.priority < b.priority
    end)
    return true
  end
  local function providerAlly(game, battle)
    for _, src in ipairs(allySources) do
      local ok, m = pcall(src.provide, game, battle)
      if ok and type(m) == "table" and (m.hp or 0) > 0
         and not (battle.player and battle.player.mon == m) then
        for _, pm in ipairs((game.save and game.save.party) or {}) do
          if pm == m then return m end
        end
      end
    end
    return nil
  end

  -- spread moves, gen 3 semantics: "foes" hits both enemies, "others"
  -- hits everyone but the user (your partner included, Earthquake
  -- style).  The primary target gets the full move; the ripple hits
  -- land at three quarters damage with no secondary effects.
  local SPREAD = {
    SURF = "foes", BLIZZARD = "foes", ROCK_SLIDE = "foes",
    EARTHQUAKE = "others", EXPLOSION = "others", SELFDESTRUCT = "others",
  }
  mod.exports.registerSpreadMove = function(moveId, kind)
    if type(moveId) ~= "string"
       or (kind ~= "foes" and kind ~= "others") then
      return false, 'move id and kind ("foes" or "others") required'
    end
    SPREAD[moveId] = kind
    return true
  end

  -- scene owners: mods that stage the battlers themselves (Dramatic
  -- Shape's 3D rungs, cinematic battle cameras).  While one is active
  -- our flat partner draws, the classic aim frames and the rigid
  -- animation shift all stand down; the slot borrow still keeps every
  -- HUD honest, and a scene adapter can stage the partners its own way.
  local sceneDetectors = {}
  mod.exports.unregisterSceneDetector = function(id)
    for i = #sceneDetectors, 1, -1 do
      if sceneDetectors[i].id == id then
        table.remove(sceneDetectors, i)
        return true
      end
    end
    return false
  end
  mod.exports.registerSceneDetector = function(det)
    if type(det) ~= "table" or det.id == nil
       or type(det.active) ~= "function" then
      return false, "detector with id and active(battle) required"
    end
    mod.exports.unregisterSceneDetector(det.id)
    sceneDetectors[#sceneDetectors + 1] = det
    return true
  end
  local function sceneActive(battle)
    for _, det in ipairs(sceneDetectors) do
      local ok, hit = pcall(det.active, battle)
      if ok and hit then return true end
    end
    return false
  end

  -- what UI mods may read while a doubles battle runs: the battler
  -- under the aim cursor (either prompt), and the partner an action
  -- has borrowed the HUD for.  Both are nil outside those windows.
  mod.exports.aimedBattler = function(battle)
    if type(battle) ~= "table" or not battle.__double then return nil end
    if battle.phase == "db_target" then
      return battle.__dbAimBattler or battle.enemy
    end
    if battle.phase == "db_switch_target" then
      return battle.__dbSwitchAim or battle.player
    end
    return nil
  end
  mod.exports.focusBattler = function(battle)
    if type(battle) ~= "table" or not battle.__double then return nil end
    return battle.__dbFocus
  end

  -- the second healthy party mon that is not already out front
  local function secondHealthy(save, leadMon)
    for _, m in ipairs(save.party or {}) do
      if m ~= leadMon and (m.hp or 0) > 0 then return m end
    end
    return nil
  end

  local function alive(b) return b and b.mon and b.mon.hp > 0 end

  -- where a foe stands on screen, by its sticky anchor (root coords).
  -- classic anchor 2 is the half-size partner slot tucked between the
  -- enemy HUD (y0-32) and the player's back sprite, feet on y=60
  local function foeRect(battle, b)
    local a = (b and b.dbAnchor) or 1
    if battle.wideRegion then
      if a == 1 then return 240, 0, 56 end
      return 180, 0, 56
    end
    if a == 1 then return 96, 0, 56 end
    return 44, 0, 56
  end

  -- where one of yours stands, likewise by sticky anchor: the vanilla
  -- back-sprite slot, or the partner card at the lead's shoulder
  local function allyRect(battle, b)
    local a = (b and b.dbAnchor) or 1
    if battle.wideRegion then
      if a == 1 then return 16, 48, 48 end
      return 72, 48, 48
    end
    if a == 1 then return 8, 48, 48 end
    return 48, 48, 48
  end

  -- ------- the decoration

  local applyDouble

  -- DOUBLES EXP set to HALF trims each foe's payout in our battles
  -- only; every other battle's experience is untouched
  local expActive = nil
  mod.hooks:wrap("exp.gain", function(next, c)
    local gained = next(c)
    if expActive and options:get("double_exp") == "half" then
      return math.max(1, math.floor((tonumber(gained) or 0) / 2))
    end
    return gained
  end)

  -- wild: the second foe is built fresh from a species and level
  local function decorate(game, battle, species, level)
    if not battle or battle.__double or battle.kind ~= "wild"
       or battle.dead then
      return battle
    end
    local BattleState = require("src.battle.BattleState")
    local Pokemon = require("src.pokemon.Pokemon")
    local Strings = require("src.core.Strings")
    if type(BattleState.makeBattler) ~= "function" then
      log.warn("engine exposes no makeBattler; doubles disabled")
      return battle
    end
    local okM, mon = pcall(Pokemon.new, game.data, species, level or 5)
    if not (okM and mon) then return battle end
    local okB, foe = pcall(BattleState.makeBattler, game.data, mon, false)
    if not (okB and foe) then return battle end
    local dex = game.save and game.save.pokedex
    if dex then dex.seen[species] = true end
    battle = applyDouble(game, battle, foe)
    if battle.__double then
      battle.introText = Strings("Wild %s and\n%s appeared!",
                                 battle.enemy.name, foe.name)
    end
    return battle
  end
  decorateFwd = decorate

  -- trainer: the second foe steps up from the trainer's own bench,
  -- which keeps refilling the second slot as mons fall
  local function decorateTrainer(game, battle, force)
    if not battle or battle.__double or battle.kind ~= "trainer"
       or battle.dead then
      return battle
    end
    if not force and options:get("trainer_doubles") == false then
      return battle
    end
    local party = battle.enemyParty
    if type(party) ~= "table" then return battle end
    local benchI
    for i, m in ipairs(party) do
      if i ~= battle.enemyIndex and (m.hp or 0) > 0 then
        benchI = i
        break
      end
    end
    if not benchI then return battle end
    local BattleState = require("src.battle.BattleState")
    if type(BattleState.makeBattler) ~= "function" then return battle end
    local okB, foe = pcall(BattleState.makeBattler, game.data,
                           party[benchI], false)
    if not (okB and foe) then return battle end
    local dex = game.save and game.save.pokedex
    if dex then dex.seen[party[benchI].species] = true end
    battle = applyDouble(game, battle, foe)
    if not battle.__double then return battle end
    battle.__dbEnemy2Index = benchI
    battle.__dbOnPromote = function(self)
      self.enemyIndex = self.__dbEnemy2Index or self.enemyIndex
    end
    battle.__dbRefill = function(self)
      local nextI
      for i, m in ipairs(self.enemyParty or {}) do
        if i ~= self.enemyIndex and i ~= self.__dbEnemy2Index
           and (m.hp or 0) > 0 then
          nextI = i
          break
        end
      end
      if not nextI then return nil end
      local okN, nb = pcall(BattleState.makeBattler, self.data,
                            self.enemyParty[nextI], false)
      if not (okN and nb) then return nil end
      self.__dbEnemy2Index = nextI
      nb.dbAnchor = (self.enemy and self.enemy.dbAnchor == 2) and 1 or 2
      local Strings = require("src.core.Strings")
      local who = (self.trainer and self.trainer.name) or "The foe"
      self:sayNext(Strings("%s sent\nout %s!", who, nb.name))
      local dex2 = self.game.save and self.game.save.pokedex
      if dex2 then dex2.seen[nb.mon.species] = true end
      return nb
    end
    return battle
  end

  -- trainer pairs: two distinct trainers share the enemy side.  A's
  -- party backs the lead slot, B's the second; when A runs dry the
  -- battle hands its endgame (defeat text, payout) to B.  Payout is
  -- therefore B's alone, a known simplification.
  local function decoratePair(game, battle, oppClassB, partyIndexB)
    if not battle or battle.__double or battle.kind ~= "trainer"
       or battle.dead then
      return battle
    end
    local BattleState = require("src.battle.BattleState")
    if type(BattleState.makeBattler) ~= "function" then return battle end
    local okT, tmp = pcall(BattleState.newTrainer, game, oppClassB,
                           tonumber(partyIndexB) or 1)
    if not (okT and tmp) or tmp.dead or not tmp.enemy then return battle end
    local partyB = tmp.enemyParty or {}
    if #partyB == 0 then return battle end
    battle = applyDouble(game, battle, tmp.enemy)
    if not battle.__double then return battle end
    battle.__dbSideB = { trainer = tmp.trainer, party = partyB,
                         index = tmp.enemyIndex or 1,
                         aiMods = tmp.enemyAIMods }

    -- slot 2 refills from B's bench only
    battle.__dbRefill = function(self)
      local b = self.__dbSideB
      if not b then return nil end
      local nextI
      for i, m in ipairs(b.party) do
        if i ~= b.index and (m.hp or 0) > 0 then
          nextI = i
          break
        end
      end
      if not nextI then return nil end
      local okN, nb = pcall(BattleState.makeBattler, self.data,
                            b.party[nextI], false)
      if not (okN and nb) then return nil end
      b.index = nextI
      nb.dbAnchor = (self.enemy and self.enemy.dbAnchor == 2) and 1 or 2
      local Strings = require("src.core.Strings")
      local who = (b.trainer and b.trainer.name) or "The foe"
      self:sayNext(Strings("%s sent\nout %s!", who, nb.name))
      return nb
    end

    -- the lead slot belongs to trainer A while A has mons; then the
    -- battle becomes trainer B's for the vanilla endgame
    battle.__dbLeadFaint = function(self)
      local Runtime = require("src.mods.Runtime")
      local Strings = require("src.core.Strings")
      local nextI
      for i, m in ipairs(self.enemyParty or {}) do
        if i ~= self.enemyIndex and (m.hp or 0) > 0 then
          nextI = i
          break
        end
      end
      if nextI then
        local okN, nb = pcall(BattleState.makeBattler, self.data,
                              self.enemyParty[nextI], false)
        if not (okN and nb) then return false end
        self.enemyIndex = nextI
        local previous = self.enemy
        nb.dbAnchor = (previous and previous.dbAnchor) or 1
        self.enemy = nb
        self:syncSides()
        self:markParticipant()
        Runtime.emit("battle.battler_switched", {
          battle = self, side = self.sides[2], battler = self.enemy,
          previous = previous,
        })
        self:sayNext(Strings("%s sent\nout %s!",
          (self.trainer and self.trainer.name) or "The foe", nb.name))
        return true
      end
      local b = self.__dbSideB
      if not (b and alive(self.enemy2)) then return false end
      -- A is out of Pokémon: bank A's prize (baseMoney times its last
      -- party mon's level, the vanilla formula), then B takes over
      local lastMon = self.enemyParty and self.enemyParty[#self.enemyParty]
      local baseMoney = (self.trainer and self.trainer.baseMoney) or 0
      self.__dbExtraPayout = (self.__dbExtraPayout or 0)
        + baseMoney * ((lastMon and lastMon.level) or 0)
      self.trainer = b.trainer or self.trainer
      self.enemyParty = b.party
      self.enemyIndex = b.index or 1
      self.enemyAIMods = b.aiMods or self.enemyAIMods
      local previous = self.enemy
      self.enemy = self.enemy2
      self.enemy2 = nil
      self.__dbSideB = nil
      -- from here the bench of the (now current) party feeds slot 2
      self.__dbLeadFaint = nil
      self.__dbEnemy2Index = self.enemyIndex
      self.__dbOnPromote = function(sf)
        sf.enemyIndex = sf.__dbEnemy2Index or sf.enemyIndex
      end
      self.__dbRefill = function(sf)
        local nI
        for i, m in ipairs(sf.enemyParty or {}) do
          if i ~= sf.enemyIndex and i ~= sf.__dbEnemy2Index
             and (m.hp or 0) > 0 then
            nI = i
            break
          end
        end
        if not nI then return nil end
        local okN, nb = pcall(BattleState.makeBattler, sf.data,
                              sf.enemyParty[nI], false)
        if not (okN and nb) then return nil end
        nb.dbAnchor = (sf.enemy and sf.enemy.dbAnchor == 2) and 1 or 2
        sf.__dbEnemy2Index = nI
        local S = require("src.core.Strings")
        sf:sayNext(S("%s sent\nout %s!",
          (sf.trainer and sf.trainer.name) or "The foe", nb.name))
        return nb
      end
      self:syncSides()
      self:markParticipant()
      Runtime.emit("battle.battler_switched", {
        battle = self, side = self.sides[2], battler = self.enemy,
        previous = previous,
      })
      self.enemy2 = self:__dbRefill() or nil
      if not self.enemy2 then self.enemy.dbAnchor = 1 end
      self:syncSides()
      if self.enemy2 then
        Runtime.emit("battle.battler_switched", {
          battle = self, side = self.sides[2], battler = self.enemy2,
        })
      end
      return true
    end
    return battle
  end

  -- everything both formats share: the second battlers, the turn loop,
  -- the faints, the aiming UI and the queue plumbing
  applyDouble = function(game, battle, foe)
    -- safari has no FIGHT menu (a doubles ball ban would make it
    -- unwinnable), and ghost/demo battles restrict actions: all three
    -- stay strictly vanilla
    if battle.safari or battle.ghost or battle.demo then return battle end
    local BattleState = require("src.battle.BattleState")
    local Strings = require("src.core.Strings")
    battle.__double = true
    battle.enemy2 = foe
    -- positions are sticky: a battler keeps its anchor for life, so a
    -- promoted survivor stays where it stood; only a fresh replacement
    -- takes the empty spot
    battle.enemy.dbAnchor = battle.enemy.dbAnchor or 1
    foe.dbAnchor = 2

    -- your own partner: the next healthy party mon, when the option
    -- says PAIR and the bench has one to give
    if options:get("your_side") ~= "solo" and battle.player then
      local benchMon = providerAlly(game, battle)
        or secondHealthy(game.save, battle.player.mon)
      if benchMon then
        local okP, ally = pcall(BattleState.makeBattler, game.data,
                                benchMon, true, game.save)
        if okP and ally then
          battle.player.dbAnchor = battle.player.dbAnchor or 1
          ally.dbAnchor = 2
          battle.player2 = ally
        end
      end
    end

    -- animation frames anchor to the two lead positions; a rigid shift
    -- (the same trick the wide layout uses) carries them to whichever
    -- partner the acting move actually involves
    local function shiftFor(self, user, target)
      local function off(b)
        if not b or (b.dbAnchor or 1) ~= 2 then return nil end
        if b == self.player or b == self.player2 then
          return { self.wideRegion and 80 or 64, 2 }
        end
        return { self.wideRegion and -66 or -60, 2 }
      end
      return off(target) or off(user)
    end
    battle.__dbShiftFor = shiftFor
    if battle.animPlayer and not battle.animPlayer.__dbWrapped then
      battle.animPlayer.__dbWrapped = true
      local origAnimDraw = battle.animPlayer.draw
      battle.animPlayer.draw = function(a, ...)
        local shift = battle.__dbAnimShift
        -- a 3D scene remaps the whole anim frame onto the arena axis,
        -- where our classic sideways shift points the wrong way
        if not shift or sceneActive(battle) then
          return origAnimDraw(a, ...)
        end
        love.graphics.push()
        love.graphics.translate(shift[1], shift[2])
        local okD, errD = pcall(origAnimDraw, a, ...)
        love.graphics.pop()
        if not okD then error(errD) end
      end
    end

    -- partners draw inside the engine's own pics layer: same menu
    -- clipping, same battle scale, under the HUD chrome, inside the
    -- wide layout's side regions.  A battler whose sticky anchor says
    -- it stands at the partner spot suppresses vanilla's lead-anchored
    -- draw for the duration of the call and is drawn at its spot here.
    local origPics = battle.drawPicsLayer
    battle.drawPicsLayer = function(self, slide, sx, sy, onlySide,
                                    skipMenuClip)
      -- a scene owner (Dramatic Shape's 3D rungs, a cinematic camera)
      -- stages the mons itself; partners painted flat over that scene
      -- double every sprite, so the flat draw stands down and the
      -- scene adapter (lib/dramatic_shape.lua for DS) stages both
      if sceneActive(self) then
        return origPics(self, slide, sx, sy, onlySide, skipMenuClip)
      end
      -- the HUD borrow (battle.draw) swaps slots for the frame; the
      -- pics unswap for their portion so sprites never move or morph
      -- while aiming.  Only the panels follow the selection.
      local unswapE, unswapP = self.__dbBorrowedE, self.__dbBorrowedP
      if unswapE then self.enemy, self.enemy2 = self.enemy2, self.enemy end
      if unswapP then
        self.player, self.player2 = self.player2, self.player
      end
      local eAway = self.enemy and (self.enemy.dbAnchor or 1) == 2
      local pAway = self.player and (self.player.dbAnchor or 1) == 2
      local prevE, prevP = self.enemySendingOut, self.sendingOut
      if eAway then self.enemySendingOut = true end
      -- Hide vanilla's 1.0x back sprite so our dual 0.55x scaled player sprites render cleanly
      self.sendingOut = true
      local okO, errO = pcall(origPics, self, slide, sx, sy, onlySide,
                              skipMenuClip)
      self.enemySendingOut, self.sendingOut = prevE, prevP
      if not okO then error(errO) end

      local g = love.graphics
      local clipY = not skipMenuClip
        and (self.phase == "mimicSelect" and 56
             or self.phase == "moveSelect" and 64) or nil
      local clipped, c1, c2, c3, c4
      if clipY and g.getScissor and g.intersectScissor then
        c1, c2, c3, c4 = g.getScissor()
        g.intersectScissor(0, 0, 160, clipY)
        clipped = true
      end
      slide = slide or 0
      sx, sy = sx or 0, sy or 0
      local BS = require("src.battle.BattleState")

      local function showable(b)
        if not (b and b.mon and b.sprite) then return false end
        if self.fxHidden and self:fxHidden(b) then return false end
        if b.mon.hp > 0 then return true end
        local okF, active = pcall(function()
          return self:fxFaintActive(b)
        end)
        return okF and active or false
      end
      local function drawFoeAt(b, anchor)
        pcall(function()
          local img = self:picImage(b.sprite)
          local sc = BS.resolveBattleScale(self.data, "front", nil,
            b.mon and b.mon.species) or 1
          local tw = math.max(1, math.min(7, math.floor(img:getWidth() / 8)))
          local th = math.max(1, math.min(7, math.floor(img:getHeight() / 8)))
          local hPad = math.floor((8 - tw) / 2)
          local vPad = 7 - th
          
          if anchor == 1 then
            local ex = 96 + 8 * hPad - slide + sx
            local ey = 8 * vPad + sy
            local dx, dy = BS.frontPlacement(ex, ey, img:getWidth(), img:getHeight(), sc)
            self:drawBattlerPic(b, dx, dy, sc)
            return
          end
          
          -- Partner Foe (Anchor 2): Full native 1.0x scale beside lead
          local ex = 44 + 8 * hPad - slide + sx
          local ey = 8 * vPad + sy
          local dx, dy = BS.frontPlacement(ex, ey, img:getWidth(), img:getHeight(), sc)
          self:drawBattlerPic(b, dx, dy, sc)
        end)
      end
      local function drawAllyAt(b, anchor)
        pcall(function()
          local img = self:picImage(b.sprite)
          local baseScale = BS.resolveBattleScale(self.data, "back", nil,
            b.mon and b.mon.species) or 1
          -- Back sprites are stored at 2x GB resolution; scale by 0.55 for double battles
          local sc = baseScale * 0.55
          local baseX = (anchor == 1 and 8 or 44) + slide + sx
          local dy = 96 - img:getHeight() * sc + sy
          self:drawBattlerPic(b, baseX, dy, sc)
        end)
      end

      if onlySide ~= "player" then
        if eAway and showable(self.enemy) then
          drawFoeAt(self.enemy, 2)
        end
        if showable(self.enemy2) then
          drawFoeAt(self.enemy2, self.enemy2.dbAnchor or 2)
        end
      end
      if onlySide ~= "enemy" then
        if showable(self.player) then
          drawAllyAt(self.player, self.player.dbAnchor or 1)
        end
        if showable(self.player2) then
          drawAllyAt(self.player2, self.player2.dbAnchor or 2)
        end
      end
      if clipped then
        if c1 then g.setScissor(c1, c2, c3, c4) else g.setScissor() end
      end
      if unswapE then self.enemy, self.enemy2 = self.enemy2, self.enemy end
      if unswapP then
        self.player, self.player2 = self.player2, self.player
      end
    end

    -- Aiming: while the target prompt is up the aimed foe OCCUPIES the
    -- lead slot.  A draw-time borrow only reaches HUDs drawn inside
    -- battle.draw; mods like gen1_modern_ui paint their panels from a
    -- render.hud hook after the state draw returns, so the swap has to
    -- hold for the whole frame, not one call.  The prompt is an idle
    -- window (no queue, no animations), and the sticky anchors keep the
    -- sprites exactly where they stand through the swap; the slots are
    -- restored before any turn logic runs.
    battle.__dbAimAt = function(self, target)
      if target == self.enemy2 and alive(self.enemy2) then
        self.enemy, self.enemy2 = self.enemy2, self.enemy
        self.__dbAimSwapped = not self.__dbAimSwapped or nil
        self:syncSides()
      end
      self.__dbAimBattler = self.enemy
      self.enemy.shownHP = self.enemy.mon.hp
      self.enemy.shownStatus = self.enemy.mon.status
    end
    battle.__dbAimReset = function(self)
      if self.__dbAimSwapped then
        self.enemy, self.enemy2 = self.enemy2, self.enemy
        self.__dbAimSwapped = nil
        self:syncSides()
      end
      self.__dbAimBattler = nil
    end

    -- the HUD borrow lives at the ROOT of the battle draw: every HUD
    -- implementation drawn inside it (the classic boxes, the wide
    -- layout's panels, any mod's battle.overlay chrome) reads
    -- battle.enemy / battle.player during the frame, so swapping the
    -- acting partner into the lead slot for the whole draw makes them
    -- ALL follow the action.  The sticky anchors keep our 2D sprites
    -- exactly where they stand through the swap.
    local origDraw = battle.draw
    if type(origDraw) == "function" then
      battle.draw = function(self, ...)
        local e2 = alive(self.enemy2) and self.__dbFocus == self.enemy2
          and self.enemy2 or nil
        local p2 = alive(self.player2) and self.__dbFocus == self.player2
          and self.player2 or nil
        -- ease shownHP toward the truth so the borrowed box drains
        -- like every other bar instead of snapping
        local function easeShown(b)
          local shown = b.shownHP or b.mon.hp
          local diff = b.mon.hp - shown
          if diff ~= 0 then
            b.shownHP = shown + (diff > 0 and math.min(diff, 2)
                                 or math.max(diff, -2))
          end
          b.shownStatus = b.mon.status
        end
        if e2 then
          easeShown(e2)
          self.enemy, self.enemy2 = self.enemy2, self.enemy
          self.__dbBorrowedE = true
        end
        if p2 then
          easeShown(p2)
          self.player, self.player2 = self.player2, self.player
          self.__dbBorrowedP = true
        end
        local okH, errH = pcall(origDraw, self, ...)
        self.__dbBorrowedE, self.__dbBorrowedP = nil, nil
        if e2 then self.enemy, self.enemy2 = self.enemy2, self.enemy end
        if p2 then self.player, self.player2 = self.player2, self.player end
        if not okH then error(errH) end
      end
    end

    -- the sides substrate is the engine's documented multi-battler
    -- shape; we are its first list-shaped tenant
    local origSync = battle.syncSides
    battle.syncSides = function(self)
      -- invariant: one body per mon.  Any switch path we didn't wrap
      -- (vanilla's SHIFT prompt applies switches its own way) that
      -- duplicates an active mon costs the partner slot, never a crash
      if self.player2 and self.player and self.player.mon == self.player2.mon then
        log.warn("duplicate player mon; dropping the partner slot")
        self.player2 = nil
      end
      if self.enemy2 and self.enemy and self.enemy.mon == self.enemy2.mon then
        log.warn("duplicate enemy mon; dropping the partner slot")
        self.enemy2 = nil
      end
      origSync(self)
      self.sides[1].battlers[2] = alive(self.player2) and self.player2 or nil
      self.sides[2].battlers[2] = alive(self.enemy2) and self.enemy2 or nil
    end
    battle:syncSides()

    -- the party menu knows the lead but not the partner: refuse a
    -- switch into the mon already fighting beside you.  With your pair
    -- up, picking a bench mon then asks WHICH of yours steps back (the
    -- db_switch_target prompt); the vanilla flow only ever swapped the
    -- lead slot, gave one foe a free move and bypassed the partner's
    -- whole turn.  With one of yours and two foes, the switch runs
    -- through our turn so both foes still act.
    local origResolveSwitch = battle.resolveSwitch
    if type(origResolveSwitch) == "function" then
      battle.resolveSwitch = function(self, newMon)
        if (self.player2 and newMon == self.player2.mon)
           or (self.__dbSwapped and self.player
               and newMon == self.player.mon) then
          self:say(Strings("%s is already\nout!",
                           monName(self.data, newMon)))
          self.phase = "messages"
          self.afterQueue = "menu"
          return
        end
        if alive(self.player2) and alive(self.player) then
          self.__dbSwitchMon = newMon
          self:__dbSwitchAimAt(self.player)
          self.phase = "db_switch_target"
          return
        end
        if alive(self.enemy2) then
          self:resolveTurn({ dbSwitch = newMon })
          return
        end
        return origResolveSwitch(self, newMon)
      end
    end

    -- switch aiming mirrors the foe aim: the mon about to step back
    -- occupies the lead slot while the prompt is up, so every HUD names
    -- it; sticky anchors keep the sprites still through the swap
    battle.__dbSwitchAimAt = function(self, target)
      if target == self.player2 and alive(self.player2) then
        self.player, self.player2 = self.player2, self.player
        self.__dbSwitchSwapped = not self.__dbSwitchSwapped or nil
        self:syncSides()
      end
      self.__dbSwitchAim = self.player
      self.player.shownHP = self.player.mon.hp
      self.player.shownStatus = self.player.mon.status
    end
    battle.__dbSwitchReset = function(self)
      if self.__dbSwitchSwapped then
        self.player, self.player2 = self.player2, self.player
        self.__dbSwitchSwapped = nil
        self:syncSides()
      end
      self.__dbSwitchAim = nil
    end

    -- lock in the recall: the mon that steps back spends its slot's
    -- action on the switch, whichever slot that is; the other slot
    -- still picks (or keeps) its own move
    battle.__dbSwitchConfirm = function(self)
      local aimed = self.__dbSwitchAim or self.player
      self:__dbSwitchReset()
      local mon = self.__dbSwitchMon
      self.__dbSwitchMon = nil
      if not mon then
        self.phase = "menu"
        return
      end
      if aimed == self.player then
        -- the picking slot recalls itself: the switch is this pass's
        -- action, and the pass flow carries on as if a move was picked
        self:resolveTurn({ dbSwitch = mon })
        return
      end
      if aimed ~= self.player2 then
        self.phase = "menu"
        return
      end
      if self.__dbSwapped then
        -- pass B aiming at the already-banked lead: its pick is voided
        -- by its own recall, and the partner keeps choosing
        self.__dbSlotA = { user = aimed, action = { dbSwitch = mon } }
      else
        -- pass A aiming at the partner: bank the recall as the
        -- partner's action, the lead keeps choosing, pass B is skipped
        self.__dbForcedB = { user = aimed, mon = mon }
      end
      self.phase = "menu"
    end

    -- the swap itself, executed as a turn entry before any move (gen
    -- 1's own order: switches resolve first, then the hits land)
    battle.__dbExecuteSwitch = function(self, outgoing, newMon)
      if self.result then return end
      if not newMon or (newMon.hp or 0) <= 0 then
        log.warn("recall dropped: the bench mon cannot fight")
        return
      end
      if (self.player and self.player.mon == newMon)
         or (self.player2 and self.player2.mon == newMon) then
        log.warn("recall dropped: the bench mon is already out")
        return
      end
      local isLead = outgoing == self.player
      if not isLead and outgoing ~= self.player2 then
        log.warn("recall dropped: the recalled mon left its slot")
        return
      end
      local BattleState = require("src.battle.BattleState")
      local Runtime = require("src.mods.Runtime")
      local okB, nb = pcall(BattleState.makeBattler, self.data, newMon,
                            true, self.game.save)
      if not (okB and nb) then
        log.warn("recall dropped: battler build failed: %s",
                     tostring(nb))
        return
      end
      log.info("recall: %s steps back for %s (%s slot)",
                   tostring(outgoing.name), tostring(nb.name),
                   isLead and "lead" or "partner")
      pcall(function() self:restoreMimicked(outgoing) end)
      nb.dbAnchor = outgoing.dbAnchor or (isLead and 1 or 2)
      if isLead then
        self.player = nb
      else
        self.player2 = nb
        -- the HUD borrow follows the incoming partner through its send
        self.__dbFocus = nb
      end
      -- later entries this turn may still aim at the withdrawn body
      self.__dbReplaced = self.__dbReplaced or {}
      self.__dbReplaced[outgoing] = nb
      -- SendOutMon: any player send-out ends the foes' trapping moves
      for _, foe in ipairs({ self.enemy, self.enemy2 }) do
        if foe then
          foe.trappingTurns, foe.trapMove, foe.trapDamage = nil, nil, nil
        end
      end
      self:syncSides()
      self:markParticipant()
      Runtime.emit("battle.battler_switched", {
        battle = self, side = self.sides[1], battler = nb,
        previous = outgoing,
      })
      -- SendOutMon puts the menus back on FIGHT / the first move
      self.menuIndex, self.moveIndex = 1, 1
      self:sayNext(self:sendOutText(nb.name))
      self:animNext("POOF_ANIM", false)
      if isLead then self.sendingOut = true end
      self:actNext(function()
        if isLead then
          self.sendingOut = false
          self:startGrowIn(nb)
        end
        self:playEntranceCry(nb)
      end)
    end

    -- pic effects (the attacker's lunge, DIG's hide, the target blink)
    -- resolve their battler from a side flag, which the engine maps to
    -- the slot LEAD -- so a partner's attack visibly played on the
    -- lead.  While an action involves a partner, the same side flag
    -- resolves to the battler the action actually involves.
    local origFxBattler = battle.animFxBattler
    if type(origFxBattler) == "function" then
      battle.animFxBattler = function(self, flipped)
        local isPlayer = self.animAttackerIsPlayer
        if flipped then isPlayer = not isPlayer end
        local function onSide(b)
          if b ~= self.player2 and b ~= self.enemy2 then return nil end
          if (b == self.player2) == (isPlayer == true) then return b end
          return nil
        end
        -- the attacker's own side prefers the acting user; the far
        -- side prefers the action's target
        local hit = onSide(self.__dbActingUser)
          or onSide(self.__dbActingTarget)
        if hit then return hit end
        return origFxBattler(self, flipped)
      end
    end

    -- exp awards inside this battle carry the doubles marker for the
    -- exp.gain wrap above
    local origAward = battle.awardExp
    battle.awardExp = function(self)
      expActive = self
      local okA, errA = pcall(origAward, self)
      expActive = nil
      if not okA then error(errA) end
    end

    -- both partners fought: they all share the exp bookkeeping
    local origMark = battle.markParticipant
    battle.markParticipant = function(self)
      origMark(self)
      if alive(self.player2) then
        self.participants = self.participants or {}
        self.participants[self.player2.mon] = true
      end
    end
    battle:markParticipant()

    -- class item/switch AI doesn't understand two slots (its switch
    -- scan can duplicate the benched-in partner): while the pair is up
    -- the lead foe just picks moves; the battle.enemy_action hook
    -- still gets the final word
    local origVanillaAction = battle.vanillaEnemyAction
    if type(origVanillaAction) == "function" then
      battle.vanillaEnemyAction = function(self)
        if self.kind == "trainer" and alive(self.enemy2) then
          local locked = self.lockedAction and self:lockedAction(self.enemy)
          if locked then return locked end
          local TrainerAI = require("src.battle.TrainerAI")
          local okA, act = pcall(TrainerAI.chooseMove, self.enemy,
                                 self.rng, self)
          if okA and act then return act end
        end
        return origVanillaAction(self)
      end
    end

    -- ------- the turn

    -- action collection runs the vanilla menu twice when your pair is
    -- up: pass A stashes the lead's choice, the slots swap so the menu
    -- (and the HUD under it) belongs to the partner, pass B collects
    -- its choice, and the slots swap back before anything executes
    battle.resolveTurn = function(self, playerAction)
      -- a lingering aim swap must never leak into turn logic
      if self.__dbAimSwapped then self:__dbAimReset() end
      if self.__dbSwitchSwapped then self:__dbSwitchReset() end
      -- both foes up and a move picked: ask which one to aim at
      -- (update/overlay decorations own the db_target phase)
      if playerAction and playerAction.id and not self.__dbTarget
         and not SPREAD[playerAction.id]
         and alive(self.enemy2) and alive(self.enemy) then
        self.__dbPending = playerAction
        self:__dbAimAt(self.enemy)
        self.phase = "db_target"
        return
      end
      local chosen = self.__dbTarget
      self.__dbTarget = nil

      if alive(self.player2) and not self.__dbSlotA then
        local forced = self.__dbForcedB
        self.__dbForcedB = nil
        if forced and forced.user ~= self.player2 then
          log.warn("stale partner recall dropped: the slot moved on")
        end
        if forced and forced.user == self.player2 then
          -- the partner's recall was chosen during pass A: its action
          -- is spoken for, so there is no second menu pass
          self.__dbSlotA = { user = self.player, action = playerAction,
                             target = chosen }
          self.__dbSlotB = { user = forced.user,
                             action = { dbSwitch = forced.mon } }
        else
          -- pass A banked; the partner picks next
          self.__dbSlotA = { user = self.player, action = playerAction,
                             target = chosen }
          self.player, self.player2 = self.player2, self.player
          self.__dbSwapped = true
          self:syncSides()
          self.phase = "menu"
          return
        end
      end

      local slotA = self.__dbSlotA
      self.__dbSlotA = nil
      local slotB
      if self.__dbSwapped then
        slotB = { user = self.player, action = playerAction,
                  target = chosen }
        self.player, self.player2 = self.player2, self.player
        self.__dbSwapped = false
        self:syncSides()
      end
      slotB = slotB or self.__dbSlotB
      self.__dbSlotB = nil

      local Runtime = require("src.mods.Runtime")
      local TurnOrder = require("src.battle.TurnOrder")
      local TrainerAI = require("src.battle.TrainerAI")

      -- foes pick a target first (piling on a hurt slot), then score
      -- their move against that exact target: TrainerAI reads
      -- battle.player, so the slot is borrowed for the scoring call
      local function hurtFrac(b)
        local maxHP = (b.curStats and b.curStats.hp)
          or (b.mon.stats and b.mon.stats.hp) or 1
        return b.mon.hp / math.max(1, maxHP)
      end
      local function foeTarget()
        local mine = {}
        if alive(self.player) then mine[#mine + 1] = self.player end
        if alive(self.player2) then mine[#mine + 1] = self.player2 end
        if #mine == 0 then return self.player end
        if #mine == 2 then
          local fracA, fracB = hurtFrac(mine[1]), hurtFrac(mine[2])
          if fracA < 0.35 and fracA < fracB then return mine[1] end
          if fracB < 0.35 and fracB < fracA then return mine[2] end
        end
        return mine[love.math.random(#mine)]
      end
      local function chooseVs(attacker, target)
        local realPlayer = self.player
        self.player = target
        local okA, act = pcall(TrainerAI.chooseMove, attacker,
                               self.rng, self)
        self.player = realPlayer
        return okA and act or nil
      end
      local e1Target = foeTarget()
      local e1
      if self.kind == "wild" then
        e1 = chooseVs(self.enemy, e1Target) or self:enemyAction()
      else
        e1 = self:enemyAction()
      end
      local e2, e2Target
      if alive(self.enemy2) then
        e2Target = foeTarget()
        e2 = chooseVs(self.enemy2, e2Target)
      end

      self.turnCount = (self.turnCount or 0) + 1
      Runtime.emit("battle.turn_started", {
        battle = self, turn = self.turnCount,
        playerAction = (slotA or {}).action or playerAction,
        enemyAction = e1, enemyAction2 = e2,
      })

      local moves = self.data.moves
      local function mv(a) return a and a.id and moves[a.id] or nil end
      local entries = {}
      if slotA then
        entries[#entries + 1] = slotA
        if slotB then entries[#entries + 1] = slotB end
      else
        entries[#entries + 1] = { user = self.player,
                                  action = playerAction, target = chosen }
      end
      entries[#entries + 1] = { user = self.enemy, action = e1,
                                target = e1Target }
      if e2 then
        entries[#entries + 1] = { user = self.enemy2, action = e2,
                                  target = e2Target }
      end

      -- switches resolve before anything moves (gen 1's own free-hit
      -- order); the rest gets the engine comparator's speed and ties
      local ordered, movers = {}, {}
      for _, entry in ipairs(entries) do
        if entry.action and entry.action.dbSwitch then
          ordered[#ordered + 1] = entry
        else
          movers[#movers + 1] = entry
        end
      end
      for _, entry in ipairs(movers) do
        local at = #ordered + 1
        for i, other in ipairs(ordered) do
          if other.action and other.action.dbSwitch then
            -- switches keep the front of the queue
          elseif TurnOrder.firstMover(entry.user, mv(entry.action),
                                      other.user, mv(other.action),
                                      self.rng) then
            at = i
            break
          end
        end
        table.insert(ordered, at, entry)
      end

      self.phase = "messages"
      self.afterQueue = "menu"
      local gen1Timing = not self.ruleset
        or self.ruleset.residualAfterMove ~= false
      for _, entry in ipairs(ordered) do
        self:act(function()
          local user = entry.user
          if not alive(user) then return end
          if entry.action and entry.action.dbSwitch then
            self.__dbAnimShift = self:__dbShiftFor(user, nil)
            self.__dbActingUser = user
            self.__dbActingTarget = nil
            self.__dbFocus = (user == self.player2) and self.player2
              or nil
            self:__dbExecuteSwitch(user, entry.action.dbSwitch)
            return
          end
          local target = entry.target
          -- a switch earlier this turn may have withdrawn the body this
          -- entry was aimed at; the hit follows the replacement
          while target and self.__dbReplaced
                and self.__dbReplaced[target] do
            target = self.__dbReplaced[target]
          end
          local onMySide = (user == self.player or user == self.player2)
          if not alive(target) then
            if onMySide then
              target = alive(self.enemy) and self.enemy or self.enemy2
            else
              target = alive(self.player) and self.player or self.player2
            end
          end
          if not alive(target) then return end
          -- the shift holds until the next action's act overwrites it,
          -- which is exactly the lifetime of this action's animations
          self.__dbAnimShift = self:__dbShiftFor(user, target)
          self.__dbActingUser = user
          self.__dbActingTarget = target
          self.__dbFocus = (target == self.enemy2 or user == self.enemy2)
              and self.enemy2
            or (target == self.player2 or user == self.player2)
              and self.player2
            or nil
          local okX, err = pcall(self.executeAction, self, user, target,
                                 entry.action)
          if not okX then
            log.warn("double action failed: %s", tostring(err))
          end
          local kind = okX and entry.action and entry.action.id
            and SPREAD[entry.action.id]
          if kind then
            self:actNext(function()
              self:__dbSpreadRipple(user, target, entry.action, kind)
            end)
          end
        end)
        if gen1Timing and (entry.user == self.enemy2
                           or entry.user == self.player2) then
          local who = entry.user
          self:act(function() self:partnerResidual(who) end)
        end
      end
      self:act(function()
        self.__dbAnimShift = nil
        self.__dbFocus = nil
        self.__dbActingUser = nil
        self.__dbActingTarget = nil
        self:endOfTurn()
      end)
    end

    -- spread ripple: every other battler the move reaches takes a
    -- reduced hit through the engine's own accuracy and damage rolls
    battle.__dbSpreadRipple = function(self, user, primary, action, kind)
      if self.result or not alive(user) then return end
      local move = self.data.moves[action.id]
      if not move or (move.power or 0) <= 0 then return end
      local extras = {}
      local function add(b)
        if b and b ~= primary and b ~= user and alive(b) then
          extras[#extras + 1] = b
        end
      end
      local onMySide = (user == self.player or user == self.player2)
      if onMySide then
        add(self.enemy)
        add(self.enemy2)
        if kind == "others" then
          add(user == self.player2 and self.player or self.player2)
        end
      else
        add(self.player)
        add(self.player2)
        if kind == "others" then
          add(user == self.enemy2 and self.enemy or self.enemy2)
        end
      end
      for _, victim in ipairs(extras) do
        if alive(user) and alive(victim) then
          local hit = true
          pcall(function()
            hit = self:accuracyRoll(move, user, victim) and true or false
          end)
          if hit then
            local dmg = 0
            local okD = pcall(function()
              dmg = self:computeDamage(user, victim, move) or 0
            end)
            dmg = math.floor((tonumber(dmg) or 0) * 0.75)
            if okD and dmg > 0 then
              self:sayNext(Strings("It also hit\n%s!",
                monName(self.data, victim.mon)))
              victim.mon.hp = math.max(0, victim.mon.hp - dmg)
              self:drainNext()
              if victim.mon.hp <= 0 then self:onFaint(victim) end
            end
          end
        end
      end
    end

    -- the engine's residualFor refuses battlers it doesn't know, so
    -- both partners get their own poison/burn/seed sweep
    battle.partnerResidual = function(self, b)
      if not b or b ~= self.enemy2 and b ~= self.player2 then return end
      if self.result or not alive(b) then return end
      local opp = (b == self.enemy2) and self.player or self.enemy
      if not alive(opp) then return end
      local Status = require("src.battle.Status")
      local okR, msgs = pcall(Status.residual, b, opp, self)
      if not (okR and msgs) then return end
      for _, m in ipairs(msgs) do self:sayNext(m) end
      if #msgs > 0 then self:drainNext() end
      if b.mon.hp <= 0 then self:onFaint(b) end
    end

    local origEndOfTurn = battle.endOfTurn
    battle.endOfTurn = function(self)
      origEndOfTurn(self)
      -- the modern ruleset sweeps residuals at end of round instead
      if self.ruleset and self.ruleset.residualAfterMove == false then
        self:partnerResidual(self.enemy2)
        self:partnerResidual(self.player2)
      end
      -- a recall that never executed (a failed RUN took the turn), the
      -- withdrawn-body map and a ball throw's animation shift all
      -- expire at the turn boundary
      self.__dbForcedB = nil
      self.__dbReplaced = nil
      self.__dbAnimShift = nil
    end

    -- a ball with two wild Pokémon up is aimed like a move: the throw
    -- defers into the db_target prompt, and the confirm COMMITS the aim
    -- swap so the whole vanilla catch pipeline (rate, shakes, the
    -- caught-mon storage, the miss free move) reads the aimed foe from
    -- the lead slot.  Paths that reach catchAttempt without the prompt
    -- (a mod calling it directly) keep the old refusal.
    local origCatch = battle.catchAttempt
    battle.catchAttempt = function(self, ball, rateOverride)
      if self.kind == "wild" and alive(self.enemy2)
         and not self.__dbBallAimed then
        self:sayNext(Strings("No aiming with\ntwo POKéMON out!"))
        return false, 0
      end
      self.__dbBallAimed = nil
      return origCatch(self, ball, rateOverride)
    end

    local origThrow = battle.throwBall
    if type(origThrow) == "function" then
      battle.throwBall = function(self, ball)
        if self.kind ~= "wild"
           or not (alive(self.enemy) and alive(self.enemy2)) then
          return origThrow(self, ball)
        end
        self.__dbPendingBall = ball
        self:__dbAimAt(self.enemy)
        self.phase = "db_target"
      end
    end

    battle.__dbBallConfirm = function(self)
      local ball = self.__dbPendingBall
      self.__dbPendingBall = nil
      if not ball then return end
      -- commit, don't reset: everything the throw queues (including
      -- the caught-mon storage) reads the lead slot at run time
      self.__dbAimSwapped = nil
      self.__dbAimBattler = nil
      self.__dbBallAimed = true
      -- the toss animation is authored on the vanilla slot; carry it
      -- to wherever the aimed foe actually stands
      self.__dbAnimShift = self:__dbShiftFor(nil, self.enemy)
      self.phase = "messages"
      self.afterQueue = "menu"
      origThrow(self, ball)
    end
    battle.__dbBallCancel = function(self)
      local ball = self.__dbPendingBall
      self.__dbPendingBall = nil
      self:__dbAimReset()
      -- the bag consumed the ball before the throw deferred; backing
      -- out hands it back
      if ball then
        pcall(function()
          require("src.inventory.Bag").add(self.game.save, ball, 1,
                                           self.data)
        end)
      end
      self.phase = "menu"
    end

    -- the db_target phase: LEFT/RIGHT swap foes, A locks in, B backs
    -- out to the move menu; everything else stays vanilla
    local origUpdate = battle.update
    battle.update = function(self, dt)
      -- a lead menu with a banked pass-A action is stale state left by
      -- a path that never resolved (a failed RUN): drop the bank
      if self.phase == "menu" and self.__dbSlotA
         and not self.__dbSwapped then
        self.__dbSlotA = nil
      end
      if self.phase == "db_switch_target" then
        local input = self.game.input
        if input:wasPressed("left") or input:wasPressed("right")
           or input:wasPressed("up") or input:wasPressed("down") then
          self:__dbSwitchAimAt(self.player2)
        elseif input:wasPressed("a") then
          self:__dbSwitchConfirm()
        elseif input:wasPressed("b") then
          self:__dbSwitchReset()
          self.__dbSwitchMon = nil
          self.phase = "menu"
        end
        return
      end
      if self.phase ~= "db_target" then
        if self.__dbAimSwapped then self:__dbAimReset() end
        if self.__dbSwitchSwapped then self:__dbSwitchReset() end
        return origUpdate(self, dt)
      end
      local input = self.game.input
      if input:wasPressed("left") or input:wasPressed("right")
         or input:wasPressed("up") or input:wasPressed("down") then
        self:__dbAimAt(self.enemy2)
      elseif input:wasPressed("a") then
        if self.__dbPendingBall then
          self:__dbBallConfirm()
          return
        end
        local t = self.__dbAimBattler or self.enemy
        if not alive(t) then
          t = alive(self.enemy) and self.enemy or self.enemy2
        end
        self:__dbAimReset()
        self.__dbTarget = t
        local action = self.__dbPending
        self.__dbPending = nil
        self:resolveTurn(action)
      elseif input:wasPressed("b") then
        if self.__dbPendingBall then
          self:__dbBallCancel()
          return
        end
        self:__dbAimReset()
        self.__dbPending = nil
        self.phase = "moveSelect"
      end
    end

    -- ------- faints: partners fall away, leads get replaced by them

    local origOnFaint = battle.onFaint
    battle.onFaint = function(self, battler)
      if battler == self.enemy2 then
        if battler.faintQueued then return end
        battler.faintQueued = true
        local Runtime = require("src.mods.Runtime")
        Runtime.emit("battle.fainted", { battle = self, battler = battler })
        pcall(function()
          require("src.core.Sound").playCry(self.data, battler.mon.species)
        end)
        self:sayNext(Strings("Wild %s\nfainted!", battler.name))
        pcall(function()
          mod.events:emit("mod.double_battles.partner_fainted",
            { battle = self, side = 2, species = battler.mon.species })
        end)
        local lead = self.enemy
        self.enemy = battler
        local okE, err = pcall(self.awardExp, self)
        self.enemy = lead
        if not okE then
          log.warn("exp for second foe failed: %s", tostring(err))
        end
        self.enemy2 = (self.__dbRefill and self:__dbRefill()) or nil
        if self.enemy2 then
          pcall(function()
            mod.events:emit("mod.double_battles.partner_joined",
              { battle = self, side = 2,
                species = self.enemy2.mon.species })
          end)
        end
        self:syncSides()
        return
      end
      if battler == self.player2 then
        if battler.faintQueued then return end
        battler.faintQueued = true
        local Runtime = require("src.mods.Runtime")
        if self.participants then self.participants[battler.mon] = nil end
        Runtime.emit("battle.fainted", { battle = self, battler = battler })
        pcall(function()
          require("src.core.Sound").playCry(self.data, battler.mon.species)
        end)
        self:sayNext(Strings("%s\nfainted!", battler.name))
        pcall(function()
          mod.events:emit("mod.double_battles.partner_fainted",
            { battle = self, side = 1, species = battler.mon.species })
        end)
        self.player2 = nil
        self:syncSides()
        return
      end
      return origOnFaint(self, battler)
    end

    -- the lead foe's faint: pay it out, then the second steps up and
    -- vanilla handles whatever the fight has become
    local origEnemyFainted = battle.enemyMonFainted
    battle.enemyMonFainted = function(self)
      if not alive(self.enemy2) then return origEnemyFainted(self) end
      local okE, err = pcall(self.awardExp, self)
      if not okE then
        log.warn("exp for lead foe failed: %s", tostring(err))
      end
      -- trainer pairs replace the lead from its own trainer's bench
      -- rather than promoting the partner (which belongs to trainer B)
      if self.__dbLeadFaint and self:__dbLeadFaint() then return end
      local Runtime = require("src.mods.Runtime")
      local previous = self.enemy
      self.enemy = self.enemy2
      if self.__dbOnPromote then self:__dbOnPromote() end
      self.enemy2 = (self.__dbRefill and self:__dbRefill()) or nil
      -- a lone survivor steps into the vanilla slot for the 1v1
      -- endgame; the partner slot draws half-size in classic
      if not self.enemy2 then self.enemy.dbAnchor = 1 end
      self:syncSides()
      self:markParticipant()
      Runtime.emit("battle.battler_switched", {
        battle = self, side = self.sides[2], battler = self.enemy,
        previous = previous,
      })
      if self.enemy2 then
        Runtime.emit("battle.battler_switched", {
          battle = self, side = self.sides[2], battler = self.enemy2,
        })
      end
      if self.kind == "wild" then
        self:sayNext(Strings("Wild %s is\nstill in the fight!",
                             self.enemy.name))
      end
    end

    -- your lead's faint with a partner up: the partner slides into the
    -- lead slot and the fight goes on; the bench menu is vanilla's job
    -- once the pair is down to one
    local origPlayerFainted = battle.playerMonFainted
    battle.playerMonFainted = function(self)
      if not alive(self.player2) then return origPlayerFainted(self) end
      local Runtime = require("src.mods.Runtime")
      local previous = self.player
      self.player = self.player2
      self.player2 = nil
      -- the promoted partner takes the vanilla back-sprite slot
      self.player.dbAnchor = 1
      self:syncSides()
      Runtime.emit("battle.battler_switched", {
        battle = self, side = self.sides[1], battler = self.player,
        previous = previous,
      })
      self:sayNext(Strings("%s stands\nits ground!", self.player.name))
    end

    -- the engine only announces lead battlers, so mods doing
    -- per-battler setup off battle.battler_switched (Crystal 251
    -- attaches its Gen 2 stat model there) would never meet the
    -- second slots.  Announce them the moment the pair forms.
    do
      local Runtime = require("src.mods.Runtime")
      pcall(function() battle:syncSides() end)
      if battle.enemy2 then
        Runtime.emit("battle.battler_switched", {
          battle = battle, side = battle.sides and battle.sides[2],
          battler = battle.enemy2,
        })
      end
      if battle.player2 then
        Runtime.emit("battle.battler_switched", {
          battle = battle, side = battle.sides and battle.sides[1],
          battler = battle.player2,
        })
      end
    end

    return battle
  end

  -- ------- drawing: every battler on screen at once

  -- classic 160px tucks the partners inside the frame; wide 304px has
  -- honest room in each side's region
  -- the target menu: a vanilla-style box in the text area naming both
  -- candidates, cursor on the aimed one.  Anchored to the right edge
  -- like the FIGHT menu, in classic, wide and 3D alike (the classic UI
  -- canvas rides into the 3D letterbox, so the box lands where every
  -- other battle menu does there).
  local function drawAimMenu(battle, first, second, aimed)
    pcall(function()
      if (first.dbAnchor or 1) == 2 then first, second = second, first end
      local Font = require("src.render.Font")
      local bx = math.floor((battle.wideRegion and 304 or 160) / 8) - 12
      Font.drawBox(bx, 12, 12, 6)
      love.graphics.setColor(0, 0, 0, 1)
      for i, b in ipairs({ first, second }) do
        local rowY = 96 + i * 16 - 8
        Font.draw(b.name or "?", bx * 8 + 16, rowY)
        if b == aimed then Font.drawCode(0xED, bx * 8 + 8, rowY) end
      end
      love.graphics.setColor(1, 1, 1, 1)
    end)
  end

  mod.hooks:wrap("battle.overlay", function(next, battle)
    next(battle)
    if type(battle) ~= "table" or not battle.__double then return end
    -- the sprite frames are 2D-only (a scene owner stages the mons in
    -- its own space); the name menu draws everywhere.  The vanilla HUD
    -- box follows the aim too (drawHUDs borrow), so the frame marks
    -- the sprite, the box shows its health, and the menu names both.
    local scene = sceneActive(battle)
    if battle.phase == "db_target" then
      local aimed = battle.__dbAimBattler or battle.enemy
      if battle.enemy and battle.enemy2 then
        drawAimMenu(battle, battle.enemy, battle.enemy2, aimed)
      end
      -- the aimed foe holds the lead slot while the prompt is up; the
      -- frame still lands on its sprite because foeRect keys off the
      -- battler's own sticky anchor, not the slot
      if not scene and aimed
         and math.floor(love.timer.getTime() * 4) % 2 == 0 then
        local tx, ty, tw = foeRect(battle, aimed)
        love.graphics.setColor(1, 0.2, 0.2, 1)
        love.graphics.rectangle("line", tx, ty, tw, tw)
        love.graphics.setColor(1, 1, 1, 1)
      end
    end
    if battle.phase == "db_switch_target" then
      local aimed = battle.__dbSwitchAim or battle.player
      if battle.player and battle.player2 then
        drawAimMenu(battle, battle.player, battle.player2, aimed)
      end
      -- same cue on your own side: the frame marks the mon about to
      -- step back for the bench pick
      if not scene and aimed
         and math.floor(love.timer.getTime() * 4) % 2 == 0 then
        local tx, ty, tw = allyRect(battle, aimed)
        love.graphics.setColor(0.2, 1, 0.4, 1)
        love.graphics.rectangle("line", tx, ty, tw, tw)
        love.graphics.setColor(1, 1, 1, 1)
      end
    end
  end)

  -- ------- pointer aiming
  -- clicking (or tapping) a foe during the target prompt aims at it;
  -- clicking the aimed foe locks it in.  The render.hud viewport gives
  -- the window-to-native mapping each frame; anything unhandled passes
  -- straight through so other pointer mods are unaffected.
  local lastViewport = nil
  mod.hooks:wrap("render.hud", function(next, game, viewport)
    lastViewport = viewport
    return next(game, viewport)
  end)

  mod.hooks:wrap("input.pointer", function(next, game, ev)
    if not (ev and ev.phase == "pressed") then return next(game, ev) end
    local st = game.stack and game.stack.top and game.stack:top()
    local aiming = st and st.__double
      and (st.phase == "db_target" or st.phase == "db_switch_target")
    if not aiming then return next(game, ev) end
    local vp = lastViewport
    if not (vp and vp.scale and vp.scale > 0) then return next(game, ev) end
    local nx = (ev.x - (vp.gameX or 0)) / vp.scale
    local ny = (ev.y - (vp.gameY or 0)) / vp.scale
    local function inside(b, rect)
      if not alive(b) then return false end
      local x, y, w = rect(st, b)
      return nx >= x and nx <= x + w and ny >= y and ny <= y + w
    end
    if st.phase == "db_switch_target" then
      local hitB
      if inside(st.player, allyRect) then
        hitB = st.player
      elseif inside(st.player2, allyRect) then
        hitB = st.player2
      end
      if not hitB then return next(game, ev) end
      if hitB == st.__dbSwitchAim then
        st:__dbSwitchConfirm()
      else
        st:__dbSwitchAimAt(hitB)
      end
      return true
    end
    local hitB
    if inside(st.enemy, foeRect) then
      hitB = st.enemy
    elseif inside(st.enemy2, foeRect) then
      hitB = st.enemy2
    end
    if not hitB then return next(game, ev) end
    if hitB == st.__dbAimBattler then
      if st.__dbPendingBall then
        st:__dbBallConfirm()
        return true
      end
      st:__dbAimReset()
      st.__dbTarget = hitB
      local action = st.__dbPending
      st.__dbPending = nil
      st:resolveTurn(action)
    else
      st:__dbAimAt(hitB)
    end
    return true
  end)

  -- ------- entry points

  -- organic doubles: wild battles reaching the overworld's push seam
  -- roll the option.  When wild_skies has a visible bird nearby, the
  -- push defers while that bird flies to the player and becomes the
  -- second foe, its real species and level and all; otherwise (or when
  -- the swoop fails) the partner rolls from the encounter list.
  -- the held-battle record lives on the OC module, not in a closure:
  -- hot reloads swap this mod's closures but every generation must see
  -- the same pending state, or a reload strands it forever
  local function pendingBox()
    local OC = require("src.world.OverworldController")
    OC.__doubleBattlesPendingBox = OC.__doubleBattlesPendingBox or {}
    return OC.__doubleBattlesPendingBox
  end

  mod.events:on("mod.wild_skies.flyer_summoned", function(ev)
    local box = pendingBox()
    local pending = box.current
    if not (pending and ev and ev.summonId == pending.summonId) then return end
    box.current = nil
    local p = pending
    local Game = require("src.core.Game")
    decorate(Game, p.battle, ev.species, ev.level)
    p.battle.__dbRecruited = true
    p.push(p.battle)
  end)

  -- the Dramatic Shape adapter teaches its 3D billboards and HUD
  -- texture about our second battlers; loaded lazily so a missing or
  -- disabled voxel mod costs nothing
  local sceneAdapter = false
  local function loadSceneAdapter()
    return nil
  end

  -- our own broadcast channel: trackers see doubles without touching
  -- private fields
  mod.events:on("battle.started", function(ev)
    local b = ev and ev.battle
    if not (b and b.__double) then return end
    local adapter = loadSceneAdapter()
    if adapter and adapter.tryInstall then pcall(adapter.tryInstall) end
    pcall(function()
      mod.events:emit("mod.double_battles.double_started", {
        battle = b,
        format = b.__dbSideB and "pair"
          or b.kind == "trainer" and "trainer"
          or (b.player2 and "2v2" or "1v2"),
        recruited = b.__dbRecruited == true,
      })
    end)
  end)

  mod.events:on("mod.wild_skies.summon_failed", function(ev)
    local box = pendingBox()
    local pending = box.current
    if not (pending and ev and ev.summonId == pending.summonId) then return end
    box.current = nil
    local p = pending
    local Game = require("src.core.Game")
    local nowMap = Game.overworld and Game.overworld.map
      and Game.overworld.map.id
    if p.mapId and nowMap and p.mapId ~= nowMap then return end
    local sp, lv = providerPartner(Game, p.battle, 50, math.huge)
    if not sp then sp, lv = rollPartner(Game, p.battle) end
    ensurePartner(Game, p.battle, sp, lv)
    p.push(p.battle)
  end)

  -- a map change orphans the deferred battle: it never starts
  mod.events:on("map.exited", function() pendingBox().current = nil end)

  do
    local OC = require("src.world.OverworldController")
    if not OC.__doubleBattlesWrapped then
      OC.__doubleBattlesWrapped = true
      OC.__doubleBattlesOrigPush = OC.pushBattle
      OC.pushBattle = function(self, battle)
        local hook = OC.__doubleBattlesDecorate
        if hook and hook(self, battle) then return end -- deferred
        return OC.__doubleBattlesOrigPush(self, battle)
      end
    end
    -- returns true when the battle is held for a swoop-in
    OC.__doubleBattlesDecorate = function(owSelf, battle)
      -- Double battles are special events/NPCs and not applied randomly to regular overworld encounters
      return false
    end
    local function _legacyDecorate(owSelf, battle)
      local Game = require("src.core.Game")
      if battle and battle.kind == "trainer" and not battle.__double
         and not battle.dead then
        -- a registered pair source gets first refusal: a second
        -- trainer joining beats the same trainer sending two.  A
        -- refused class falls back to the ordinary trainer double.
        local oppB, idxB = providerPair(Game, battle)
        if oppB then
          decoratePair(Game, battle, oppB, idxB)
        end
        if not battle.__double then
          decorateTrainer(Game, battle)
        end
        return false
      end
      if not (battle and battle.kind == "wild" and not battle.__double
              and not battle.dead) then
        return false
      end
      if battle.safari or battle.ghost or battle.demo then
        log.info("doubles declined: special battle format")
        return false
      end
      local vetoId = vetoedBy(Game, battle)
      if vetoId then
        log.info("doubles declined: vetoed by %s", tostring(vetoId))
        return false
      end
      log.info("doubles: wild battle seen (option=%s)",
                   tostring(options:get("wild_doubles")))
      local box = pendingBox()
      -- story battles launched by scripts (Snorlax, the legendaries)
      -- stay 1v1 unless the launching mod tagged itself organic
      local now = love.timer.getTime()
      local organic = box.organicUntil and now < box.organicUntil
      local scripted = box.scriptedUntil and now < box.scriptedUntil
      box.organicUntil, box.scriptedUntil = nil, nil
      if scripted and not organic then
        -- Wilds of Kanto's visible-mon touch battles arrive as scripts
        -- too, but they're organic encounters.  Its pendingBattle
        -- marker is set before the battle queues and held through it;
        -- the touched entity itself is already despawned, so the live
        -- spawn list can't be trusted for this.
        local isWilds = false
        pcall(function()
          local wilds = Game.mods and Game.mods.exports
            and Game.mods.exports.overworld_wild_spawns
          local logic = wilds and wilds.logic
          if logic and logic.pendingBattle then isWilds = true end
        end)
        if not isWilds then
          log.info("doubles declined: scripted battle (story)")
          return false
        end
      end
      if box.current then
        -- another wild battle (a bump, an interception) beat the
        -- summoned bird to it: drop the held encounter and give THIS
        -- battle a partner right away instead of letting it slip 1v1
        box.current = nil
        local sp, lv = providerPartner(Game, battle, 50, math.huge)
        if not sp then sp, lv = rollPartner(Game, battle) end
        ensurePartner(Game, battle, sp, lv)
        return false
      end
      local chance = doubleChance()
      if love.math.random() >= chance then
        if chance >= 1 then
          log.warn("doubles declined despite ALWAYS; report this")
        end
        return false
      end
      -- registered sources ahead of the bird get first refusal
      local spEarly, lvEarly = providerPartner(Game, battle,
                                               -math.huge, 50)
      if spEarly then
        ensurePartner(Game, battle, spEarly, lvEarly)
        return false
      end
      local ws = mod.find("wild_skies")
      local summon = ws and ws.exports and ws.exports.summonFlyer
      local p = Game.overworld and Game.overworld.player
      if summon and p then
        local okS, sid = pcall(summon, p.cellX, p.cellY, { radius = 8 })
        if okS and sid then
          box.current = {
            battle = battle, summonId = sid,
            deadline = love.timer.getTime() + 6,
            mapId = Game.overworld.map and Game.overworld.map.id,
            push = function(b) OC.__doubleBattlesOrigPush(owSelf, b) end,
          }
          return true
        end
      end
      local sp, lv = providerPartner(Game, battle, 50, math.huge)
      if not sp then sp, lv = rollPartner(Game, battle) end
      ensurePartner(Game, battle, sp, lv)
      return false
    end
  end

  -- a few calm steps after one of our doubles ends, so the next fight
  -- never starts on the very next blade of grass; a won pair battle
  -- also pays out the first trainer's banked prize here
  local breatherSteps = 0
  mod.events:on("battle.ended", function(ev)
    if ev and ev.battle and ev.battle.__double then breatherSteps = 4 end
    local b = ev and ev.battle
    local extra = b and b.__dbExtraPayout
    if extra and extra > 0 then
      b.__dbExtraPayout = nil
      if ev.result == "win" then
        local Game = require("src.core.Game")
        if Game.save then
          Game.save.money = math.min(999999, (Game.save.money or 0) + extra)
          log.info("paid the first trainer's prize: %d", extra)
        end
      end
    end
  end)
  mod.events:on("world.stepped", function()
    if breatherSteps > 0 then breatherSteps = breatherSteps - 1 end
  end)
  mod.hooks:wrap("encounter.roll", function(next, encDef, ctx)
    local box = pendingBox()
    -- a summon whose ending never arrived (lost events, hot reload)
    -- expires here instead of muting encounters forever
    if box.current and love.timer.getTime() > (box.current.deadline or 0) then
      box.current = nil
    end
    if breatherSteps > 0 or box.current then return nil end
    return next(encDef, ctx)
  end)

  -- ------- public API

  -- every engine path that pushes a battle wires onFinish to
  -- afterBattle, the seam that revives the party and warps to the heal
  -- point on a loss.  A battle pushed without it strands the player on
  -- the map with a fainted party after a wipe, so ours wire it too.
  local function wireFinish(ow, battle)
    if battle.onFinish then return end
    battle.onFinish = function(result)
      if ow.afterBattle then ow:afterBattle(result, battle) end
    end
  end

  -- start a double on demand (scenario mods, scripts, tests)
  mod.exports.startWildDouble = function(spA, lvA, spB, lvB)
    local Game = require("src.core.Game")
    local ow = Game.overworld
    if not (ow and ow.pushBattle) then return false, "no overworld" end
    local BattleState = require("src.battle.BattleState")
    local okN, battle = pcall(BattleState.newWild, Game, spA, lvA)
    if not (okN and battle) or battle.dead then
      return false, "battle refused"
    end
    decorate(Game, battle, spB, lvB or lvA)
    if not battle.__double then return false, "decoration refused" end
    wireFinish(ow, battle)
    ow:pushBattle(battle)
    return true
  end

  -- start a trainer double on demand, option or no option
  mod.exports.startTrainerDouble = function(oppClass, partyIndex)
    local Game = require("src.core.Game")
    local ow = Game.overworld
    if not (ow and ow.pushBattle) then return false, "no overworld" end
    local BattleState = require("src.battle.BattleState")
    local okN, battle = pcall(BattleState.newTrainer, Game, oppClass,
                              tonumber(partyIndex) or 1)
    if not (okN and battle) or battle.dead then
      return false, "battle refused"
    end
    decorateTrainer(Game, battle, true)
    if not battle.__double then return false, "decoration refused" end
    wireFinish(ow, battle)
    ow:pushBattle(battle)
    return true
  end

  -- two trainers versus your pair, staged by map scripts or mods
  mod.exports.startTrainerPair = function(oppA, idxA, oppB, idxB)
    local Game = require("src.core.Game")
    local ow = Game.overworld
    if not (ow and ow.pushBattle) then return false, "no overworld" end
    local BattleState = require("src.battle.BattleState")
    local okN, battle = pcall(BattleState.newTrainer, Game, oppA,
                              tonumber(idxA) or 1)
    if not (okN and battle) or battle.dead then
      return false, "battle refused"
    end
    decoratePair(Game, battle, oppB, idxB)
    if not battle.__double then return false, "decoration refused" end
    wireFinish(ow, battle)
    ow:pushBattle(battle)
    return true
  end

  mod.exports.isDoubleBattle = function(battle)
    return type(battle) == "table" and battle.__double == true
  end

  -- shadow the builtin start_battle only to stamp its battles as
  -- script-launched; the builtin does all the real work.  If another
  -- mod owns the override already, scripted exclusion quietly turns
  -- off rather than fighting over the verb.
  pcall(function()
    mod.content.commands:register("start_battle", {
      foreground = true,
      fn = function(ctx, kind, a, b)
        local OC = require("src.world.OverworldController")
        OC.__doubleBattlesPendingBox = OC.__doubleBattlesPendingBox or {}
        OC.__doubleBattlesPendingBox.scriptedUntil =
          love.timer.getTime() + 1
        local cmdModName = "src.script." .. "Commands"
        local okCommands, Commands = pcall(require, cmdModName)
        if okCommands and Commands and Commands.start_battle then
          return Commands.start_battle(ctx, kind, a, b)
        end
      end,
    })
  end)

  -- battle-starting mods whose script battles ARE organic encounters
  -- (wild_skies bumps, free_fly interceptions) call this first
  mod.exports.tagOrganic = function()
    local OC = require("src.world.OverworldController")
    OC.__doubleBattlesPendingBox = OC.__doubleBattlesPendingBox or {}
    OC.__doubleBattlesPendingBox.organicUntil = love.timer.getTime() + 1
    return true
  end

  mod.content.commands:register("double_battles:trainer_pair", {
    foreground = true,
    fn = function(ctx, oppA, idxA, oppB, idxB)
      mod.exports.startTrainerPair(oppA, idxA, oppB, idxB)
    end,
  })

  mod.content.commands:register("double_battles:trainer", {
    foreground = true,
    fn = function(ctx, oppClass, partyIndex)
      mod.exports.startTrainerDouble(oppClass, partyIndex)
    end,
  })

  mod.content.commands:register("double_battles:start", {
    foreground = true,
    fn = function(ctx, spA, lvA, spB, lvB)
      mod.exports.startWildDouble(spA, tonumber(lvA) or 5, spB,
                                  tonumber(lvB))
    end,
  })

  log.info("double_battles ready (wild doubles: %s, side: %s)",
               tostring(options:get("wild_doubles")),
               tostring(options:get("your_side")))

  local Doubles = {
    startWildDouble = mod.exports and mod.exports.startWildDouble or startWildDouble,
    startTrainerDouble = mod.exports and mod.exports.startTrainerDouble or startTrainerDouble,
    startTrainerPair = mod.exports and mod.exports.startTrainerPair or startTrainerPair,
    isDoubleBattle = mod.exports and mod.exports.isDoubleBattle or isDoubleBattle,
    decorate = decorate,
    decorateTrainer = decorateTrainer,
    decoratePair = decoratePair,
    exports = mod.exports
  }

  return Doubles
end
