#!/usr/bin/env python3
"""
Gen1Online - Cloud-Ready Self-Cleansing Global Trade Station (GTS) Server
Features:
- Self-cleansing auto-purge for listings older than 30 days
- Claim box cleanup for items older than 60 days
- Rate limiting per IP (60 requests/minute)
- Cloud deployment readiness (Render, Railway, Heroku, Docker)
"""

import http.server
import socketserver
import json
import os
import time
import sys

# Bind to Cloud PORT or default 7779
PORT = int(os.environ.get("PORT", 7779))
DB_FILE = os.environ.get("GTS_DB_PATH", os.path.join(os.path.dirname(__file__), "gts_database.json"))

# 30 days TTL for listings, 60 days for claim box
LISTING_TTL_SECONDS = 30 * 86400
CLAIM_TTL_SECONDS = 60 * 86400

db = {
    "listings": {},     # listingId -> listing object
    "user_counts": {},  # trainerId -> active deposit count
    "history": [],      # array of last 50 receipts
    "claim_boxes": {},  # trainerId -> array of traded mons
    "next_id": 1001
}

rate_limits = {}

def load_db():
    global db
    if os.path.exists(DB_FILE):
        try:
            with open(DB_FILE, "r", encoding="utf-8") as f:
                db = json.load(f)
            print(f"[GTS Cloud Server] Database loaded: {len(db.get('listings', {}))} active listings.")
        except Exception as e:
            print(f"[GTS Cloud Server] Error loading database: {e}")

def save_db():
    try:
        with open(DB_FILE, "w", encoding="utf-8") as f:
            json.dump(db, f, indent=2)
    except Exception as e:
        print(f"[GTS Cloud Server] Error saving database: {e}")

def self_clean_db():
    """Self-cleansing engine: Purges listings older than 30 days and claim items older than 60 days."""
    now = int(time.time())
    purged_listings = 0
    purged_claims = 0

    # 1. Purge expired listings (> 30 days old)
    expired_ids = []
    for list_id, listing in list(db.get("listings", {}).items()):
        ts = listing.get("timestamp", now)
        if now - ts > LISTING_TTL_SECONDS:
            expired_ids.append(list_id)

    for list_id in expired_ids:
        listing = db["listings"].pop(list_id)
        trainer_id = str(listing.get("trainerId"))
        if trainer_id in db["user_counts"]:
            db["user_counts"][trainer_id] = max(0, db["user_counts"][trainer_id] - 1)
        purged_listings += 1

    # 2. Purge old claim box items (> 60 days old)
    for trainer_id, claims in list(db.get("claim_boxes", {}).items()):
        valid_claims = []
        for claim in claims:
            ts = claim.get("timestamp", now)
            if now - ts <= CLAIM_TTL_SECONDS:
                valid_claims.append(claim)
            else:
                purged_claims += 1
        db["claim_boxes"][trainer_id] = valid_claims

    if purged_listings > 0 or purged_claims > 0:
        print(f"[Self-Cleansing Engine] Purged {purged_listings} expired listings and {purged_claims} old claims.")
        save_db()

def add_receipt(text):
    db["history"].insert(0, {
        "text": text,
        "time": int(time.time())
    })
    db["history"] = db["history"][:50]

def check_rate_limit(ip):
    now = time.time()
    if ip not in rate_limits:
        rate_limits[ip] = []
    rate_limits[ip] = [t for t in rate_limits[ip] if now - t < 60]
    if len(rate_limits[ip]) >= 60:
        return False
    rate_limits[ip].append(now)
    return True

