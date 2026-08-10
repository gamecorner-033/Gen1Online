-- Registry & Template for Custom Trainer Battle NPCs
local BattleCategory = {
  registry = {}
}

function BattleCategory.register(battleNpcDef)
  table.insert(BattleCategory.registry, battleNpcDef)
end

return BattleCategory
