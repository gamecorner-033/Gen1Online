local UI = {}

UI.colors = {
  ink = { 0.08, 0.10, 0.10 }, outline = { 0.18, 0.22, 0.18 },
  cream = { 0.96, 0.92, 0.70 }, paper = { 0.98, 0.95, 0.79 },
  muted = { 0.70, 0.73, 0.58 }, green = { 0.25, 0.67, 0.31 },
  greenLight = { 0.72, 0.85, 0.57 }, red = { 0.74, 0.20, 0.22 },
  redLight = { 0.92, 0.61, 0.52 }, gold = { 0.95, 0.67, 0.17 },
  goldLight = { 0.97, 0.84, 0.48 }, blue = { 0.26, 0.57, 0.72 },
  blueLight = { 0.69, 0.84, 0.84 }, purple = { 0.55, 0.34, 0.65 },
}

function UI.color(value, alpha)
  love.graphics.setColor(value[1], value[2], value[3], alpha or 1)
end

function UI.rect(mode, x, y, width, height)
  love.graphics.rectangle(mode, math.floor(x), math.floor(y), width, height)
end

function UI.centered(Font, value, y)
  Font.draw(value, math.floor((160 - Font.width(value)) / 2), y)
end

function UI.panel(x, y, width, height, fill, border)
  UI.color(border or UI.colors.outline)
  UI.rect("fill", x, y, width, height)
  UI.color(fill)
  UI.rect("fill", x + 2, y + 2, width - 4, height - 4)
end

function UI.compactCoins(value)
  value = math.max(0, math.floor(tonumber(value) or 0))
  if value >= 1000000 then return "C 1M" end
  if value >= 10000 then return "C " .. math.floor(value / 1000) .. "K" end
  return "C " .. value
end

function UI.frame(title, Font, coinCount, theme)
  local C = UI.colors
  UI.color(theme.base); UI.rect("fill", 0, 0, 160, 144)
  UI.color(C.outline); UI.rect("fill", 3, 3, 154, 138)
  UI.color(theme.base); UI.rect("fill", 6, 6, 148, 132)
  UI.color(theme.header); UI.rect("fill", 7, 7, 146, 18)
  UI.color(C.cream); UI.rect("fill", 7, 23, 146, 2)
  UI.color(C.ink); Font.draw(title, 10, 11)
  local label = UI.compactCoins(coinCount)
  Font.draw(label, 150 - Font.width(label), 11)
end

function UI.button(Font, label, y, enabled, theme)
  local C = UI.colors
  UI.color(C.outline); UI.rect("fill", 29, y + 2, 102, 20)
  UI.color(enabled and theme.action or C.muted); UI.rect("fill", 29, y, 102, 19)
  UI.color(C.paper); UI.rect("line", 32, y + 3, 96, 13)
  UI.color(C.ink); UI.centered(Font, label, y + 6)
end

return UI
