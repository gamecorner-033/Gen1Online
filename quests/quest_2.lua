-- Quest #2: Bye Bye Butterfree (Solo Story Quest)
return {
  id = 2,
  title = "BYE BYE BUTTERFREE",
  shortLabel = "2. BUTTERFREE",
  type = "solo",
  location = "VIRIDIAN FOREST",
  lore = "Bug Catcher BugHead in Viridian Forest needs help raising his Caterpie into a Butterfree!\fTake his Caterpie, raise it until it evolves into a Butterfree, then return it so it can fly free!",
  objectives = {
    { id = "caterpie_received", label = "TAKE CATERPIE" },
    { id = "raise_butterfree", label = "RAISE BUTTERFREE" },
    { id = "turn_in", label = "RETURN TO BUGHEAD" }
  },
  reward = "MAX STAT CATERPIE (BUGSY) + 1,000 XP"
}
