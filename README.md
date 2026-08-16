# Gen1Online Game Corner - Multiplayer MMO, GTS, Casino Lounge & Online Quests

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Mod Version: v0.3.4.3](https://img.shields.io/badge/version-0.3.4.3-green.svg)](manifest.json)

**Gen1Online Game Corner** brings the ultimate multiplayer Pokémon MMO experience together with cooperative quests, persistent progression, and high-stakes casino entertainment in *Pokémon Gen 1 Recomp*.

It combines seamless real-time overworld MMO co-op, custom character avatars, persistent leveling (Level 1–100), authentic Link Trading & PVP battles, cooperative quest storylines, and a 24/7 persistent **Global Trade Station (GTS)** with the expanded **Celadon Casino Lounge**, featuring **Blackjack**, **Crash Multiplier**, **Tube Flyer**, **Prize Case**, **Pawn Broker**, and **Live Multiplayer Online Texas Hold'em Poker**!

---

## 🌟 Key Features

### 📜 1. Online Quests (Gen 2 port — in progress)
- The original Gen 1 quest content (**"Magnemite Repair"** co-op quest, **"Bye Bye Butterfree"** solo quest, and their in-world NPCs/items) was **removed during the Gen 2 migration**.
- The mod now ships a **registry skeleton** (`quests/init.lua` and `npcs/init.lua`) with a clean registration API designed for Gen 2, ready to be filled back in with quest definitions and NPCs.
- The server-side quest engine (`QUEST_DEFINITIONS` / `QuestManager` in `gts_server.py`, plus the `quest_get` / `quest_accept` / `quest_pickup` / `quest_turn_in` endpoints) is untouched and ready to serve the re-added content.
- **Quest Log UI**: not yet reimplemented for Gen 2.

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
2. **Server files are NOT part of the mod zip.** They live in a separate `server/gen1online/` folder
   (outside the mod directory) so they are never distributed to players. The mod zip contains only the
   client code — it carries **no** player database, tokens, or server secrets.
3. **Configure the admin key** (required before first start):
   ```bash
   cd server/gen1online
   python -c "import secrets; print(secrets.token_hex(16))"   # pick a long random key
   ```
   Save it in `server_secrets.json` next to `gts_server.py`:
   ```json
   { "adminKey": "PASTE_YOUR_RANDOM_KEY_HERE" }
   ```
4. Start the server (binds to `127.0.0.1` by default — it is never exposed directly):
   ```bash
   python gts_server.py
   ```
5. (Recommended for playing with friends) Expose it through a Cloudflare tunnel so your public IP stays hidden:
   ```bash
   cloudflared tunnel --url http://127.0.0.1:7779
   ```
   Give your friends the `https://<random>.trycloudflare.com/` URL.
6. In *Pokémon Gen 1 Recomp*, press **`START`** → Select **`CONNECT TO SERVER`**.
7. Walk up to any online trainer, face them, and press **`A`** to challenge them to PVP or trade.

---

## 🔒 Server Security (Read This!)

- **The server binds to `127.0.0.1` only.** Never change this to `0.0.0.0` unless you fully
  understand the risk — an open port lets anyone on the internet reach your server and your PC.
- **Use `cloudflared` (or similar) as the only way in.** The tunnel forwards the public URL to
  localhost, so your home IP address is never revealed to players.
- **The admin key is your master password.** `admin_action` requests (ban / unban / remove / audit)
  are rejected with `403 FORBIDDEN` without it. Admin commands are run from the host machine:
  ```bash
  python gts_admin.py list
  python gts_admin.py ban 123456 "cheating"
  python gts_admin.py audit
  ```
  `gts_admin.py` reads the key from `server_secrets.json` automatically.
- **Recovery tokens are secret.** Every account has a token that can restore the save. A leaked token
  lets someone take over that account, so never share your token and never upload
  `server_secrets.json`, `gts_database.json`, `players_backup.json`, or `private_ip_ledger.json`.
- **Tokens are now 128-bit** for new accounts; legacy 8-character tokens remain valid.
- The IP audit ledger (`private_ip_ledger.json`) is stored only on the host for ban enforcement — it is
  never exposed through the API.

---

## 👨‍💻 Credits & Acknowledgements

- **Creator & Lead Designer**: **Gamecorner33**
- **Original Blackjack Mod Creator**: **martin2844** ([martin2844/gen1recomp-blackjack-corner](https://github.com/martin2844/gen1recomp-blackjack-corner))
- **Co-Developer**: **Google DeepMind / Antigravity AI Assistant**
- **MMO Engine Inspiration**: **alamops** ([alamops/RBYMMOMod](https://github.com/alamops/RBYMMOMod))
- **Platform**: **bryanthaboi** and the **Gen 1 Recomp Team** ([bryanthaboi/gen1recomp](https://github.com/bryanthaboi/gen1recomp))
