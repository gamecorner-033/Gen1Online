-- Registry & Template for Custom Shop / Merchant NPCs
local ShopCategory = {
  registry = {}
}

function ShopCategory.register(shopNpcDef)
  table.insert(ShopCategory.registry, shopNpcDef)
end

return ShopCategory