class GTSHandler(http.server.BaseHTTPRequestHandler):
    def _send_json(self, data, status=200):
        body = json.dumps(data).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        client_ip = self.client_address[0]
        if not check_rate_limit(client_ip):
            self._send_json({"error": "RATE LIMIT EXCEEDED"}, status=429)
            return

        load_db()
        self_clean_db()

        if self.path == "/gts/browse" or self.path == "/gts" or self.path == "/":
            self._send_json({
                "success": True,
                "status": "ONLINE",
                "listings": db["listings"],
                "history": db["history"]
            })
        elif self.path.startswith("/gts/claims"):
            trainer_id = None
            if "?" in self.path:
                params = self.path.split("?")[1]
                for p in params.split("&"):
                    if p.startswith("trainerId="):
                        trainer_id = p.split("=")[1]
            claims = db["claim_boxes"].get(str(trainer_id), [])
            listings = [l for l in db["listings"].values() if str(l.get("trainerId")) == str(trainer_id)]
            self._send_json({
                "success": True,
                "claims": claims,
                "my_listings": listings
            })
        else:
            self._send_json({"error": "Endpoint not found"}, status=404)

    def do_POST(self):
        client_ip = self.client_address[0]
        if not check_rate_limit(client_ip):
            self._send_json({"error": "RATE LIMIT EXCEEDED"}, status=429)
            return

        load_db()
        self_clean_db()

        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length).decode("utf-8")
        try:
            req = json.loads(body)
        except Exception:
            self._send_json({"error": "Invalid JSON"}, status=400)
            return

        action = req.get("action")

        if action == "deposit":
            trainer_id = str(req.get("trainerId"))
            trainer_name = req.get("trainerName", "TRAINER")
            offered_mon = req.get("offeredMon")
            wanted = req.get("wanted", [])

            current_count = db["user_counts"].get(trainer_id, 0)
            if current_count >= 3:
                self._send_json({"success": False, "error": "MAX 3 DEPOSITS REACHED"}, status=400)
                return

            list_id = f"GTS_{db['next_id']}"
            db["next_id"] += 1

            listing = {
                "id": list_id,
                "trainerId": trainer_id,
                "trainerName": trainer_name,
                "offeredMon": offered_mon,
                "wanted": wanted,
                "timestamp": int(time.time())
            }

            db["listings"][list_id] = listing
            db["user_counts"][trainer_id] = current_count + 1
            mon_name = offered_mon.get("nickname") or offered_mon.get("species")
            add_receipt(f"{trainer_name} (ID {trainer_id}) DEPOSITED {mon_name} LV{offered_mon.get('level', 1)}")
            save_db()

            self._send_json({"success": True, "listing": listing})

        elif action == "trade":
            list_id = req.get("listingId")
            buyer_id = str(req.get("buyerId"))
            buyer_name = req.get("buyerName", "TRAINER")
            sent_mon = req.get("sentMon")

            if list_id not in db["listings"]:
                self._send_json({"success": False, "error": "LISTING NO LONGER EXISTS"}, status=404)
                return

            listing = db["listings"].pop(list_id)
            seller_id = str(listing["trainerId"])
            db["user_counts"][seller_id] = max(0, db["user_counts"].get(seller_id, 1) - 1)

            if seller_id not in db["claim_boxes"]:
                db["claim_boxes"][seller_id] = []

            offered = listing["offeredMon"]
            off_name = offered.get("nickname") or offered.get("species")
            sent_name = sent_mon.get("nickname") or sent_mon.get("species")

            db["claim_boxes"][seller_id].append({
                "mon": sent_mon,
                "fromName": buyer_name,
                "fromId": buyer_id,
                "originalOffered": off_name,
                "timestamp": int(time.time())
            })

            add_receipt(f"{buyer_name} TRADED {sent_name} TO {listing['trainerName']} FOR {off_name}")
            save_db()

            self._send_json({
                "success": True,
                "receivedMon": offered
            })

        elif action == "withdraw":
            list_id = req.get("listingId")
            trainer_id = str(req.get("trainerId"))

            if list_id in db["listings"] and str(db["listings"][list_id]["trainerId"]) == trainer_id:
                listing = db["listings"].pop(list_id)
                db["user_counts"][trainer_id] = max(0, db["user_counts"].get(trainer_id, 1) - 1)
                save_db()
                self._send_json({"success": True, "returnedMon": listing["offeredMon"]})
            else:
                self._send_json({"success": False, "error": "Listing not found or unauthorized"}, status=404)

        elif action == "claim":
            trainer_id = str(req.get("trainerId"))
            claim_idx = req.get("index", 0)

            claims = db["claim_boxes"].get(trainer_id, [])
            if 0 <= claim_idx < len(claims):
                claimed = claims.pop(claim_idx)
                save_db()
                self._send_json({"success": True, "claimedMon": claimed["mon"]})
            else:
                self._send_json({"success": False, "error": "Claim not found"}, status=404)
        else:
            self._send_json({"error": "Unknown action"}, status=400)

def run_server():
    load_db()
    self_clean_db()
    with socketserver.TCPServer(("", PORT), GTSHandler) as httpd:
        print(f"======================================================")
        print(f"  Gen1Online Cloud GTS Server Running on Port {PORT}")
        print(f"  Database Path: {DB_FILE}")
        print(f"  Self-Cleansing TTL: 30 Days (Listings), 60 Days (Claims)")
        print(f"======================================================")
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            print("\n[GTS Cloud Server] Shutting down gracefully...")
            save_db()

if __name__ == "__main__":
    run_server()
