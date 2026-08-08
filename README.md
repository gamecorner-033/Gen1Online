# Gen1Online - Multiplayer MMO, Global Trade Station (GTS) & Co-Op Mod

**Gen1Online** brings seamless real-time overworld MMO co-op, custom character avatar selection, persistent player leveling (Level 1–100), authentic vanilla Link Trading with link cable cutscenes & trade evolutions, facing PVP Link Battles, in-game chat, and a 24/7 persistent **Global Trade Station (GTS)** to *Pokémon Gen 1 Recomp*.

---

## 🌟 Key Features

### 🌐 1. Streamlined "Connect to Server" & Character Setup
- **Single-Click Start Menu**: Press **`START`** → Select **`CONNECT TO SERVER`**.
- **Automatic Device Save Detection**: If an online character is already associated with this save/device, it automatically validates your recovery token, loads your level & XP progression, and logs you in instantly.
- **Authentic Vanilla Naming Screen**: New players are greeted with the classic Game Boy letter-grid naming screen to enter their own custom trainer name.
- **Server Name Collision Protection**: Real-time server query (`/player/check_name`) prevents duplicate names across players.
- **Character Avatar Customization**: Choose from 17 walkable character sprites (`RED`, `BLUE`, `LEAF / GIRL`, `PROF. OAK`, `COOLTRAINER M`, `COOLTRAINER F`, `TEAM ROCKET`, `LASS`, `YOUNGSTER`, `BLACKBELT`, `SUPER NERD`, `HIKER`, `BEAUTY`, `BUG CATCHER`, `SWIMMER`, `SAILOR`, `GENTLEMAN`).
- **Secure Recovery Token**: Each account receives a unique recovery password/token stored safely in your save file.

---

### 📈 2. Player Leveling System (Level 1 to 100)
- **XP Progression Curve**: Dynamic leveling curve that starts fast and scales up gradually (`XP_REQ = math.floor(50 * ((lvl - 1) ^ 1.8))`).
- **Core XP Rewards**:
  - **Catching Pokémon**: `+50 XP`
  - **Wild Pokémon Battles**: `+15 XP`
  - **NPC Trainer Battles**: `+40 XP`
  - **PVP Link Battles**: `+100 XP` (Victory) / `+25 XP` (Participation)
  - **Breeding Pokémon**: `+60 XP` (Prepared for breeding mechanics)
- **Real-Time Level-Up Fanfares**: Celebratory textboxes and sound effects upon leveling up.
- **Overworld Level Badges**: Head tags above players display their active level (e.g. `RED (Lv24)`).

---

### 💻 3. Pokémon Center PC "MMO Terminal"
Every PC in the game (Pokémon Centers, Player's Bedroom, Celadon Mansion) is equipped with the **`ONLINE MMO TERMINAL`**:
- **My MMO Profile & XP**: Displays your Level (1–100), Level Progress Bar (`[========--] 340/500 XP`), Badges, Pokédex count, PVP Record, Avatar Sprite, and Recovery Token.
- **Server Leaderboards**: Live top 25 rankings sorted by Level, PVP Wins, and total XP.
- **Global MMO Chat**: Send broadcasts and browse the 50 most recent chat messages.
- **Global Trade Station (GTS)**: Direct access to GTS browsing, deposits, and claim boxes.

---

### 🏪 4. 24/7 Global Trade Station (GTS)
- **Interactive Wanted Pokémon Selector**: When depositing a Pokémon, choose up to 3 wanted species from an organized alphabetical picker (`A-C`, `D-F`, `G-I`, `J-L`, `M-O`, `P-R`, `S-U`, `V-Z`).
- **Persistent Cloud Database**: Pokémon remain stored safely on the server even when all players exit their games.
- **3-Deposit Limit**: Up to 3 active deposits per Trainer ID.
- **Offline Claim Boxes**: Traded Pokémon are delivered to your **Claim Box** waiting for your next login.
- **Recent History Log**: Displays the 50 most recent server transactions.

---

### ⚔️ 5. Authentic Vanilla Link Trading & PVP Battles
- **Facing Interaction**: Walk up to any trainer on the overworld, face them, and press **`A`** to open the interaction menu.
- **Vanilla Link Trading**: Interactive 2-column party selection (`YOURS` vs `THEIRS`), authentic **Link Cable machine animation cutscenes** (`TradeAnim`), sound effects, and automatic trade evolutions (Haunter, Machoke, Graveler, Kadabra).
- **PVP Link Battles**: Synchronized lockstep Link Battles with auto-healing and shared RNG seeds.

---

### 🛡️ 6. Server Host Backup & Anti-Cheat CLI
- **Host-Only Backup File (`players_backup.json`)**: Server automatically persists all registered accounts, levels, XP, and stats to a dedicated backup file on the host machine.
- **Anti-Cheat Audit Engine**: Validates XP gains against mathematical level boundaries and flags tampering or impossible stat jumps.
- **Host Admin CLI Tool (`gts_admin.py`)**:
  ```bash
  python gts_admin.py list                     # List all registered players, levels, XP, ban status
  python gts_admin.py audit                    # Run anti-cheat verification on all accounts
  python gts_admin.py view <trainerId>         # View full details for a player
  python gts_admin.py ban <trainerId> [reason] # Ban a player from connecting
  python gts_admin.py unban <trainerId>        # Unban a player
  python gts_admin.py remove <trainerId>       # Delete a player from the server and backup
  ```

---

## 🛠️ Installation & Setup

1. Place the `Gen1Online-main` mod folder into your `mods/` directory:
   ```
   pokemon-gen1-recomp/mods/Gen1Online-main/
   ```
2. Start the server (or connect to an existing host):
   ```bash
   python gts_server.py
   ```
3. In *Pokémon Gen 1 Recomp*, press **`START`** → Select **`CONNECT TO SERVER`**.

---

## 👨‍💻 Credits & Acknowledgements

- **Created by**: **Gamecorner33** (with AI Assistant **Antigravity**).
- **Special Thanks & Credit**: **alamops** ([alamops/RBYMMOMod](https://github.com/alamops/RBYMMOMod)) — for creating the fantastic **RBY MMO** mod, which served as an invaluable reference and inspiration for character avatar selection, chat presentation, and multiplayer concepts in Gen 1 Recomp.
