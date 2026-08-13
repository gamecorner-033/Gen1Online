# Changelog

## [0.3.5.56] - 2026-08-13

### Changed

- **Cloudflare Tunnel URL Update**: Updated official Cloudflare tunnel endpoint to
  `katrina-quick-bugs-predicted.trycloudflare.com`.

## [0.3.5.5] - 2026-08-13

### Fixed

- **Online Save Connection & Options Menu Routing**: Guaranteed reliable online connection
  feedback and instant routing to `ONLINE OPTIONS` whenever loading an online save file.
- **Cross-Build Patch Version Compatibility**: Implemented patch-level version compatibility
  checking (`is_version_compatible`), allowing clients and servers across the `0.3.5.x` series
  to connect seamlessly without version mismatch popups.
- **LÖVE Filesystem Relaunch Guard**: Protected `conf.lua` filesystem symlink initialization
  and wrapped process pipe closures (`io.popen`) to eliminate in-process relaunch crashes.

## [0.3.5.3] - 2026-08-12

### Fixed

- **Oak Speech Intro Freeze Fix**: Fixed a freeze occurring after Professor Oak's
  speech (*"I'll be seeing you later!"*) during the New Game overworld transition.
  Removed an invasive hook on `Events.set` that interfered with `World:loadPlayerData`
  initial flag seeding.
- **Cross-Platform Android & Mobile Transport**: Resolved network connection errors
  on Android devices by standardizing HTTP tunnel routing over native LuaSocket,
  avoiding `127.0.0.1` loopback redirects and `curl.exe` dependencies on mobile.

## [0.3.5.2] - 2026-08-12

### Changed

- **Exclusive Gold (Gen 2) Connection Rule**: Strictly enforced that Pokémon Gold
  (Gen 2) is the required game version for connecting to the server. Non-Gold game
  boots will prompt the player to launch Pokémon Gold to play online.
- **Improved Network Diagnostics & Fallback**: Enhanced HTTP fallback to system `curl.exe`
  when LuaSec fails or SSL certs are untrusted, ensuring exact server error messages
  are reported instead of generic network timeouts.

## [0.3.5.1] - 2026-08-12

### Fixed

- **Map Scene & Story Cutscene Persistence**: Fixed an issue in Gen 2 where
  re-entering maps would re-play initial scenes (such as Elm's Lab starter
  dialogue) or block routes (such as the Route 29 NPC woman stopping the player).
- **Bi-directional `mapScenes` & `scriptMem` Sync**: Full map scene ID tables
  and script memory are now preserved and synced between the game engine, save files,
  and server host backups.
- **Human-Readable Flag Crosswalks**: Integrated complete constant mappings for
  all Gen 1 & Gen 2 event flags (`EVENT_GOT_A_POKEMON_FROM_ELM`, `EVENT_GOT_STARTER`, etc.)
  with real-time hooks on `Events.set` and `World.setMapScene`.
- **Server-Side Player Backup Cards**: Server host machine automatically outputs
  individual `Players Backup/Player_<ID>_<Name>.json` files logging account details,
  recovery tokens, completed event flags, map scene states, badges, party, and stats.

## [0.3.5.0] - 2026-08-11

### Added

- **Gen 2 (Gold) Support.** The mod now declares `"api": 2` and
  `"games": ["gen1", "gen2"]`, enabling it to load on Gold boots via the
  Gen 2 compatibility adapter.
- Generation detection helper (`currentGeneration` / `isGen2`) for
  future generation-conditional logic.

### Changed

- Online save files on Gold now use a `_gold` suffix
  (`save_online_gold.lua`) to keep progress separate from Gen 1 saves.
- `Game.logicSpeed` override is now guarded with a nil check for Gen 2
  facade safety — the patch only installs when the method exists.

## [0.2.0] - 2026-08-07

### Added

- A 1,000,000-coin Coin Case limit across the mod's purchases, wagers, payouts,
  prize refunds, and pawn transactions.
- Compatibility for the original slot machines, including high-balance-safe
  payouts and a compact four-character credit counter up to `1.0M`.
- House-banked Texas Hold'em with real best-five-of-seven hand evaluation.
- Progressive Play wagering across all three streets: check or bet 3x/4x
  before the flop, continue with 2x after the flop, then check or bet 1x at
  the river.
- One clear starting bet, standard best-hand comparison against the house,
  and 1:1 payouts across all committed wagers.
- A dedicated blue-felt Hold'em screen with hole cards, five community cards,
  staged controls, showdown hands, and net results.
