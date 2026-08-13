import unittest
import json
import os
import sys

# Import gts_server
sys.path.insert(0, r'e:/gen1recomp-dev/mods/gen1online-gamecorner')
import gts_server

class TestGoldServerWipe(unittest.TestCase):
    def setUp(self):
        # Fresh in-memory DB
        gts_server.db["accounts"] = {}
        gts_server.db["profiles"] = {}
        gts_server.db["listings"] = {}
        gts_server.db["claim_boxes"] = {}
        gts_server.db["user_counts"] = {}
        gts_server.db["history"] = []
        gts_server.db["chat"] = []
        gts_server.db["battle_log"] = []
        gts_server.db["quest_log"] = []

    def test_name_availability_after_wipe(self):
        # All names should be available
        test_names = ["RED", "GOLD", "ASH", "AHMED", "LEAN", "ALANO", "BESTIE", "CUZZO", "ZVINCE"]
        for name in test_names:
            name_clean = name.upper()
            found = False
            for acc in gts_server.db.get("accounts", {}).values():
                if acc.get("name", "").upper() == name_clean:
                    found = True
                    break
            self.assertFalse(found, f"Name {name} should be available after wipe!")

    def test_unique_trainer_id_generation(self):
        tid1 = gts_server.generate_unique_trainer_id()
        self.assertTrue(tid1.isdigit() and len(tid1) == 6)
        gts_server.db["accounts"][tid1] = {"name": "GOLD", "level": 1}
        tid2 = gts_server.generate_unique_trainer_id()
        self.assertNotEqual(tid1, tid2)

    def test_database_files_exist_and_valid(self):
        db_path = r'e:/gen1recomp-dev/mods/gen1online-gamecorner/gts_database.json'
        with open(db_path, 'r', encoding='utf-8') as f:
            data = json.load(f)
            self.assertIn("accounts", data)
            self.assertEqual(len(data["accounts"]), 0)

if __name__ == '__main__':
    unittest.main()
