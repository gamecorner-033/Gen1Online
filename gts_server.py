#!/usr/bin/env python3
"""
Gen1Online - Cloud-Ready Multi-Threaded Self-Cleansing GTS & MMO Overworld Server
Features:
- Live Network Multi-Room Lockstep Challenges (PVP Link Battle & Link Trade popups across players!)
- Guaranteed Delivery on Challenges (Stays pending until accepted/declined or 15s expiration)
- Isolated Multi-Battle Rooms (Supports unlimited simultaneous battles: P1 vs P2, P3 vs P4, etc.)
- 15-Second Expiry on Pending Challenges to Prevent Auto-Battles on Connection
- Live PVP Win/Loss Record Tracking & Persistent Profile Updates
- In-Memory Fast Position Sync (< 1ms response time, zero disk I/O on movement)
- Multi-threaded ThreadingTCPServer for instant simultaneous multi-player connections
- Multi-player 16-player overworld position sync API per map instance
- Real Client IP extraction via Cloudflare `CF-Connecting-IP` header
- Persistent Trainer Profiles & Dedicated Player Leveling System (1 to 100)
- Host-Only Persistent Player Backup File (`players_backup.json`) with Anti-Cheat Audit
- Real-Time Global/Local MMO Chat Relay & Leaderboard Engine
"""

import http.server
import socketserver
import json
import os
import time
import math
import secrets
import re

PORT = int(os.environ.get("PORT", 7779))
DB_FILE = os.environ.get("GTS_DB_PATH", os.path.join(os.path.dirname(__file__), "gts_database.json"))
BACKUP_DB_FILE = os.environ.get("GTS_BACKUP_PATH", os.path.join(os.path.dirname(__file__), "players_backup.json"))

MOD_VERSION = "0.3.4.1"

LISTING_TTL_SECONDS = 30 * 86400
CLAIM_TTL_SECONDS = 60 * 86400
PLAYER_TIMEOUT_SECONDS = 30  # 30s timeout guard for map transitions
CHALLENGE_TTL_SECONDS = 15   # Challenges expire in 15s so stale challenges never launch on join

# Leveling Curve Constants: starts fast, gradually slows down
# Total XP for Level 100 is ~199,000 XP
def calculate_xp_for_level(lvl):
    if lvl <= 1:
        return 0
    return int(50 * ((lvl - 1) ** 1.8))

def calculate_level_from_xp(xp):
    if xp <= 0:
        return 1
    for lvl in range(100, 0, -1):
        if xp >= calculate_xp_for_level(lvl):
            return lvl
    return 1

XP_REWARDS = {
    "catch": 50,
    "wild_battle": 15,
    "trainer_battle": 40,
    "pvp_win": 100,
    "pvp_loss": 25,
    "breeding": 60
}

db = {
    "listings": {},           # listingId -> listing object
    "user_counts": {},        # trainerId -> active deposit count
    "history": [],            # array of last 50 receipts
    "claim_boxes": {},        # trainerId -> array of traded mons
    "profiles": {},           # trainerId -> persistent profile object
    "accounts": {},           # trainerId -> verified MMO player account object
    "chat": [],               # last 100 global chat messages
    "banned_trainers": {},    # trainerId -> { reason, bannedAt }
    "active_players": {},     # trainerId -> live position & state object (IN-MEMORY ONLY)
    "pending_challenges": {}, # targetTrainerId -> challenge object (fromId, fromName, type, party, seed, roomId)
    "battle_rooms": {},        # roomId -> { targetTrainerId -> [pending_messages] }
    "parties": {},             # partyId -> { leaderId, leaderName, members: { tid: { name, level, map, x, y, spriteId, lastSeen } }, created }
    "player_parties": {},      # trainerId -> partyId
    "pending_party_invites": {}, # targetTrainerId -> { fromId, fromName, partyId, timestamp }
    "party_messages": {},      # partyId -> [ { fromId, fromName, text, timestamp } ]
    "party_xp_events": {},     # trainerId -> [ { fromName, xp, reason, timestamp } ]
    "next_id": 1001
}

rate_limits = {}

def load_db():
    global db
    if os.path.exists(DB_FILE):
        try:
            with open(DB_FILE, "r", encoding="utf-8") as f:
                loaded = json.load(f)
                for k, v in loaded.items():
                    if k not in ["active_players", "pending_challenges", "battle_rooms"]:
                        db[k] = v
        except Exception as e:
            print(f"[GTS Cloud Server] Error loading database: {e}")

    # Also restore accounts from backup if available
    if os.path.exists(BACKUP_DB_FILE):
        try:
            with open(BACKUP_DB_FILE, "r", encoding="utf-8") as f:
                backup_data = json.load(f)
                if "accounts" in backup_data:
                    for tid, acc in backup_data["accounts"].items():
                        if tid not in db["accounts"]:
                            db["accounts"][tid] = acc
        except Exception as e:
            print(f"[GTS Cloud Server] Error reading player backup: {e}")

def save_db():
    try:
        save_copy = {k: v for k, v in db.items() if k not in ["active_players", "pending_challenges", "battle_rooms"]}
        with open(DB_FILE, "w", encoding="utf-8") as f:
            json.dump(save_copy, f, indent=2)
    except Exception as e:
        print(f"[GTS Cloud Server] Error saving database: {e}")

    # Always persist host backup file
    save_backup()

def save_backup():
    try:
        backup_copy = {
            "timestamp": int(time.time()),
            "total_players": len(db.get("accounts", {})),
            "accounts": db.get("accounts", {}),
            "banned_trainers": db.get("banned_trainers", {}),
            "history": db.get("history", [])[:50]
        }
        with open(BACKUP_DB_FILE, "w", encoding="utf-8") as f:
            json.dump(backup_copy, f, indent=2)
    except Exception as e:
        print(f"[GTS Cloud Server] Error saving host backup: {e}")

def self_clean_db():
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

    # 3. Purge inactive online players (> 30 seconds timeout)
    for tid, pdata in list(db.get("active_players", {}).items()):
        if now - pdata.get("timestamp", 0) > PLAYER_TIMEOUT_SECONDS:
            db["active_players"].pop(tid, None)

    # 4. Purge stale challenges (> 15 seconds old)
    for tid, cdata in list(db.get("pending_challenges", {}).items()):
        if now - cdata.get("timestamp", 0) > CHALLENGE_TTL_SECONDS:
            db["pending_challenges"].pop(tid, None)

    # 5. Trim chat messages to last 100
    if len(db.get("chat", [])) > 100:
        db["chat"] = db["chat"][-100:]

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
    if len(rate_limits[ip]) >= 2400:
        return False
    rate_limits[ip].append(now)
    return True

# Anti-Cheat Audit Engine
def audit_account_integrity(account):
    flags = []
    xp = account.get("xp", 0)
    level = account.get("level", 1)

    if level < 1 or level > 100:
        flags.append(f"INVALID_LEVEL_{level}")

    min_xp = calculate_xp_for_level(level)
    max_xp = calculate_xp_for_level(level + 1) if level < 100 else 10000000

    if xp < min_xp:
        flags.append(f"XP_UNDERFLOW_{xp}_FOR_LVL_{level}")

    calculated_level = calculate_level_from_xp(xp)
    if calculated_level != level:
        flags.append(f"LEVEL_XP_DESYNC_CALC_{calculated_level}_STATED_{level}")

    if xp > 300000:
        flags.append(f"EXCESSIVE_TOTAL_XP_{xp}")

    return flags


# ---------------------------------------------------------------------------
# Comprehensive Profanity & Slur Filter Engine
# ---------------------------------------------------------------------------
BAD_WORDS = [
    "fuck", "fucker", "fucking", "fucked", "fuckhead", "motherfucker", "fuk", "fck", "fak", "fuc",
    "shit", "shitting", "bullshit", "shithead", "shitty", "shyt", "shtt",
    "bitch", "bitches", "bitching", "bitchass", "btch", "b1tch",
    "asshole", "assholes", "dumbass", "jackass", "fatass", "badass", "ashole",
    "cunt", "cunts",
    "dick", "dicks", "dickhead", "cock", "cocks", "cocksucker",
    "pussy", "pussies", "pusy",
    "bastard", "bastards",
    "slut", "sluts", "slutty",
    "whore", "whores", "whor",
    "nigger", "nigga", "niggaz", "niggers", "niggas", "n1gga", "n1gger",
    "faggot", "fag", "faggots", "fags", "fgt",
    "retard", "retarded", "tard",
    "chink", "kike", "spic", "gook", "wetback", "tranny",
    "pedophile", "pedo", "rapist", "rape",
    "penis", "vagina", "dildo", "blowjob", "handjob", "cum", "cumshot",
    "porn", "porno", "hentai", "nude", "nudes", "boobs", "tits", "titties",
    "twat", "wanker", "prick"
]

