# AGENTS.md

## What this is

A mod for **Pokémon Gen 1 Recomp** (a LÖVE-based recomp with a mod system) that adds online co-op, PVP link battles, link trading, and a persistent GTS. There is no test/build/lint tooling and no Lua dependency tree in this repo — `main.lua` requires engine modules (`src.core.Game`, `src.link.LinkBattle`, `src.pokemon.Party`, etc.) that belong to the host game and are NOT here. `main.lua` cannot be run standalone; verify Lua changes in-game only.

- `main.lua` — all game/mod code (~1780 lines, single file). Entry point per `manifest.json` (`"entry": "main.lua"`). There is no Lua test/build/lint tooling and the `src.*` engine modules it requires are NOT here; verify Lua changes in-game only.
- `src/gen1online/` — the Python server package (managed with **uv**, see `pyproject.toml` + `uv.lock`). Modules by responsibility: `server.py` (HTTP transport/routing), `gts.py` (marketplace handlers), `realtime.py` (position sync/challenges/battle rooms), `storage.py` (PostgreSQL + in-memory store), `ratelimit.py`, `config.py`, `migrate.py` (legacy importer). Requires a reachable `DATABASE_URL` at startup.
- `docker-compose.yml` — runs `postgres` + `gts-server` (`build: .`) together; the server is meant to sit behind a Cloudflare Tunnel (`cloudflared`) or reverse proxy, not exposed directly.
- `migrate.py` — one-time importer from the legacy JSON DB into Postgres (`uv run gen1online-migrate`, or `uv run python -m gen1online.migrate`). Truncates the GTS tables first.
- `gts_database.json` — **frozen legacy seed data only**. The server no longer reads or writes it; it exists solely as input for the migration importer. Do not hand-edit it.
- `mod.zip` — the built mod players install (root-level binary artifact, updated by commits). Contains exactly `main.lua`, `manifest.json`, `mod.card`, `README.md` at the zip root — nothing else. Keep it in sync when `main.lua` changes (rebuild with `zip mod.zip main.lua manifest.json mod.card README.md`; the `src.*` engine modules and the Python server are NOT part of it).
- `manifest.json` (version 0.2.1) vs `mod.card` (version 0.1.0) are out of sync; `mod.card` is a legacy card. `manifest.json` is authoritative.

## Commands

- Run server locally (uv): `uv sync && uv run gen1online-server` (or `uv run python -m gen1online`; binds `0.0.0.0:7779`, override with `HOST`/`PORT`). Env: `HOST` (default `0.0.0.0`), `PORT` (default 7779), `DATABASE_URL` (default `postgresql://gts:gts@localhost:5432/gts`). Requires a running Postgres.
- Run the full stack: `docker compose up -d --build` (builds the uv Dockerfile, waits for a healthy Postgres, then starts the server; also 127.0.0.1:7779).
- Migrate legacy data into Postgres: `uv run gen1online-migrate [path/to/gts_database.json]`.
- Release: pushing a `v*` tag triggers `.github/workflows/release.yml`, which zips `main.lua manifest.json mod.card README.md` into `gen1online.zip` (players only; self-hosters build the server from the repo via `docker compose up -d --build`).

## Architecture / networking

- The mod's only server URL is **hardcoded** in `main.lua:36` (`GTS_SERVER_URL`). Currently `http://127.0.0.1:7779` for local dev against the docker-compose stack — **revert to the `trycloudflare.com` tunnel URL and rebuild `mod.zip` before tagging any release**. Changing deployment = edit that line and rebuild `mod.zip`.
- All networking runs in a LÖVE background thread (`love.thread.newThread`) that does blocking HTTP POST polls. Channels: `gen1mmo_out`/`gen1mmo_in` (position sync), `gen1mmo_battle_out`/`gen1mmo_battle_in` (battle), `gen1mmo_debug`. All HTTP goes to `GTS_SERVER_URL + "/gts"`.
- **Channel semantics are a contract — do not change**: pos-sync is keep-newest (stale positions discarded); battle channel is FIFO and every send must be delivered (drops lose battle moves). A `keepNewest=true` flag on battle polls marks them as droppable polls.
- Server API: GET `/gts/browse`, `/gts/players`, `/gts/profile`, `/gts/claims`; POST `/gts` with JSON `action`: `sync_pos`, `send_challenge`, `clear_challenge`, `send_battle_msg`, `poll_battle_msgs`, `clear_battle_room`, `log_trade_receipt`, `update_profile`, `deposit`, `trade`, `withdraw`, `claim`.
- Client timeouts: 0.5s default for direct calls, 3.5s in the background thread; responses are only trusted on HTTP 200.
- **Server storage split (src/gen1online/storage.py)**: persisted collections (`listings`, `user_counts`, `history`, `claim_boxes`, `profiles`) live in Postgres and are mirrored in the in-memory `db` dict for reads — every mutation writes Postgres transactionally first, then updates memory. `active_players`, `pending_challenges`, `battle_rooms` are transient and stay in-memory only (not in the DB schema). Postgres purges (expired listings/claims, history cap) run on a 30s throttle inside `self_clean_db` because `sync_pos` hammers that path at 10–20 Hz.

## Gotchas

- Server keys `active_players` by `trainerId`. If two players share an ID they filter each other out as "self" and become mutually invisible. IDs are generated with `love.math.random` when `save.player.id` is missing (main.lua:516) — don't switch to plain `math.random` (unseeded → collisions).
- **Never forward `bye` battle messages** (`GtsNetAdapter:send` suppresses them). A `bye` arriving after `clear_battle_room` poisons the opponent's next battle → instant "other player left" loop. Keep both `clear_battle_room` calls in `battle.finish`.
- Server purges players idle 30s (`PLAYER_TIMEOUT_SECONDS`). The keepalive `sync_pos` in the `core.game.update` hook (main.lua:1721) exists so players stay visible while menus/Textboxes cover the overworld — don't remove it.
- Client-side deposit want-list is hardcoded to `{"PIKACHU"}` (`main.lua:1281`) despite the README advertising "up to 3 wanted species"; the deposit limit (3) is enforced on both client and server.
- Server rate limit: 2400 requests/min/IP, resolved from `CF-Connecting-IP` → `X-Forwarded-For` → socket address.
- Battle room IDs must be unique per battle (they embed a random seed) so stale messages from a prior battle can't leak in.
