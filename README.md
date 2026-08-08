# Gen1Online Game Corner - Multiplayer MMO, GTS, Casino Lounge & Online Texas Hold'em

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Mod Version: v0.3.3](https://img.shields.io/badge/version-0.3.3-green.svg)](manifest.json)

**Gen1Online Game Corner** brings the best of multiplayer Pokémon and high-stakes casino entertainment together in *Pokémon Gen 1 Recomp*.

It combines seamless real-time overworld MMO co-op, custom character avatars, persistent leveling (Level 1–100), authentic Link Trading & PVP battles, and a 24/7 persistent **Global Trade Station (GTS)** with the expanded **Celadon Casino Lounge**, featuring **Blackjack**, **Crash Multiplier**, **Tube Flyer**, **Prize Case**, **Pawn Broker**, and **Live Multiplayer Online Texas Hold'em Poker**!

---

## 🌟 Key Features

### 🃏 1. Live Multiplayer Online Texas Hold'em & Casino Lounge
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

### 🌐 2. Streamlined "Connect to Server" & Character Setup
- **Single-Click Start Menu**: Press **`START`** → Select **`CONNECT TO SERVER`**.
- **Automatic Device Save Detection**: Loads your recovery token, level, and XP progression automatically.
- **Authentic Vanilla Naming Screen**: Classic Game Boy letter-grid naming screen.
- **Character Avatar Customization**: 17 walkable character sprites (`RED`, `BLUE`, `LEAF / GIRL`, `PROF. OAK`, `COOLTRAINER M`, `COOLTRAINER F`, `TEAM ROCKET`, `LASS`, `YOUNGSTER`, `BLACKBELT`, `SUPER NERD`, `HIKER`, `BEAUTY`, `BUG CATCHER`, `SWIMMER`, `SAILOR`, `GENTLEMAN`).
- **Secure Recovery Token**: 8-character token stored safely to restore your profile on any device.

---

### 📈 3. Player Leveling System (Level 1 to 100)
- **XP Progression Curve**: Dynamic leveling curve (`XP_REQ = math.floor(50 * ((lvl - 1) ^ 1.8))`).
- **Core XP Rewards**:
  - **Catching Pokémon**: `+50 XP`
  - **Wild Battles**: `+15 XP`
  - **Trainer Battles**: `+40 XP`
  - **PVP Link Battles**: `+100 XP` (Win) / `+25 XP` (Participation)
  - **Breeding / Evolution**: `+50 XP`
- **Trainer Card**: Live server ranking (e.g. `#12/250`), PvP Win/Loss record, Badges, Pokédex count, and Blackout tally.

---

### 🏪 4. 24/7 Global Trade Station (GTS) & PVP Battles
- **Alphabetical Wanted Pokémon Selector**: Choose up to 3 wanted species (`A-C`, `D-F`, `G-I`, `J-L`, `M-O`, `P-R`, `S-U`, `V-Z`).
- **Persistent Cloud Database**: Listings stay safe on the server even when players log off.
- **Offline Claim Boxes**: Traded Pokémon are delivered safely for your next login.
- **Facing PVP Link Battles & Link Trading**: Walk up to any trainer in the overworld, face them, and press **`A`** to challenge or trade.

---

## 🛠️ Installation & Setup

1. Place the `gen1online-gamecorner` mod folder into your `mods/` directory:
   ```
   pokemon-gen1-recomp/mods/gen1online-gamecorner/
   ```
2. Start the server (or connect to an existing host):
   ```bash
   python gts_server.py
   ```
3. In *Pokémon Gen 1 Recomp*, press **`START`** → Select **`CONNECT TO SERVER`**.
4. Teleport directly to **`GAME CORNER`** or **`BLACKJACK LOUNGE`** using the **Debug Menu**!

---

## 👨‍💻 Credits & Acknowledgements

A huge thank you to all the talented creators and contributors who made this mod possible:

### 🎰 Blackjack Corner & Casino Games
- **Creator**: **martin2844** ([martin2844/gen1recomp-blackjack-corner](https://github.com/martin2844/gen1recomp-blackjack-corner))
  - Designed and created the original **Blackjack Corner** mod.
  - Authored the Celadon Casino Lounge map (`BLACKJACK_LOUNGE`), custom pixel-art table sprites, Blackjack rules engine, original Texas Hold'em rules & view, Crash machine, Tube Flyer, Prize Case, Pawn Broker, and 1,000,000-coin economy.

### 🌐 Gen1Online MMO & Multiplayer Infrastructure
- **Creator & Lead Designer**: **Gamecorner33**
  - Architected the Gen1Online concept, overworld player synchronization, 24/7 GTS system, and MMO design.
- **Co-Developer**: **Google DeepMind / Antigravity AI Assistant**
  - Developed the asynchronous 60FPS non-blocking network thread, lockstep PVP Link Battles, MMO leveling curve & Trainer Card, account recovery tokens, anti-cheat audit suite, and the real-time **Online Multiplayer Texas Hold'em Engine**.

### 💡 Inspiration & Platform Credits
- **alamops** ([alamops/RBYMMOMod](https://github.com/alamops/RBYMMOMod)) — For creating the wonderful **RBY MMO** mod, which served as an invaluable reference and inspiration for avatar selection, chat relays, and multiplayer mechanics in Gen 1.
- **bryanthaboi** and the **Gen 1 Recomp Team** ([bryanthaboi/gen1recomp](https://github.com/bryanthaboi/gen1recomp)) — For the foundational decompilation and recompilation platform that makes all of this modding possible.