EXACT_BAD_WORDS = [
    "ass", "asses", "damn", "dammit", "hell", "sex", "tit", "kys"
]

LEET_MAP = {
    '@': 'a', '4': 'a',
    '8': 'b',
    '(': 'c', '<': 'c', '[': 'c',
    '3': 'e', '€': 'e',
    '6': 'g', '9': 'g',
    '#': 'h',
    '1': 'i', '!': 'i', '|': 'i',
    '0': 'o',
    '5': 's', '$': 's', 'z': 's',
    '7': 't', '+': 't',
    'v': 'u',
}

def normalize_text(text):
    if not text:
        return ""
    t = str(text).lower()
    chars = []
    for ch in t:
        chars.append(LEET_MAP.get(ch, ch))
    normalized = "".join(chars)
    collapsed = re.sub(r'(.)\1{2,}', r'\1', normalized)
    return collapsed

def get_clean_alpha(text):
    norm = normalize_text(text)
    return re.sub(r'[^a-z0-9]', '', norm)

def contains_profanity(text):
    if not text:
        return False
    norm = normalize_text(text)
    alpha = get_clean_alpha(text)
    for w in BAD_WORDS:
        if w in alpha:
            return True
    tokens = re.findall(r'[a-z0-9]+', norm)
    for token in tokens:
        if token in EXACT_BAD_WORDS or token in BAD_WORDS:
            return True
    for w in EXACT_BAD_WORDS:
        pattern = r'\b' + re.escape(w) + r'\b'
        if re.search(pattern, norm):
            return True
    return False

def censor_profanity(text):
    if not text:
        return ""
    words = re.findall(r'\S+|\s+', str(text))
    censored_words = []
    for word in words:
        if word.isspace():
            censored_words.append(word)
            continue
        if contains_profanity(word):
            censored_words.append("*" * len(word))
        else:
            censored_words.append(word)
    res = "".join(censored_words)
    if contains_profanity(text) and res == str(text):
        return "*" * max(3, min(8, len(text)))
    return res

class ThreadedTCPServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    daemon_threads = True
    allow_reuse_address = True


# ---------------------------------------------------------------------------
# Texas Hold'em Multiplayer Server Engine
# ---------------------------------------------------------------------------
RANKS_HOLDEM = ["2", "3", "4", "5", "6", "7", "8", "9", "10", "J", "Q", "K", "A"]
SUITS_HOLDEM = ["C", "D", "H", "S"]
RANK_VALUES_HOLDEM = {r: i + 2 for i, r in enumerate(RANKS_HOLDEM)}

def create_deck():
    deck = []
    for s in SUITS_HOLDEM:
        for r in RANKS_HOLDEM:
            deck.append({"rank": r, "suit": s, "val": RANK_VALUES_HOLDEM[r]})
    secrets.SystemRandom().shuffle(deck)
    return deck

def eval_5_card_hand(cards):
    vals = sorted([c["val"] for c in cards], reverse=True)
    counts = {}
    suits = {}
    for c in cards:
        counts[c["val"]] = counts.get(c["val"], 0) + 1
        suits[c["suit"]] = suits.get(c["suit"], 0) + 1
    
    is_flush = len(suits) == 1
    is_straight = False
    straight_high = 0
    unique_vals = sorted(list(set(vals)), reverse=True)
    if len(unique_vals) == 5:
        if unique_vals[0] - unique_vals[4] == 4:
            is_straight = True
            straight_high = unique_vals[0]
        elif unique_vals == [14, 5, 4, 3, 2]:
            is_straight = True
            straight_high = 5
            
    if is_flush and is_straight:
        if straight_high == 14:
            return (9, [14], "ROYAL FLUSH")
        return (8, [straight_high], "STRAIGHT FLUSH")
        
    sorted_groups = sorted(counts.items(), key=lambda x: (x[1], x[0]), reverse=True)
    
    if sorted_groups[0][1] == 4:
        return (7, [sorted_groups[0][0], sorted_groups[1][0]], "FOUR OF A KIND")
    if sorted_groups[0][1] == 3 and sorted_groups[1][1] == 2:
        return (6, [sorted_groups[0][0], sorted_groups[1][0]], "FULL HOUSE")
    if is_flush:
        return (5, vals, "FLUSH")
    if is_straight:
        return (4, [straight_high], "STRAIGHT")
    if sorted_groups[0][1] == 3:
        kickers = [x[0] for x in sorted_groups[1:]]
        return (3, [sorted_groups[0][0]] + kickers, "THREE OF A KIND")
    if sorted_groups[0][1] == 2 and sorted_groups[1][1] == 2:
        kicker = sorted_groups[2][0]
        return (2, [sorted_groups[0][0], sorted_groups[1][0], kicker], "TWO PAIR")
    if sorted_groups[0][1] == 2:
        kickers = [x[0] for x in sorted_groups[1:]]
        return (1, [sorted_groups[0][0]] + kickers, "ONE PAIR")
    return (0, vals, "HIGH CARD")

def evaluate_best_7_hand(seven_cards):
    import itertools
    best_score = None
    best_name = "HIGH CARD"
    for combo in itertools.combinations(seven_cards, 5):
        score_cat, score_tb, name = eval_5_card_hand(list(combo))
        score_tuple = (score_cat, score_tb)
        if best_score is None or score_tuple > best_score:
            best_score = score_tuple
            best_name = name
    return best_score, best_name

class HoldemPlayer:
    def __init__(self, trainer_id, name, chips):
        self.trainer_id = str(trainer_id)
        self.name = name
        self.chips = int(chips)
        self.hole_cards = []
        self.current_bet = 0
        self.total_hand_bet = 0
        self.folded = False
        self.acted = False
        self.all_in = False
        self.last_action = "SEATED"
        self.last_seen = time.time()
        self.evaluated_score = None
        self.evaluated_hand_name = ""

