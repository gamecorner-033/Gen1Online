# Gen1Online Game Corner - Multiplayer MMO, GTS, Casino Lounge & Online Quests

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Mod Version: v0.3.5.0](https://img.shields.io/badge/version-0.3.5.0-green.svg)](manifest.json)

**Gen1Online Game Corner** brings the ultimate multiplayer Pokémon MMO experience together with cooperative quests, persistent progression, and high-stakes casino entertainment in *Pokémon Gen 1 Recomp*.

It combines seamless real-time overworld MMO co-op, custom character avatars, persistent leveling (Level 1–100), authentic Link Trading & PVP battles, cooperative quest storylines, and a 24/7 persistent **Global Trade Station (GTS)** with the expanded **Celadon Casino Lounge**, featuring **Blackjack**, **Crash Multiplier**, **Tube Flyer**, **Prize Case**, **Pawn Broker**, and **Live Multiplayer Online Texas Hold'em Poker**!

---

## 🌟 Key Features

### 📜 1. Server-Authoritative Cooperative Quests ("Magnemite Repair")
- **Debut Co-op Quest — "Magnemite Repair"**:
  - **Location**: Pallet Town (NPC **Fixer Felix**) & Kanto Power Plant.
  - **Cooperative Mechanics**: Two trainers must form a **Party** and split up to recover two specialized parts:
    - **Item A ("Magnetized Coil")**: Located on the upper floor of the Power Plant.
    - **Item B ("Conduit Lens")**: Located in the Power Plant basement.
  - **Server-Authoritative Mutual Exclusion Blocker**:
    - Picking up Item A permanently flags your character and blocks you from picking up Item B (*"You can't carry both – it's too heavy to repair alone!"*), requiring you to coordinate and split up with a partner.
  - **Cooperative Turn-In & Rewards**:
    - Return to Felix with your partner holding the other part to repair the Magnemite.
    - **Rewards**: **Level 30 Magneton** added to both players' parties/boxes + **1,000 MMO XP** to both trainers!
    - Server broadcasts a celebration message: *"The swarm has arrived! Magnemites fused into Magneton!"*
- **Two-Tier Scrollable Quest Log UI**:
  - Access via Start Menu → **`QUEST`**.
  - **Tier 1 (Quest List)**: Scrollable list of active, completed, and available quests with status tags (`[NEW]`, `[ACTV]`, `[DONE]`).
  - **Tier 2 (Quest Details)**: Clean 18-column card displaying dynamic objective checkboxes (`[X]` / `[ ]`), rewards, and full story lore on pressing **`SELECT`**.

---

### 👥 2. Cooperative Party System & Shared XP
- **Party System (Up to 4 Players)**: Create a party, invite nearby trainers, view live party member maps, coordinates, and levels.
- **100% Shared XP**: All MMO experience gained from wild battles, trainer victories, catches, and quests is shared in real-time across all party members.
- **Teammate Warp**: Warp directly to your party members across Kanto.

---

### 🃏 3. Live Multiplayer Online Texas Hold'em & Casino Lounge
- **Online Multiplayer Poker Tables**: Join 2-to-6 seat live tables with other connected trainers (`Rookie 10`, `Casino 50`, `High Roller 100`, `Champion 500`).
- **Real-Time Betting Engine**: Small & Big Blinds, multi-round betting (`Pre-Flop` $\rightarrow$ `Flop` $\rightarrow$ `Turn` $\rightarrow$ `River` $\rightarrow$ `Showdown`), 7-card best-hand evaluation, and tie-split pot calculation.
- **Solo Practice Mode**: Instant solo practice against the house dealer.
- **Celadon Casino Lounge (`BLACKJACK_LOUNGE`)**:
  - **Blackjack**: Full table with 3:2 natural payouts, double down, and split hands.
  - **Crash Multiplier**: Rocket multiplier machine with high-volatility cash-outs.
  - **Tube Flyer**: Flappy-style arcade machine earning coins per obstacle dodged.
  - **Prize Case**: 500-coin prize roulette with version-exclusive Pokémon, shiny upgrades, rare TMs, and Master Balls.
  - **Pawn Broker**: Shady Pokémon broker that appraises and holds up to 5 party Pokémon for instant coins.
  - **1,000,000 Coin Economy**: Unified Coin Case used seamlessly across all games and original slots.

---

### 🌐 4. Streamlined "Connect to Server" & Character Setup
- **Single-Click Start Menu**: Press **`START`** → Select **`CONNECT TO SERVER`**.
- **Automatic Device Save Detection**: Loads your recovery token, level, and XP progression automatically.
- **Authentic Vanilla Naming Screen**: Classic Game Boy letter-grid naming screen.
- **Character Avatar Customization**: 17 walkable character sprites (`RED`, `BLUE`, `LEAF / GIRL`, `PROF. OAK`, `COOLTRAINER M`, `COOLTRAINER F`, `TEAM ROCKET`, `LASS`, `YOUNGSTER`, `BLACKBELT`, `SUPER NERD`, `HIKER`, `BEAUTY`, `BUG CATCHER`, `SWIMMER`, `SAILOR`, `GENTLEMAN`).
- **Dedicated Dual-Save Architecture**: Online saves write strictly to `save_online.lua`, preserving offline `save.lua` data completely untouched.

---

### 📈 5. Player Leveling System (Level 1 to 100)
- **XP Progression Curve**: Dynamic leveling curve (`XP_REQ = math.floor(50 * ((lvl - 1) ^ 1.8))`).
- **Core XP Rewards**:
  - **Quests Completed**: `+1,000 XP`
  - **Catching Pokémon**: `+50 XP`
  - **Wild Battles**: `+15 XP`
  - **Trainer Battles**: `+40 XP`
  - **PVP Link Battles**: `+100 XP` (Win) / `+25 XP` (Participation)
  - **Breeding / Evolution**: `+50 XP`
- **Trainer Card**: Live server ranking (e.g. `#12/250`), PvP Win/Loss record, Badges, Pokédex count, and Blackout tally.

---

### 🏪 6. 24/7 Global Trade Station (GTS) & PVP Battles
- **Alphabetical Wanted Pokémon Selector**: Choose up to 3 wanted species (`A-C`, `D-F`, `G-I`, `J-L`, `M-O`, `P-R`, `S-U`, `V-Z`).
- **Persistent Cloud Database**: Listings stay safe on the server even when players log off.
- **Offline Claim Boxes**: Traded Pokémon are delivered safely for your next login.
- **Facing PVP Link Battles & Link Trading**: Walk up to any trainer in the overworld, face them, and press **`A`** to challenge or trade.

---

## 🛠️ Installation & Setup

1. Place the `gen1online-gamecorner` and `gen1quests` mod folders into your `mods/` directory:
   ```
   pokemon-gen1-recomp/mods/gen1online-gamecorner/
   pokemon-gen1-recomp/mods/gen1quests/
   ```
2. Start the server (or connect to an existing host):
   ```bash
   python gts_server.py
   ```
3. In *Pokémon Gen 1 Recomp*, press **`START`** → Select **`CONNECT TO SERVER`**.
4. Speak to **Fixer Felix** in Pallet Town to begin your first cooperative quest!

---

## 👨‍💻 Credits & Acknowledgements

- **Creator & Lead Designer**: **Gamecorner33**
- **Original Blackjack Mod Creator**: **martin2844** ([martin2844/gen1recomp-blackjack-corner](https://github.com/martin2844/gen1recomp-blackjack-corner))
- **Double Battles Framework**: **Shane Hudson** ([shanehudson-gen1recomp-mods/double_battles](https://github.com/shanehudson-gen1recomp-mods/monorepo))
- **Co-Developer**: **Google DeepMind / Antigravity AI Assistant**
- **MMO Engine Inspiration**: **alamops** ([alamops/RBYMMOMod](https://github.com/alamops/RBYMMOMod))
- **Platform**: **bryanthaboi** and the **Gen 1 Recomp Team** ([bryanthaboi/gen1recomp](https://github.com/bryanthaboi/gen1recomp))
