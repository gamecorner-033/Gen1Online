-- Quest #1: Magnemite Repair (Cooperative Party Quest)
return {
  id = 1,
  title = "MAGNEMITE REPAIR",
  shortLabel = "1. MAGNEMITE",
  type = "coop",
  location = "PALLET TOWN & POWER PLANT",
  lore = "The Power Plant is in disarray! Fixer Felix in Pallet Town needs two trainers to recover a Magnetized Coil and a Conduit Lens.\fSearch the upper floor and basement of the Power Plant with a partner!",
  objectives = {
    { id = "part_a", label = "COIL (UPPER FLOOR)", item = "MAGNET_COIL" },
    { id = "part_b", label = "LENS (BASEMENT)", item = "CONDUIT_LENS" },
    { id = "turn_in", label = "RETURN W/ PARTNER" }
  },
  reward = "MAGNETON LV30 + 1,000 XP"
}