class HoldemTable:
    def __init__(self, table_id, name, min_bet, max_seats=6):
        self.table_id = table_id
        self.name = name
        self.min_bet = int(min_bet)
        self.max_seats = max_seats
        self.players = []
        self.state = "waiting"
        self.pot = 0
        self.current_bet = 0
        self.min_raise = self.min_bet
        self.dealer_idx = 0
        self.active_turn_idx = 0
        self.deck = []
        self.community_cards = []
        self.turn_start_time = 0
        self.turn_timeout_seconds = 15
        self.last_action_text = f"TABLE {name.upper()} OPEN"
        self.winners = []

    def get_player(self, trainer_id):
        for p in self.players:
            if p.trainer_id == str(trainer_id):
                return p
        return None

    def join_player(self, trainer_id, name, buy_in):
        p = self.get_player(trainer_id)
        if p:
            p.name = name
            p.chips = max(p.chips, int(buy_in))
            p.last_seen = time.time()
            return True, "ALREADY SEATED"
        if len(self.players) >= self.max_seats:
            return False, "TABLE IS FULL"
        new_p = HoldemPlayer(trainer_id, name, buy_in)
        self.players.append(new_p)
        self.last_action_text = f"{name} JOINED THE TABLE"
        if len(self.players) >= 2 and self.state == "waiting":
            self.start_new_hand()
        return True, "JOINED"

    def leave_player(self, trainer_id):
        p = self.get_player(trainer_id)
        if not p:
            return 0
        chips = p.chips
        idx = self.players.index(p)
        self.players.remove(p)
        self.last_action_text = f"{p.name} LEFT THE TABLE"
        if len(self.players) < 2:
            self.state = "waiting"
            self.community_cards = []
            self.pot = 0
        elif self.active_turn_idx == idx:
            self.ensure_active_turn_valid()
        return chips

    def start_new_hand(self):
        active_candidates = [p for p in self.players if p.chips >= self.min_bet]
        if len(active_candidates) < 2:
            self.state = "waiting"
            self.community_cards = []
            self.pot = 0
            self.last_action_text = "WAITING FOR PLAYERS (MIN 2)"
            return

        self.deck = create_deck()
        self.community_cards = []
        self.pot = 0
        self.current_bet = self.min_bet
        self.min_raise = self.min_bet
        self.winners = []
        self.dealer_idx = (self.dealer_idx + 1) % len(self.players)

        for p in self.players:
            p.hole_cards = [self.deck.pop(), self.deck.pop()]
            p.current_bet = 0
            p.total_hand_bet = 0
            p.folded = False
            p.acted = False
            p.all_in = False
            p.last_action = "PLAYING"
            p.evaluated_score = None
            p.evaluated_hand_name = ""

        sb_idx = (self.dealer_idx + 1) % len(self.players)
        bb_idx = (self.dealer_idx + 2) % len(self.players)
        
        sb_amount = max(1, self.min_bet // 2)
        bb_amount = self.min_bet

        sb_player = self.players[sb_idx]
        sb_actual = min(sb_player.chips, sb_amount)
        sb_player.chips -= sb_actual
        sb_player.current_bet = sb_actual
        sb_player.total_hand_bet = sb_actual
        self.pot += sb_actual

        bb_player = self.players[bb_idx]
        bb_actual = min(bb_player.chips, bb_amount)
        bb_player.chips -= bb_actual
        bb_player.current_bet = bb_actual
        bb_player.total_hand_bet = bb_actual
        self.pot += bb_actual

        self.state = "preflop"
        self.active_turn_idx = (bb_idx + 1) % len(self.players)
        self.turn_start_time = time.time()
        self.last_action_text = f"NEW HAND! BLINDS {sb_actual}/{bb_actual} POSTED"

    def advance_phase(self):
        for p in self.players:
            p.current_bet = 0
            p.acted = False
        self.current_bet = 0
        self.min_raise = self.min_bet

        if self.state == "preflop":
            self.state = "flop"
            self.community_cards = [self.deck.pop(), self.deck.pop(), self.deck.pop()]
            self.last_action_text = "THE FLOP IS DEALT!"
        elif self.state == "flop":
            self.state = "turn"
            self.community_cards.append(self.deck.pop())
            self.last_action_text = "THE TURN IS DEALT!"
        elif self.state == "turn":
            self.state = "river"
            self.community_cards.append(self.deck.pop())
            self.last_action_text = "THE RIVER IS DEALT!"
        elif self.state == "river":
            self.state = "showdown"
            self.evaluate_showdown()
            return

        self.active_turn_idx = (self.dealer_idx + 1) % len(self.players)
        self.ensure_active_turn_valid()

    def evaluate_showdown(self):
        active_players = [p for p in self.players if not p.folded]
        if not active_players:
            self.state = "waiting"
            return
        
        if len(active_players) == 1:
            winner = active_players[0]
            winner.chips += self.pot
            self.winners = [{"trainerId": winner.trainer_id, "name": winner.name, "amount": self.pot, "handName": "LAST PLAYER STANDING"}]
            self.last_action_text = f"{winner.name} WINS {self.pot} COINS (OTHERS FOLDED)!"
            self.state = "payout"
            self.turn_start_time = time.time()
            return

        best_score = None
        winners = []
        for p in active_players:
            seven = p.hole_cards + self.community_cards
            score_tuple, hand_name = evaluate_best_7_hand(seven)
            p.evaluated_score = score_tuple
            p.evaluated_hand_name = hand_name
            if best_score is None or score_tuple > best_score:
                best_score = score_tuple
                winners = [p]
            elif score_tuple == best_score:
                winners.append(p)

        split_pot = self.pot // len(winners)
        self.winners = []
        for w in winners:
            w.chips += split_pot
            self.winners.append({
                "trainerId": w.trainer_id,
                "name": w.name,
                "amount": split_pot,
                "handName": w.evaluated_hand_name,
                "cards": w.hole_cards
            })
        winner_names = " & ".join([w.name for w in winners])
        self.last_action_text = f"{winner_names} WINS WITH {winners[0].evaluated_hand_name}!"
        self.state = "payout"
        self.turn_start_time = time.time()

    def ensure_active_turn_valid(self):
        active_unfolded = [p for p in self.players if not p.folded]
        if len(active_unfolded) <= 1:
            self.evaluate_showdown()
            return

        round_complete = True
        for p in active_unfolded:
            if not p.all_in and (not p.acted or p.current_bet < self.current_bet):
                round_complete = False
                break

        if round_complete:
            self.advance_phase()
            return

        count = 0
        while count < len(self.players):
            p = self.players[self.active_turn_idx]
            if not p.folded and not p.all_in and (not p.acted or p.current_bet < self.current_bet):
                self.turn_start_time = time.time()
                return
            self.active_turn_idx = (self.active_turn_idx + 1) % len(self.players)
            count += 1
        
        self.advance_phase()

    def process_action(self, trainer_id, action_type, amount=0):
        if self.state in ("waiting", "showdown", "payout"):
            return False, "ROUND NOT IN PROGRESS"

        if not (0 <= self.active_turn_idx < len(self.players)):
            return False, "INVALID TURN"

        curr_p = self.players[self.active_turn_idx]
        if curr_p.trainer_id != str(trainer_id):
            return False, "NOT YOUR TURN"

        call_needed = self.current_bet - curr_p.current_bet

        if action_type == "fold":
            curr_p.folded = True
            curr_p.acted = True
            curr_p.last_action = "FOLD"
            self.last_action_text = f"{curr_p.name} FOLDED"
            active_left = [p for p in self.players if not p.folded]
            if len(active_left) <= 1:
                self.evaluate_showdown()
                return True, "FOLDED"

        elif action_type == "check":
            if call_needed > 0:
                return False, f"CANNOT CHECK (NEED {call_needed} TO CALL)"
            curr_p.acted = True
            curr_p.last_action = "CHECK"
            self.last_action_text = f"{curr_p.name} CHECKED"

        elif action_type == "call":
            actual_call = min(curr_p.chips, call_needed)
            curr_p.chips -= actual_call
            curr_p.current_bet += actual_call
            curr_p.total_hand_bet += actual_call
            self.pot += actual_call
            if curr_p.chips == 0:
                curr_p.all_in = True
            curr_p.acted = True
            curr_p.last_action = f"CALL {actual_call}"
            self.last_action_text = f"{curr_p.name} CALLED {actual_call}"

        elif action_type in ("bet", "raise"):
            bet_target = amount if amount > 0 else (self.current_bet + self.min_raise)
            additional_needed = bet_target - curr_p.current_bet
            if additional_needed <= 0 or additional_needed > curr_p.chips:
                additional_needed = curr_p.chips
                bet_target = curr_p.current_bet + additional_needed
            
            curr_p.chips -= additional_needed
            curr_p.current_bet = bet_target
            curr_p.total_hand_bet += additional_needed
            self.pot += additional_needed
            if curr_p.chips == 0:
                curr_p.all_in = True
            
            if bet_target > self.current_bet:
                self.min_raise = bet_target - self.current_bet
                self.current_bet = bet_target
                for other in self.players:
                    if other != curr_p and not other.folded and not other.all_in:
                        other.acted = False

            curr_p.acted = True
            curr_p.last_action = f"RAISE TO {bet_target}"
            self.last_action_text = f"{curr_p.name} RAISED TO {bet_target}"
        else:
            return False, "UNKNOWN ACTION"

        self.active_turn_idx = (self.active_turn_idx + 1) % len(self.players)
        self.ensure_active_turn_valid()
        return True, "ACTION PROCESSED"

    def tick(self):
        now = time.time()
        for p in list(self.players):
            if now - p.last_seen > 45.0:
                self.leave_player(p.trainer_id)

        if self.state == "waiting":
            if len(self.players) >= 2:
                self.start_new_hand()
        elif self.state in ("payout", "showdown"):
            if now - self.turn_start_time >= 4.0:
                self.start_new_hand()
        else:
            if now - self.turn_start_time > self.turn_timeout_seconds:
                if 0 <= self.active_turn_idx < len(self.players):
                    curr_p = self.players[self.active_turn_idx]
                    call_needed = self.current_bet - curr_p.current_bet
                    if call_needed == 0:
                        self.process_action(curr_p.trainer_id, "check")
                    else:
                        self.process_action(curr_p.trainer_id, "fold")

    def get_client_state(self, client_trainer_id):
        self.tick()
        client_p = self.get_player(client_trainer_id)
        if client_p:
            client_p.last_seen = time.time()

        seats_data = []
        for i, p in enumerate(self.players):
            s_dict = {
                "seatIdx": i,
                "trainerId": p.trainer_id,
                "name": p.name,
                "chips": p.chips,
                "currentBet": p.current_bet,
                "folded": p.folded,
                "allIn": p.all_in,
                "isDealer": (i == self.dealer_idx),
                "isTurn": (i == self.active_turn_idx and self.state not in ("waiting", "showdown", "payout")),
                "lastAction": p.last_action,
                "cards": p.hole_cards if (self.state in ("showdown", "payout") or p.trainer_id == str(client_trainer_id)) else []
            }
            seats_data.append(s_dict)

        my_turn = False
        allowed_actions = []
        call_amount = 0
        min_raise = self.current_bet + self.min_raise
        my_hand_name = ""

        if client_p and not client_p.folded and self.state not in ("waiting", "showdown", "payout"):
            if 0 <= self.active_turn_idx < len(self.players) and self.players[self.active_turn_idx] == client_p:
                my_turn = True
                call_needed = self.current_bet - client_p.current_bet
                call_amount = min(client_p.chips, call_needed)
                if call_needed == 0:
                    allowed_actions = ["check", "bet", "fold"]
                else:
                    allowed_actions = ["call", "raise", "fold"]

            if client_p.hole_cards:
                all_known = client_p.hole_cards + self.community_cards
                if len(all_known) >= 5:
                    _, my_hand_name = evaluate_best_7_hand(all_known)
                else:
                    my_hand_name = "HOLDEM HAND"

        time_left = max(0, int(self.turn_timeout_seconds - (time.time() - self.turn_start_time)))

        return {
            "tableId": self.table_id,
            "tableName": self.name,
            "minBet": self.min_bet,
            "state": self.state,
            "pot": self.pot,
            "currentBet": self.current_bet,
            "communityCards": self.community_cards,
            "seats": seats_data,
            "myCards": client_p.hole_cards if client_p else [],
            "myChips": client_p.chips if client_p else 0,
            "myTurn": my_turn,
            "allowedActions": allowed_actions,
            "callAmount": call_amount,
            "minRaise": min_raise,
            "myHandName": my_hand_name,
            "lastActionText": self.last_action_text,
            "timeRemaining": time_left,
            "winners": self.winners
        }

# Global Poker Tables
holdem_tables = {
    "table_10": HoldemTable("table_10", "Starter Lounge (10c)", 10),
    "table_50": HoldemTable("table_50", "Celadon High-Roller (50c)", 50),
    "table_100": HoldemTable("table_100", "Silph Executive (100c)", 100),
    "table_500": HoldemTable("table_500", "Champion's Table (500c)", 500)
}

class GTSHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        return

    def get_real_ip(self):
        cf_ip = self.headers.get("CF-Connecting-IP")
        if cf_ip: return cf_ip
        xf_ip = self.headers.get("X-Forwarded-For")
        if xf_ip: return xf_ip.split(",")[0].strip()
        return self.client_address[0]

    def _send_json(self, data, status=200):
        body = json.dumps(data).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        # Strict Mod Version Gate for GET requests (except public server discovery)
        path_only = self.path.split("?")[0]
        if not path_only.startswith("/server/info") and path_only != "/":
            client_ver = self.headers.get("X-Mod-Version", "").strip()
            if not client_ver and "?" in self.path:
                for p in self.path.split("?")[1].split("&"):
                    if p.startswith("version=") or p.startswith("modVersion="):
                        client_ver = p.split("=")[1].strip()
            if not client_ver or client_ver != MOD_VERSION:
                self._send_json({
                    "success": False,
                    "error": "VERSION_MISMATCH",
                    "serverVersion": MOD_VERSION,
                    "clientVersion": client_ver or "LEGACY_OUTDATED",
                    "message": f"VERSION MISMATCH! SERVER REQUIRES V{MOD_VERSION}, PLEASE UPDATE YOUR MOD!"
                }, status=426)
                return

        client_ip = self.get_real_ip()
        if not check_rate_limit(client_ip):
            self._send_json({"error": "RATE LIMIT EXCEEDED"}, status=429)
            return

        self_clean_db()

        if path_only == "/gts/browse" or path_only == "/gts" or path_only == "/":
            self._send_json({
                "success": True,
                "status": "ONLINE",
                "active_player_count": len(db["active_players"]),
                "active_players": db["active_players"],
                "listings": db["listings"],
                "history": db["history"]
            })
        elif path_only.startswith("/gts/players"):
            self._send_json({
                "success": True,
                "online_count": len(db["active_players"]),
                "players": db["active_players"]
            })
        elif path_only.startswith("/gts/profile"):
            trainer_id = None
            if "?" in self.path:
                params = self.path.split("?")[1]
                for p in params.split("&"):
                    if p.startswith("trainerId="):
                        trainer_id = p.split("=")[1]
            profile = db["profiles"].get(str(trainer_id), {})
            account = db.get("accounts", {}).get(str(trainer_id), {})
            
            # Compute composite profile
            level = account.get("level", profile.get("level", 1))
            xp = account.get("xp", profile.get("xp", 0))
            pvp_wins = account.get("pvpWins", profile.get("pvpWins", 0))
            pvp_losses = account.get("pvpLosses", profile.get("pvpLosses", 0))
            gts_trades = account.get("gtsTrades", profile.get("gtsTrades", 0))
            wild_battles = account.get("wildBattles", 0)
            trainer_battles = account.get("trainerBattles", 0)
            
            # Calculate server-wide ranking (1/N is highest rank, N/N is lowest rank with live total count)
            all_accs_dict = {}
            for tid, acc in db.get("accounts", {}).items():
                if not acc.get("isBanned", False):
                    all_accs_dict[str(tid)] = acc

            for tid, p in db.get("profiles", {}).items():
                if str(tid) not in all_accs_dict and str(tid) not in db.get("banned_trainers", {}):
                    all_accs_dict[str(tid)] = {
                        "trainerId": str(tid),
                        "name": p.get("name", "TRAINER"),
                        "level": p.get("level", 1),
                        "xp": p.get("xp", 0),
                        "pvpWins": p.get("pvpWins", 0),
                        "badges": p.get("badges", 0),
                        "pokedexCount": p.get("pokedexCount", 0)
                    }

            if str(trainer_id) not in all_accs_dict and trainer_id is not None and str(trainer_id) not in db.get("banned_trainers", {}):
                all_accs_dict[str(trainer_id)] = {
                    "trainerId": str(trainer_id),
                    "name": account.get("name", profile.get("name", "TRAINER")),
                    "level": level,
                    "xp": xp,
                    "pvpWins": pvp_wins,
                    "badges": account.get("badges", profile.get("badges", 0)),
                    "pokedexCount": account.get("pokedexCount", profile.get("pokedexCount", 0))
                }

            all_accs = list(all_accs_dict.values())
            all_accs.sort(key=lambda a: (
                int(a.get("level", 1)),
                int(a.get("xp", 0)),
                int(a.get("pvpWins", 0)),
                int(a.get("badges", 0)),
                int(a.get("pokedexCount", 0))
            ), reverse=True)

            total_players_count = max(1, len(all_accs))
            server_rank_num = total_players_count
            for idx, a in enumerate(all_accs, start=1):
                if str(a.get("trainerId")) == str(trainer_id):
                    server_rank_num = idx
                    break
            
            def get_rank(lvl, wins):
                if lvl >= 100: return "POKéMON LEGEND"
                elif lvl >= 90: return "GRAND MASTER"
                elif lvl >= 80: return "CHAMPION"
                elif lvl >= 70: return "ELITE FOUR"
                elif lvl >= 60: return "VETERAN"
                elif lvl >= 50: return "MASTER"
                elif lvl >= 40: return "ACE TRAINER"
                elif lvl >= 30: return "EXPERT"
                elif lvl >= 20: return "TRAINER"
                elif lvl >= 10: return "ROOKIE"
                else: return "NOVICE"
                
            rank = profile.get("rank") or get_rank(level, pvp_wins)
            blackouts = account.get("blackoutCount", profile.get("blackouts", 0))
            merged_profile = {
                "trainerId": trainer_id,
                "name": account.get("name", profile.get("name", "TRAINER")),
                "level": level,
                "xp": xp,
                "rank": rank,
                "serverRank": server_rank_num,
                "totalPlayers": total_players_count,
                "title": profile.get("title", "ACE TRAINER"),
                "badges": account.get("badges", profile.get("badges", 0)),
                "pokedexCount": account.get("pokedexCount", profile.get("pokedexCount", 0)),
                "pvpWins": pvp_wins,
                "pvpLosses": pvp_losses,
                "wildBattles": wild_battles,
                "trainerBattles": trainer_battles,
                "blackouts": blackouts,
                "blackoutCount": blackouts,
                "favoriteMon": profile.get("favoriteMon", "PIKACHU"),
                "gtsTrades": gts_trades
            }
            self._send_json({
                "success": True,
                "profile": merged_profile,
                "account": account
            })
        elif path_only.startswith("/gts/claims"):
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
        elif path_only.startswith("/player/check_name"):
            name = ""
            if "?" in self.path:
                params = self.path.split("?")[1]
                for p in params.split("&"):
                    if p.startswith("name="):
                        name = p.split("=")[1].strip()
            name_clean = name.upper()
            taken = False
            for acc in db.get("accounts", {}).values():
                if acc.get("name", "").upper() == name_clean:
                    taken = True
                    break
            self._send_json({
                "success": True,
                "name": name,
                "taken": taken
            })
        elif path_only.startswith("/chat/history"):
            self._send_json({
                "success": True,
                "messages": db.get("chat", [])[-50:]
            })
        elif path_only.startswith("/server/info"):
            self._send_json({
                "success": True,
                "version": MOD_VERSION,
                "modVersion": MOD_VERSION,
                "serverName": "Gen 1 Online Official MMO Server",
                "activePlayers": len(db.get("active_players", {})),
                "totalAccounts": len(db.get("accounts", {}))
            })
        elif path_only.startswith("/mmo/leaderboard"):
            all_accounts = list(db.get("accounts", {}).values())
            # Filter out banned accounts
            valid_accounts = [a for a in all_accounts if not a.get("isBanned", False)]
            # Sort by Level DESC, then PVP Wins DESC, then Total XP DESC
            sorted_players = sorted(
                valid_accounts,
                key=lambda a: (a.get("level", 1), a.get("pvpWins", 0), a.get("xp", 0)),
                reverse=True
            )
            top_leaderboard = sorted_players[:25]
            self._send_json({
                "success": True,
                "total_players": len(valid_accounts),
                "leaderboard": top_leaderboard
            })
        else:
            self._send_json({"error": "Endpoint not found"}, status=404)

    def do_POST(self):
        client_ip = self.get_real_ip()
        if not check_rate_limit(client_ip):
            self._send_json({"error": "RATE LIMIT EXCEEDED"}, status=429)
            return

        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length).decode("utf-8")
        try:
            req = json.loads(body)
        except Exception:
            self._send_json({"error": "Invalid JSON"}, status=400)
            return

        client_ver = str(req.get("modVersion", req.get("version", ""))).strip()
        # Strict Mod Version Enforcement: Reject legacy or mismatched versions
        if not client_ver or client_ver != MOD_VERSION:
            self._send_json({
                "success": False,
                "error": "VERSION_MISMATCH",
                "serverVersion": MOD_VERSION,
                "clientVersion": client_ver or "LEGACY_OUTDATED",
                "message": f"VERSION MISMATCH! SERVER REQUIRES V{MOD_VERSION}, YOUR CLIENT IS ON V{client_ver or 'LEGACY'}. PLEASE UPDATE YOUR MOD!"
            }, status=426)
            return

        action = req.get("action")
        now = int(time.time())

        # 1. High-Speed In-Memory MMO Overworld Position Sync Endpoint
        if action == "sync_pos":
            trainer_id = str(req.get("trainerId"))

            if trainer_id in db.get("banned_trainers", {}):
                self._send_json({"success": False, "error": "BANNED"}, status=403)
                return

            session_id = str(req.get("sessionId", "")).strip()
            existing_player = db["active_players"].get(trainer_id)

            # Duplicate Player Failsafe: Ensure 2 of the same player cannot be active simultaneously
            if existing_player and session_id:
                old_session = str(existing_player.get("sessionId", "")).strip()
                old_ts = existing_player.get("timestamp", 0)
                # If another session is actively pinging within the last 10 seconds:
                if old_session and old_session != session_id and (now - old_ts < 10):
                    self._send_json({
                        "success": False,
                        "error": "ALREADY_LOGGED_IN",
                        "message": "ACCOUNT ALREADY ACTIVE ON ANOTHER DEVICE!"
                    }, status=409)
                    return

            map_id = req.get("map")
            sprite_id = req.get("spriteId", "SPRITE_RED")
            is_first_sync = (trainer_id not in db["active_players"])
            player_entry = {
                "trainerId": trainer_id,
                "sessionId": session_id,
                "name": req.get("name", "TRAINER"),
                "spriteId": sprite_id,
                "map": map_id,
                "x": req.get("x", 5),
                "y": req.get("y", 5),
                "px": req.get("px"),
                "py": req.get("py"),
                "fx": req.get("fx", 5),
                "fy": req.get("fy", 5),
                "facing": req.get("facing", "down"),
                "moving": req.get("moving", False),
                "species": req.get("species"),
                "title": req.get("title", "ROOKIE"),
                "level": req.get("level", 1),
                "modVersion": str(req.get("modVersion", req.get("version", MOD_VERSION))),
                "gameVersion": str(req.get("gameVersion", "Pokemon Red")),
                "recompVersion": str(req.get("recompVersion", "0.0.0-dev")),
                "ip": client_ip,
                "timestamp": now
            }

            db["active_players"][trainer_id] = player_entry

            if is_first_sync:
                print(f"[MMO Active Player] {player_entry['name']} (ID {trainer_id}) | Map: {map_id} | Mod: v{player_entry['modVersion']} | Game: {player_entry['gameVersion']} | Recomp: {player_entry['recompVersion']} | IP: {client_ip}")

            # Fast cleanup for inactive players (> 30s)
            for tid, pdata in list(db["active_players"].items()):
                if now - pdata.get("timestamp", 0) > PLAYER_TIMEOUT_SECONDS:
                    db["active_players"].pop(tid, None)

            # Filter active players on the same map (up to 16 players)
            map_players = []
            for tid, p in db["active_players"].items():
                if tid != trainer_id and p.get("map") == map_id:
                    map_players.append(p)
                    if len(map_players) >= 16:
                        break

            # Check if there is a pending challenge (do not pop so delivery is guaranteed)
            challenge = db["pending_challenges"].get(trainer_id)
            if challenge and (now - challenge.get("timestamp", 0) > CHALLENGE_TTL_SECONDS):
                db["pending_challenges"].pop(trainer_id, None)
                challenge = None

            
            # Check for Party Invites & Party Shared XP
            party_invite = db.get("pending_party_invites", {}).get(trainer_id)
            if party_invite and (now - party_invite.get("timestamp", 0) > 30):
                db.get("pending_party_invites", {}).pop(trainer_id, None)
                party_invite = None

            party_xp_list = db.get("party_xp_events", {}).pop(trainer_id, [])
            party_id = db.get("player_parties", {}).get(trainer_id)
            party_info = db.get("parties", {}).get(party_id) if party_id else None
            if party_info and trainer_id in party_info.get("members", {}):
                party_info["members"][trainer_id]["map"] = map_id
                party_info["members"][trainer_id]["x"] = req.get("x", 5)
                party_info["members"][trainer_id]["y"] = req.get("y", 5)
                party_info["members"][trainer_id]["level"] = req.get("level", 1)
                party_info["members"][trainer_id]["lastSeen"] = now

            self._send_json({
                "success": True,
                "players": map_players,
                "challenge": challenge,
                "partyInvite": party_invite,
                "partyXp": party_xp_list,
                "party": party_info
            })

        # 2. Player Account Registration & Fresh Profile Creation
        elif action == "register_player":
            trainer_id = str(req.get("trainerId"))
            name = req.get("name", "TRAINER").strip()
            sprite_id = req.get("spriteId", "SPRITE_RED")
            title = req.get("title", "NOVICE")

            if contains_profanity(name):
                self._send_json({"success": False, "error": "Name contains inappropriate language"}, status=400)
                return

            if contains_profanity(title):
                self._send_json({"success": False, "error": "Title contains inappropriate language"}, status=400)
                return

            # Check if name is already registered by another trainerId
            name_upper = name.upper()
            for tid, acc in db.get("accounts", {}).items():
                if tid != trainer_id and acc.get("name", "").upper() == name_upper:
                    self._send_json({"success": False, "error": "NAME_TAKEN"}, status=409)
                    return

            # Check if trainer is banned
            if trainer_id in db.get("banned_trainers", {}):
                self._send_json({"success": False, "error": "BANNED"}, status=403)
                return

            # Create or restore account
            existing_account = db.get("accounts", {}).get(trainer_id)
            token = req.get("token") or (existing_account.get("token") if existing_account else secrets.token_hex(4).upper())

            account = {
                "trainerId": trainer_id,
                "name": name,
                "spriteId": sprite_id,
                "level": existing_account.get("level", 1) if existing_account else 1,
                "xp": existing_account.get("xp", 0) if existing_account else 0,
                "token": token,
                "badges": req.get("badges", 0),
                "pokedexCount": req.get("pokedexCount", 0),
                "wildBattles": existing_account.get("wildBattles", 0) if existing_account else 0,
                "trainerBattles": existing_account.get("trainerBattles", 0) if existing_account else 0,
                "pvpWins": existing_account.get("pvpWins", 0) if existing_account else 0,
                "pvpLosses": existing_account.get("pvpLosses", 0) if existing_account else 0,
                "breedingCount": existing_account.get("breedingCount", 0) if existing_account else 0,
                "title": req.get("title", "ROOKIE"),
                "favoriteMon": req.get("favoriteMon", "PIKACHU"),
                "isBanned": False,
                "createdAt": existing_account.get("createdAt", now) if existing_account else now,
                "lastSeen": now
            }

            db["accounts"][trainer_id] = account
            save_db()

            self._send_json({
                "success": True,
                "account": account
            })

        # 3. Player Token Redemption & Save Restoration Endpoint
        elif action == "redeem_token":
            raw_token = str(req.get("token", "")).strip().upper()
            if not raw_token:
                self._send_json({"success": False, "error": "EMPTY_TOKEN"}, status=400)
                return

            found_account = None
            for tid, acc in db.get("accounts", {}).items():
                if str(acc.get("token", "")).strip().upper() == raw_token:
                    found_account = acc
                    break

            if not found_account:
                self._send_json({"success": False, "error": "TOKEN_NOT_FOUND"}, status=404)
                return

            if found_account.get("isBanned", False):
                self._send_json({"success": False, "error": "BANNED"}, status=403)
                return

            profile = db.get("profiles", {}).get(str(found_account.get("trainerId")), {})
            self._send_json({
                "success": True,
                "account": found_account,
                "profile": profile
            })

        # 3. Synchronized XP Gain & Leveling Verification
        elif action == "sync_xp":
            trainer_id = str(req.get("trainerId"))
            token = req.get("token")
            xp_type = req.get("xpType", "wild_battle")
            delta_xp = XP_REWARDS.get(xp_type, 10)

            account = db.get("accounts", {}).get(trainer_id)
            if not account:
                self._send_json({"success": False, "error": "ACCOUNT_NOT_FOUND"}, status=404)
                return

            if account.get("isBanned", False):
                self._send_json({"success": False, "error": "BANNED"}, status=403)
                return

            # Token authentication
            if token and account.get("token") and token != account.get("token"):
                self._send_json({"success": False, "error": "INVALID_TOKEN"}, status=401)
                return

            old_level = account.get("level", 1)
            current_xp = account.get("xp", 0) + delta_xp

            if xp_type == "wild_battle":
                account["wildBattles"] = account.get("wildBattles", 0) + 1
            elif xp_type == "trainer_battle":
                account["trainerBattles"] = account.get("trainerBattles", 0) + 1
            elif xp_type == "catch":
                account["pokedexCount"] = req.get("pokedexCount", account.get("pokedexCount", 0) + 1)
            elif xp_type == "pvp_win":
                account["pvpWins"] = account.get("pvpWins", 0) + 1
            elif xp_type == "pvp_loss":
                account["pvpLosses"] = account.get("pvpLosses", 0) + 1
            elif xp_type == "breeding":
                account["breedingCount"] = account.get("breedingCount", 0) + 1

            new_level = calculate_level_from_xp(current_xp)
            new_level = min(100, max(1, new_level))

            account["xp"] = current_xp
            account["level"] = new_level
            account["lastSeen"] = now
            if "badges" in req: account["badges"] = req["badges"]
            if "pokedexCount" in req: account["pokedexCount"] = req["pokedexCount"]

            leveled_up = new_level > old_level
            if leveled_up:
                add_receipt(f"{account.get('name', 'TRAINER')} (ID {trainer_id}) LEVELED UP TO LV{new_level}!")

            db["accounts"][trainer_id] = account
            save_db()

            next_lvl_xp = calculate_xp_for_level(new_level + 1) if new_level < 100 else current_xp
            cur_lvl_base_xp = calculate_xp_for_level(new_level)

            self._send_json({
                "success": True,
                "level": new_level,
                "xp": current_xp,
                "leveledUp": leveled_up,
                "currentLevelBaseXp": cur_lvl_base_xp,
                "nextLevelXp": next_lvl_xp
            })

        # 4. MMO Chat Message Relay
        elif action == "send_chat":
            trainer_id = str(req.get("trainerId", "0"))
            name = req.get("name", "TRAINER")
            text = req.get("text", "").strip()
            scope = req.get("scope", "global")

            if trainer_id in db.get("banned_trainers", {}):
                self._send_json({"success": False, "error": "BANNED"}, status=403)
                return

            if len(text) == 0:
                self._send_json({"success": False, "error": "EMPTY_MESSAGE"}, status=400)
                return

            if len(text) > 80:
                text = text[:80]

            msg_entry = {
                "id": len(db.get("chat", [])) + 1,
                "trainerId": trainer_id,
                "name": name,
                "text": text,
                "scope": scope,
                "time": now
            }

            db.setdefault("chat", []).append(msg_entry)
            if len(db["chat"]) > 100:
                db["chat"] = db["chat"][-100:]

            self._send_json({
                "success": True,
                "message": msg_entry
            })

        # 5. Direct Network Challenge Endpoint (PVP Lockstep / Trade / Log Trade)
        elif action == "send_challenge":
            target_id = str(req.get("targetId"))
            from_id = str(req.get("fromId"))
            from_name = req.get("fromName", "TRAINER")
            challenge_type = req.get("challengeType", "PVP")
            room_id = req.get("roomId") or f"ROOM_{min(from_id, target_id)}_{max(from_id, target_id)}"

            db["pending_challenges"][target_id] = {
                "fromId": from_id,
                "fromName": from_name,
                "type": challenge_type,
                "party": req.get("party"),
                "seed": req.get("seed"),
                "roomId": room_id,
                "timestamp": now
            }

            self._send_json({
                "success": True,
                "roomId": room_id,
                "message": f"Challenge '{challenge_type}' sent to Trainer ID {target_id}"
            })

        elif action == "clear_challenge":
            trainer_id = str(req.get("trainerId"))
            db["pending_challenges"].pop(trainer_id, None)
            self._send_json({"success": True})

        # 6. Dedicated Lockstep Multi-Room Battle Messaging API
        elif action == "send_battle_msg":
            room_id = str(req.get("roomId"))
            target_id = str(req.get("targetId"))
            msg = req.get("msg")

            if room_id not in db["battle_rooms"]:
                db["battle_rooms"][room_id] = {}
            if target_id not in db["battle_rooms"][room_id]:
                db["battle_rooms"][room_id][target_id] = []

            db["battle_rooms"][room_id][target_id].append(msg)
            self._send_json({"success": True})

        elif action == "poll_battle_msgs":
            room_id = str(req.get("roomId"))
            my_id = str(req.get("myId"))

            pending_msgs = []
            if room_id in db["battle_rooms"] and my_id in db["battle_rooms"][room_id]:
                pending_msgs = db["battle_rooms"][room_id].pop(my_id, [])

            self._send_json({
                "success": True,
                "msgs": pending_msgs
            })

        elif action == "clear_battle_room":
            room_id = str(req.get("roomId"))
            db["battle_rooms"].pop(room_id, None)
            self._send_json({"success": True})

        elif action == "log_trade_receipt":
            text = req.get("text", "LINK TRADE COMPLETED")
            add_receipt(text)
            save_db()
            self._send_json({"success": True})

        elif action == "update_profile":
            trainer_id = str(req.get("trainerId"))
            profile = db["profiles"].get(trainer_id, {
                "trainerId": trainer_id,
                "name": req.get("name", "TRAINER"),
                "title": "POKéMON TRAINER",
                "badges": 0,
                "pokedexCount": 0,
                "gtsTrades": 0,
                "pvpWins": 0,
                "favoriteMon": "PIKACHU",
                "timestamp": now
            })

            profile["name"] = req.get("name", profile.get("name"))
            if "title" in req: profile["title"] = req["title"]
            if "badges" in req: profile["badges"] = req["badges"]
            if "pokedexCount" in req: profile["pokedexCount"] = req["pokedexCount"]
            if "blackouts" in req: profile["blackouts"] = int(req["blackouts"])
            if "blackoutCount" in req: profile["blackouts"] = int(req["blackoutCount"])
            if "gtsTrades" in req: profile["gtsTrades"] = (profile.get("gtsTrades", 0) + req["gtsTrades"])
            if "pvpWins" in req: profile["pvpWins"] = (profile.get("pvpWins", 0) + req["pvpWins"])
            if "favoriteMon" in req: profile["favoriteMon"] = req["favoriteMon"]
            profile["timestamp"] = now

            # Also update account record if present
            if trainer_id in db.get("accounts", {}):
                if "blackouts" in req: db["accounts"][trainer_id]["blackoutCount"] = int(req["blackouts"])
                if "blackoutCount" in req: db["accounts"][trainer_id]["blackoutCount"] = int(req["blackoutCount"])
                if "badges" in req: db["accounts"][trainer_id]["badges"] = req["badges"]
                if "pokedexCount" in req: db["accounts"][trainer_id]["pokedexCount"] = req["pokedexCount"]

            db["profiles"][trainer_id] = profile
            save_db()

            self._send_json({"success": True, "profile": profile})

        elif action == "deposit":
            trainer_id = str(req.get("trainerId"))
            trainer_name = censor_profanity(req.get("trainerName", "TRAINER"))
            offered_mon = req.get("offeredMon", {})
            if offered_mon and "nickname" in offered_mon:
                offered_mon["nickname"] = censor_profanity(offered_mon["nickname"])
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
                "timestamp": now
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
                self._send_json({"success": False, "error": "Listing not found"}, status=404)
                return

            listing = db["listings"].pop(list_id)
            seller_id = str(listing["trainerId"])
            seller_name = listing.get("trainerName", "TRAINER")
            offered_mon = listing["offeredMon"]

            db["user_counts"][seller_id] = max(0, db["user_counts"].get(seller_id, 1) - 1)

            if seller_id not in db["claim_boxes"]:
                db["claim_boxes"][seller_id] = []

            db["claim_boxes"][seller_id].append({
                "mon": sent_mon,
                "fromName": buyer_name,
                "fromId": buyer_id,
                "originalOffered": offered_mon.get("nickname") or offered_mon.get("species"),
                "timestamp": now
            })

            off_name = offered_mon.get("nickname") or offered_mon.get("species")
            sent_name = sent_mon.get("nickname") or sent_mon.get("species")
            add_receipt(f"{buyer_name} TRADED {sent_name} TO {seller_name} FOR {off_name}")
            save_db()

            self._send_json({
                "success": True,
                "receivedMon": offered_mon
            })

        elif action == "withdraw":
            list_id = req.get("listingId")
            trainer_id = str(req.get("trainerId"))

            if list_id in db["listings"]:
                listing = db["listings"].pop(list_id)
                db["user_counts"][trainer_id] = max(0, db["user_counts"].get(trainer_id, 1) - 1)
                off_name = listing["offeredMon"].get("nickname") or listing["offeredMon"].get("species")
                add_receipt(f"{listing.get('trainerName', 'TRAINER')} WITHDREW {off_name}")
                save_db()
                self._send_json({"success": True})
            else:
                self._send_json({"success": False, "error": "Listing not found"}, status=404)

        elif action == "claim":
            trainer_id = str(req.get("trainerId"))
            idx = int(req.get("index", 0))

            if trainer_id in db["claim_boxes"] and idx < len(db["claim_boxes"][trainer_id]):
                claimed = db["claim_boxes"][trainer_id].pop(idx)
                c_name = claimed["mon"].get("nickname") or claimed["mon"].get("species")
                add_receipt(f"TRAINER {trainer_id} CLAIMED {c_name}")
                save_db()
                self._send_json({"success": True, "claimed": claimed})
            else:
                self._send_json({"success": False, "error": "Claim not found"}, status=404)

        # 7. Host Admin Anti-Cheat & Player Management Actions
        elif action == "admin_action":
            admin_op = req.get("adminOp")
            target_tid = str(req.get("targetId", ""))

            if admin_op == "list_players":
                accounts_summary = []
                for tid, acc in db.get("accounts", {}).items():
                    flags = audit_account_integrity(acc)
                    accounts_summary.append({
                        "trainerId": tid,
                        "name": acc.get("name"),
                        "level": acc.get("level", 1),
                        "xp": acc.get("xp", 0),
                        "spriteId": acc.get("spriteId"),
                        "pvpWins": acc.get("pvpWins", 0),
                        "pvpLosses": acc.get("pvpLosses", 0),
                        "badges": acc.get("badges", 0),
                        "pokedexCount": acc.get("pokedexCount", 0),
                        "isBanned": acc.get("isBanned", False),
                        "antiCheatFlags": flags,
                        "lastSeen": acc.get("lastSeen", 0)
                    })
                self._send_json({"success": True, "players": accounts_summary})

            elif admin_op == "ban_player":
                if target_tid in db.get("accounts", {}):
                    db["accounts"][target_tid]["isBanned"] = True
                    db.setdefault("banned_trainers", {})[target_tid] = {
                        "reason": req.get("reason", "Admin Ban"),
                        "bannedAt": now
                    }
                    db["active_players"].pop(target_tid, None)
                    save_db()
                    self._send_json({"success": True, "message": f"Player {target_tid} banned."})
                else:
                    self._send_json({"success": False, "error": "Player not found"}, status=404)

            elif admin_op == "unban_player":
                if target_tid in db.get("accounts", {}):
                    db["accounts"][target_tid]["isBanned"] = False
                db.get("banned_trainers", {}).pop(target_tid, None)
                save_db()
                self._send_json({"success": True, "message": f"Player {target_tid} unbanned."})

            elif admin_op == "remove_player":
                db.get("accounts", {}).pop(target_tid, None)
                db.get("profiles", {}).pop(target_tid, None)
                db.get("active_players", {}).pop(target_tid, None)
                db.get("claim_boxes", {}).pop(target_tid, None)
                db.get("user_counts", {}).pop(target_tid, None)
                save_db()
                self._send_json({"success": True, "message": f"Player {target_tid} deleted from server."})

            elif admin_op == "audit":
                audit_report = {}
                for tid, acc in db.get("accounts", {}).items():
                    flags = audit_account_integrity(acc)
                    if flags:
                        audit_report[tid] = {
                            "name": acc.get("name"),
                            "level": acc.get("level"),
                            "xp": acc.get("xp"),
                            "flags": flags
                        }
                self._send_json({"success": True, "flagged_players": audit_report})
            else:
                self._send_json({"error": "Unknown admin action"}, status=400)
        
        # 9. Co-op Multiplayer Party System
        elif action == "party_create":
            trainer_id = str(req.get("trainerId", "0"))
            trainer_name = censor_profanity(req.get("name", "TRAINER"))
            level = int(req.get("level", 1))
            map_id = req.get("map", "PALLET_TOWN")
            x = req.get("x", 5)
            y = req.get("y", 5)
            sprite_id = req.get("spriteId", "SPRITE_RED")
            
            # Leave existing party if in one
            old_p_id = db["player_parties"].get(trainer_id)
            if old_p_id and old_p_id in db["parties"]:
                db["parties"][old_p_id]["members"].pop(trainer_id, None)
                if len(db["parties"][old_p_id]["members"]) == 0:
                    db["parties"].pop(old_p_id, None)

            party_id = f"party_{int(time.time())}_{trainer_id}"
            db["parties"][party_id] = {
                "id": party_id,
                "leaderId": trainer_id,
                "leaderName": trainer_name,
                "created": int(time.time()),
                "members": {
                    trainer_id: {
                        "trainerId": trainer_id,
                        "name": trainer_name,
                        "level": level,
                        "map": map_id,
                        "x": x,
                        "y": y,
                        "spriteId": sprite_id,
                        "lastSeen": int(time.time())
                    }
                }
            }
            db["player_parties"][trainer_id] = party_id
            self._send_json({"success": True, "partyId": party_id, "party": db["parties"][party_id]})

        elif action == "party_invite":
            trainer_id = str(req.get("trainerId", "0"))
            trainer_name = censor_profanity(req.get("name", "TRAINER"))
            target_id = str(req.get("targetId", ""))
            
            party_id = db["player_parties"].get(trainer_id)
            if not party_id or party_id not in db["parties"]:
                # Auto-create party if not in one
                party_id = f"party_{int(time.time())}_{trainer_id}"
                db["parties"][party_id] = {
                    "id": party_id,
                    "leaderId": trainer_id,
                    "leaderName": trainer_name,
                    "created": int(time.time()),
                    "members": {
                        trainer_id: {
                            "trainerId": trainer_id,
                            "name": trainer_name,
                            "level": int(req.get("level", 1)),
                            "map": req.get("map", "PALLET_TOWN"),
                            "x": req.get("x", 5),
                            "y": req.get("y", 5),
                            "spriteId": req.get("spriteId", "SPRITE_RED"),
                            "lastSeen": int(time.time())
                        }
                    }
                }
                db["player_parties"][trainer_id] = party_id

            if len(db["parties"][party_id]["members"]) >= 4:
                self._send_json({"success": False, "error": "PARTY IS FULL (MAX 4)!"}, status=400)
                return

            db["pending_party_invites"][target_id] = {
                "fromId": trainer_id,
                "fromName": trainer_name,
                "partyId": party_id,
                "timestamp": int(time.time())
            }
            self._send_json({"success": True, "message": f"INVITED TO PARTY!"})

        elif action == "party_accept":
            trainer_id = str(req.get("trainerId", "0"))
            trainer_name = censor_profanity(req.get("name", "TRAINER"))
            invite = db["pending_party_invites"].pop(trainer_id, None)
            if not invite or (int(time.time()) - invite.get("timestamp", 0) > 30):
                self._send_json({"success": False, "error": "INVITE EXPIRED!"}, status=400)
                return
            
            party_id = invite["partyId"]
            if party_id not in db["parties"] or len(db["parties"][party_id]["members"]) >= 4:
                self._send_json({"success": False, "error": "PARTY NO LONGER AVAILABLE!"}, status=400)
                return

            db["parties"][party_id]["members"][trainer_id] = {
                "trainerId": trainer_id,
                "name": trainer_name,
                "level": int(req.get("level", 1)),
                "map": req.get("map", "PALLET_TOWN"),
                "x": req.get("x", 5),
                "y": req.get("y", 5),
                "spriteId": req.get("spriteId", "SPRITE_RED"),
                "lastSeen": int(time.time())
            }
            db["player_parties"][trainer_id] = party_id
            self._send_json({"success": True, "partyId": party_id, "party": db["parties"][party_id]})

        elif action == "party_decline":
            trainer_id = str(req.get("trainerId", "0"))
            db["pending_party_invites"].pop(trainer_id, None)
            self._send_json({"success": True})

        elif action == "party_leave":
            trainer_id = str(req.get("trainerId", "0"))
            party_id = db["player_parties"].pop(trainer_id, None)
            if party_id and party_id in db["parties"]:
                db["parties"][party_id]["members"].pop(trainer_id, None)
                if len(db["parties"][party_id]["members"]) == 0:
                    db["parties"].pop(party_id, None)
                elif db["parties"][party_id]["leaderId"] == trainer_id:
                    # Pass leadership to next member
                    next_leader = next(iter(db["parties"][party_id]["members"].keys()))
                    db["parties"][party_id]["leaderId"] = next_leader
                    db["parties"][party_id]["leaderName"] = db["parties"][party_id]["members"][next_leader]["name"]
            self._send_json({"success": True})

        elif action == "party_info":
            trainer_id = str(req.get("trainerId", "0"))
            party_id = db["player_parties"].get(trainer_id)
            if not party_id or party_id not in db["parties"]:
                self._send_json({"success": True, "party": None})
                return
            self._send_json({"success": True, "party": db["parties"][party_id]})

        elif action == "party_share_xp":
            trainer_id = str(req.get("trainerId", "0"))
            trainer_name = censor_profanity(req.get("name", "TRAINER"))
            xp_amount = int(req.get("xp", 0))
            reason = req.get("reason", "co-op")
            party_id = db["player_parties"].get(trainer_id)
            if party_id and party_id in db["parties"] and xp_amount > 0:
                for member_id in db["parties"][party_id]["members"]:
                    if member_id != trainer_id:
                        if member_id not in db["party_xp_events"]:
                            db["party_xp_events"][member_id] = []
                        db["party_xp_events"][member_id].append({
                            "fromName": trainer_name,
                            "xp": xp_amount,
                            "reason": reason,
                            "timestamp": int(time.time())
                        })
            self._send_json({"success": True})

        elif action == "party_warp_target":
            target_id = str(req.get("targetId", "0"))
            player_data = db["active_players"].get(target_id)
            if player_data:
                self._send_json({
                    "success": True,
                    "map": player_data.get("map", "PALLET_TOWN"),
                    "x": player_data.get("x", 5),
                    "y": player_data.get("y", 5)
                })
            else:
                self._send_json({"success": False, "error": "MEMBER NOT ACTIVE ON MAP!"}, status=404)

        # 8. Multi-Player Online Texas Hold'em Engine
        elif action in ("holdem_tables", "get_holdem_tables"):
            tables_summary = []
            for t_id, tab in holdem_tables.items():
                tables_summary.append({
                    "id": tab.table_id,
                    "name": tab.name,
                    "minBet": tab.min_bet,
                    "buyIn": tab.min_bet * 10,
                    "playerCount": len(tab.players),
                    "maxSeats": tab.max_seats,
                    "state": tab.state,
                    "pot": tab.pot
                })
            self._send_json({"success": True, "tables": tables_summary})

        elif action == "holdem_join":
            t_id = req.get("tableId", "table_50")
            trainer_id = str(req.get("trainerId", "0"))
            trainer_name = censor_profanity(req.get("name", "TRAINER"))
            buy_in = int(req.get("buyIn", 500))
            if t_id not in holdem_tables:
                self._send_json({"success": False, "error": "Table not found"}, status=404)
                return
            tab = holdem_tables[t_id]
            ok, msg = tab.join_player(trainer_id, trainer_name, buy_in)
            if ok:
                st = tab.get_client_state(trainer_id)
                self._send_json({"success": True, "state": st})
            else:
                self._send_json({"success": False, "error": msg}, status=400)

        elif action == "holdem_leave":
            t_id = req.get("tableId", "table_50")
            trainer_id = str(req.get("trainerId", "0"))
            if t_id in holdem_tables:
                refund = holdem_tables[t_id].leave_player(trainer_id)
                self._send_json({"success": True, "refund": refund})
            else:
                self._send_json({"success": True, "refund": 0})

        elif action == "holdem_state":
            t_id = req.get("tableId", "table_50")
            trainer_id = str(req.get("trainerId", "0"))
            if t_id in holdem_tables:
                st = holdem_tables[t_id].get_client_state(trainer_id)
                self._send_json({"success": True, "state": st})
            else:
                self._send_json({"success": False, "error": "Table not found"}, status=404)

        elif action == "holdem_action":
            t_id = req.get("tableId", "table_50")
            trainer_id = str(req.get("trainerId", "0"))
            act_type = req.get("actionType", "check")
            amount = int(req.get("amount", 0))
            if t_id in holdem_tables:
                tab = holdem_tables[t_id]
                ok, msg = tab.process_action(trainer_id, act_type, amount)
                st = tab.get_client_state(trainer_id)
                self._send_json({"success": ok, "message": msg, "state": st})
            else:
                self._send_json({"success": False, "error": "Table not found"}, status=404)

        else:
            self._send_json({"error": "Unknown action"}, status=400)

if __name__ == "__main__":
    load_db()
    server = ThreadedTCPServer(("0.0.0.0", PORT), GTSHandler)
    print(f"============================================================")
    print(f" Gen1Online 24/7 GTS & MMO Server with Leveling & Anti-Cheat")
    print(f" Port: {PORT} | Cloudflare Ready: YES | Backup: players_backup.json")
    print(f" Active Accounts: {len(db.get('accounts', {}))}")
    print(f"============================================================")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        save_db()
        print("\n[GTS Cloud Server] Server shut down cleanly. Backup saved.")