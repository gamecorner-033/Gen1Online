-- Comprehensive In-Game Profanity & Slur Filter for Gen1Online
-- Protects Player Names, Trainer Titles, Pokémon Nicknames, GTS Trades, and MMO Chat

local Profanity = {}

local BAD_WORDS = {
  "fuck", "fucker", "fucking", "fucked", "fuckhead", "motherfucker", "fuk", "fck", "fak", "fuc",
  "shit", "shitting", "bullshit", "shithead", "shitty", "shyt", "shtt",
  "bitch", "bitches", "bitching", "bitchass", "btch", "b1tch",
  "asshole", "assholes", "dumbass", "jackass", "fatass", "badass", "ashole",
  "cunt", "cunts",
  "dick", "dicks", "dickhead", "cock", "cocks", "cocksucker",
  "pussy", "pussies", "pusy",
  "bastard", "bastards",
  "slut", "sluts", "slutty",
  "whore", "whores", "whor",
  "nigger", "nigga", "niggaz", "niggers", "niggas", "n1gga", "n1gger",
  "faggot", "fag", "faggots", "fags", "fgt",
  "retard", "retarded", "tard",
  "chink", "kike", "spic", "gook", "wetback", "tranny",
  "pedophile", "pedo", "rapist", "rape",
  "penis", "vagina", "dildo", "blowjob", "handjob", "cum", "cumshot",
  "porn", "porno", "hentai", "nude", "nudes", "boobs", "tits", "titties",
  "twat", "wanker", "prick"
}

local EXACT_BAD_WORDS = {
  ass = true, asses = true, damn = true, dammit = true,
  hell = true, sex = true, tit = true, kys = true
}

local LEET_MAP = {
  ["@"] = "a", ["4"] = "a",
  ["8"] = "b",
  ["("] = "c", ["<"] = "c", ["["] = "c",
  ["3"] = "e",
  ["6"] = "g", ["9"] = "g",
  ["#"] = "h",
  ["1"] = "i", ["!"] = "i", ["|"] = "i",
  ["0"] = "o",
  ["5"] = "s", ["$"] = "s", ["z"] = "s",
  ["7"] = "t", ["+"] = "t",
  ["v"] = "u"
}

local function normalize(text)
  if not text or text == "" then return "" end
  local lower = string.lower(text)
  local t = {}
  for i = 1, #lower do
    local ch = lower:sub(i, i)
    t[#t + 1] = LEET_MAP[ch] or ch
  end
  local norm = table.concat(t)
  -- Collapse consecutive duplicate characters (e.g. fuuuuck -> fuck)
  norm = norm:gsub("(.)%1%1+", "%1")
  return norm
end

local function cleanAlpha(text)
  local norm = normalize(text)
  return norm:gsub("[^%a%d]", "")
end

function Profanity.contains(text)
  if not text or text == "" then return false end
  local norm = normalize(text)
  local alpha = cleanAlpha(text)

  -- 1. Check alpha-only stripped text against bad words
  for _, w in ipairs(BAD_WORDS) do
    if alpha:find(w, 1, true) then
      return true
    end
  end

  -- 2. Check tokenized words
  for token in norm:gmatch("%w+") do
    if EXACT_BAD_WORDS[token] then
      return true
    end
    for _, w in ipairs(BAD_WORDS) do
      if token == w then
        return true
      end
    end
  end

  return false
end

function Profanity.censor(text)
  if not text or text == "" then return "" end
  if not Profanity.contains(text) then return text end

  -- Censor word by word
  local words = {}
  for segment in text:gmatch("%S+") do
    if Profanity.contains(segment) then
      words[#words + 1] = string.rep("*", #segment)
    else
      words[#words + 1] = segment
    end
  end

  local res = table.concat(words, " ")
  if Profanity.contains(text) and res == text then
    return string.rep("*", math.max(3, math.min(8, #text)))
  end
  return res
end

return Profanity