- A second dealer and interactive poker table in the casino lounge.
- A shady Pokemon pawn broker at the original Game Corner counter.
- Stat-, level-, and rarity-based appraisals paid in Game Corner coins, with
  exact Pokemon restoration for a 30% redemption premium.
- Five persistent pawn slots with an explicit first-pawned-first-sold warning
  when adding a sixth Pokemon.
- Safe party/PC redemption and protections for the final party member, full
  Coin Cases, and full Pokemon storage.
- Three generated center-lounge arcade cabinets with separate Crash, Tube
  Flyer, and Prize Case screens.
- A wager-and-cash-out Crash game with a hidden house-edged crash point,
  continuously rising multiplier, four wager sizes, and persistent records.
- A 10-coin flying game with deterministic tube physics, immediate one-coin
  payouts per passed tube, best scores, and safe Coin Case limits.
- A 500-coin case-opening reel with rarity colors, a premium Pokemon roster,
  rare items and TMs, and a roughly 0.1% Master Ball chance.
- Transactional case rewards that use party/PC delivery and refund the full
  opening price if the selected reward cannot be stored.

### Improved

- Replaced low-tier Prize Case Pokemon with starters, fossils, Dragonite,
  Mew, and a special Pikachu that arrives knowing Surf.
- Styled the Master Ball reel card as a gold-and-black jackpot and slowed the
  case reel and Crash multiplier growth for clearer decision timing.
- Refactored the runtime into per-game `games/` modules and supporting
  `other/` services, reducing `main.lua` to composition and registration.
- Rebuilt all three arcade screens around bright, machine-specific Game Boy
  palettes so the engine's black tile font remains legible in every state.
- Crash now presents all four wagers at once with a clear selection, a visual
  launch preview, and a light graph surface.
- Tube Flyer gained readable top-HUD scoring, capped pipe openings, a clearer
  bird silhouette, and a compact result ribbon that preserves the playfield.
- Prize Case gained icon-led reel cards, shorter readable reel labels, stronger
  winner markers, and compact opening/result panels without a dark backdrop.
- Expanded the lounge from 14x10 to 20x12 walk cells for two distinct games,
  more breathing room, and a central circulation aisle.
- Reduced both overworld tables from five to four tiles wide and gave each
  game its own locally generated table art.
- Added concise in-world guidance for progressive Hold'em decisions and
  standard best-hand payouts.
- Verify each wager independently, so a player with exactly one starting bet
  can check every street and still reach showdown.
- Early bets now reveal only the next street instead of skipping directly to
  showdown, and unaffordable bets never block the free Check action.
- Removed the Ultimate Hold'em Ante, Blind, bonus-paytable, and dealer-
  qualification rules that conflicted with the multi-street game.

### Fixed

- Original slot payouts now cross the old 9,999-coin boundary instead of
  silently losing the next payout coin.
- Hidden Game Corner coin pickups preserve five- and six-digit balances
  instead of clamping them back to 9,999.
- Prize Case reel positioning and winner highlighting now share the same
  configured winning-card index.

## [0.1.0] - 2026-08-06

### Added

- Playable blackjack using the existing Game Corner coin balance.
- Pixel-drawn cards, chips, casino table, action states, and round feedback.
- Expanded Red- and Blue-aware Pokemon prize catalogues.
- Persistent shiny upgrades with locally derived gold battle art.
- Rare item prizes and a one-time 9,999-coin Master Ball redemption.
- Larger 50, 250, 500, 1,000, and capacity-aware MAX coin purchases.
- Red-, Blue-, and Yellow-aware prize catalogues with starters, fossils, and
  opposite-version species.
- Safe party/PC delivery and failure handling that never charges for a prize
  the player cannot receive.

### Improved

- Removed level suffixes from Pokemon prize rows so long names no longer
  collide with their prices.
- Failed prize purchases now return to the catalogue instead of closing it.
- Replaced the borrowed octagonal dining table with a wide, green semicircular
  blackjack table, centered dealer, betting marks, chips, deck, and a fully
  interactive front edge.
- Moved the table into a dedicated Blackjack Lounge with its own double-door,
  spectators, open circulation space, and reciprocal Game Corner warps.
- Expanded the coin clerk with 50, 250, 500, 1,000, and capacity-aware MAX
  purchases at the original exchange rate.
- Card pips, court cards, silhouettes, and color rendering were rebuilt for the
  real 160x144 game pipeline.
