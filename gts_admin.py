#!/usr/bin/env python3
"""
Gen1Online Host Administration & Anti-Cheat CLI Tool
Usage:
  python gts_admin.py list                     - List all registered players on server
  python gts_admin.py audit                    - Run anti-cheat audit on all player accounts
  python gts_admin.py view <trainerId>         - View full details for a player
  python gts_admin.py ban <trainerId> [reason] - Ban a player from online play
  python gts_admin.py unban <trainerId>        - Unban a player
  python gts_admin.py remove <trainerId>       - Delete a player from server database & backup
"""

import sys
import json
import urllib.request
import urllib.error
import os

SERVER_URL = os.environ.get("GTS_SERVER_URL", "http://127.0.0.1:7779")

def post_admin_action(op, target_id="", extra=None):
    payload = {
        "action": "admin_action",
        "adminOp": op,
        "targetId": str(target_id)
    }
    if extra:
        payload.update(extra)

    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        SERVER_URL,
        data=data,
        headers={"Content-Type": "application/json"}
    )
    try:
        with urllib.request.urlopen(req, timeout=5) as response:
            res_body = response.read().decode("utf-8")
            return json.loads(res_body)
    except urllib.error.URLError as e:
        print(f"[Admin CLI Error] Cannot connect to GTS server at {SERVER_URL}: {e}")
        return None

def cmd_list():
    res = post_admin_action("list_players")
    if not res or not res.get("success"):
        print("Failed to retrieve player list.")
        return

    players = res.get("players", [])
    print(f"\n================================================================================")
    print(f" Gen1Online Server - Registered Players ({len(players)} total)")
    print(f"================================================================================")
    print(f"{'ID':<8} {'NAME':<12} {'LVL':<5} {'XP':<9} {'SPRITE':<16} {'PVP W/L':<9} {'STATUS':<8} {'FLAGS'}")
    print(f"--------------------------------------------------------------------------------")

    for p in players:
        tid = p.get("trainerId", "?")
        name = p.get("name", "TRAINER")
        lvl = p.get("level", 1)
        xp = p.get("xp", 0)
        sprite = p.get("spriteId", "SPRITE_RED").replace("SPRITE_", "")
        pvp = f"{p.get('pvpWins', 0)}/{p.get('pvpLosses', 0)}"
        status = "BANNED" if p.get("isBanned") else "ACTIVE"
        flags = ", ".join(p.get("antiCheatFlags", [])) or "CLEAN"

        print(f"{tid:<8} {name:<12} {lvl:<5} {xp:<9} {sprite:<16} {pvp:<9} {status:<8} {flags}")
    print(f"================================================================================\n")

def cmd_audit():
    res = post_admin_action("audit")
    if not res or not res.get("success"):
        print("Failed to run anti-cheat audit.")
        return

    flagged = res.get("flagged_players", {})
    print(f"\n================================================================================")
    print(f" Gen1Online Anti-Cheat Audit Report")
    print(f"================================================================================")
    if not flagged:
        print(" All registered players passed anti-cheat verification! (0 violations)")
    else:
        print(f" WARNING: {len(flagged)} player(s) flagged for potential tampering:")
        for tid, data in flagged.items():
            print(f"  - Trainer ID {tid} ({data.get('name')}): Level {data.get('level')}, XP {data.get('xp')}")
            for flag in data.get("flags", []):
                print(f"      * {flag}")
    print(f"================================================================================\n")

def cmd_ban(tid, reason):
    res = post_admin_action("ban_player", tid, {"reason": reason})
    if res and res.get("success"):
        print(f"Successfully banned Trainer ID {tid} (Reason: {reason}).")
    else:
        print(f"Failed to ban Trainer ID {tid}: {res.get('error') if res else 'Network Error'}")

def cmd_unban(tid):
    res = post_admin_action("unban_player", tid)
    if res and res.get("success"):
        print(f"Successfully unbanned Trainer ID {tid}.")
    else:
        print(f"Failed to unban Trainer ID {tid}.")

def cmd_remove(tid):
    res = post_admin_action("remove_player", tid)
    if res and res.get("success"):
        print(f"Successfully removed Trainer ID {tid} from server database & backup.")
    else:
        print(f"Failed to remove Trainer ID {tid}.")

def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return

    cmd = sys.argv[1].lower()
    if cmd == "list":
        cmd_list()
    elif cmd == "audit":
        cmd_audit()
    elif cmd == "ban":
        if len(sys.argv) < 3:
            print("Usage: python gts_admin.py ban <trainerId> [reason]")
            return
        reason = sys.argv[3] if len(sys.argv) > 3 else "Admin Ban"
        cmd_ban(sys.argv[2], reason)
    elif cmd == "unban":
        if len(sys.argv) < 3:
            print("Usage: python gts_admin.py unban <trainerId>")
            return
        cmd_unban(sys.argv[2])
    elif cmd == "remove" or cmd == "delete":
        if len(sys.argv) < 3:
            print("Usage: python gts_admin.py remove <trainerId>")
            return
        cmd_remove(sys.argv[2])
    else:
        print(f"Unknown command: {cmd}")
        print(__doc__)

if __name__ == "__main__":
    main()
