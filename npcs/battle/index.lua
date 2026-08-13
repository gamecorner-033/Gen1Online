-- Registry for Custom Trainer Battle NPCs
return function(loadModFile, mod)
  local BattleCategory = {
    route1 = loadModFile(mod, "npcs/battle/route1_trainer.lua"),
    route2 = loadModFile(mod, "npcs/battle/route2_brothers.lua")
  }

  return BattleCategory
end
