"""Export must preserve the action range used in numerical evaluation."""
import json
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
import torch
from train_mission_rl import export_actor


class MissionActorExportTests(unittest.TestCase):
    def test_overtaking_checkpoint_keeps_full_throttle_range(self):
        actor = SimpleNamespace(latent_pi=torch.nn.Sequential(torch.nn.Linear(40, 2), torch.nn.ReLU()), mu=torch.nn.Linear(2, 2))
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'actor.json'
            export_actor(SimpleNamespace(actor=actor), path,
                         {'config': {'action_low': [-.6, -.65], 'action_high': [1., .65]}})
            exported = json.loads(path.read_text())
        self.assertEqual(exported['action_high'], [1., .65])
        self.assertEqual(exported['action_low'], [-.6, -.65])


if __name__ == '__main__':
    unittest.main()
