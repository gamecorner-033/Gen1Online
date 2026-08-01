# Gen1Online - Multiplayer Co-Op & Global Trade Station (GTS) Mod

**Gen1Online** brings seamless real-time overworld co-op multiplayer, 3D Voxel support, facing PVP Link Battles, vanilla Link Trading, and a 24/7 persistent **Global Trade Station (GTS)** to *Pokémon Gen 1 Recomp*.

---

## 🌟 Key Features

### 🌐 1. Real-Time Overworld Co-Op
- **Visible Roaming Trainers**: See connected players roaming Kanto in real time (`SPRITE_RED`) with 20 Hz position sync.
- **Trailing Follower Pokémon**: Trailing follower Pokémon sprites render behind each trainer on the overworld map.
- **Smooth Animation & Collision**: Linear movement interpolation, walking leg animations, and solid physical collision (`passable = false`).
- **3D Voxel & 2D Perspective**: Fully compatible with 3D Voxel camera perspectives while preserving authentic Gen 1 GBC color palettes.

---

### 🏪 2. 24/7 Global Trade Station (GTS)
- **Persistent Cloud Database**: Upload Pokémon to the GTS server where they remain stored safely on disk even when all players exit their games.
- **3-Deposit Limit**: Up to 3 active deposits per Trainer ID (`save.player.id`).
- **Up to 3 Wanted Species**: Specify up to 3 wanted species you are willing to accept in exchange for your deposit (e.g. Offering *Charmander LV10*, Wanting *Pikachu*, *Pidgey*, or *Caterpie*).
- **Interactive Summary Cards**: View offered Pokémon stats, level, OT Name & Trainer ID, and wanted species list.
- **Offline Claim Boxes**: When another trainer trades for your deposit while you are offline, your received Pokémon is placed in your **Claim Box** waiting for you when you log back in.
- **Recent History Log**: Tracks and displays receipts for the 50 most recent GTS transactions.

---

### 🛡️ 3. Cloudflare HTTPS Security & Self-Cleansing
- **Cloudflare Tunnel (`cloudflared`)**: Secured behind Cloudflare's encrypted HTTPS Tunnel with 100% home IP privacy and Anycast DDoS protection.
- **Self-Cleansing Engine**: Automatically purges abandoned deposits older than 30 days and claim box items older than 60 days.
- **Rate Limiting**: Protects server endpoints against spam or flood attacks.

---

### ⚔️ 4. PVP Link Battles & Link Trading
- **Facing A-Button Interaction**: Walk up to any trainer on the overworld, face them, and press **`A`** to bring up the interaction menu.
- **Real-Time PVP Link Battles**: Integrated with Recomp's native `LinkBattle` engine with pre-battle auto-healing and synchronized RNG seeds.
- **Vanilla Link Trading**: Interactive trade selection menu featuring authentic `TradeAnim` cutscenes, trade evolutions, and forced disk saves.

---

## 🛠️ Installation & Setup

1. Download `gen1online.zip` from the latest release.
2. Place `gen1online.zip` (or extract the folder) into your `mods/` directory:
   ```
   pokemon-gen1-recomp/mods/gen1online/
   ```
3. Enable **Gen1Online** in the in-game Mod Manager menu.

---

## 🕹️ How to Play Online

1. Press **`START`** → Select **`CO-OP ONLINE`**.
2. Select **`CONNECT GTS SERVER`** to synchronize with the live 24/7 Global Trade Station.
3. Select **`HOST SERVER`** or **`JOIN SERVER`** to connect with friends for overworld roaming, PVP battles, and link trading!

---

## 👨‍💻 Credits

Created by **Gamecorner33** (with AI Assistant **Antigravity**).
