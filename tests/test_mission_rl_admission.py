"""Reject stale execution evidence and altered model/source artifacts."""
import copy,sys,unittest
from pathlib import Path
from unittest.mock import patch
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tools'))
import audit_mission_rl as audit

class AdmissionTests(unittest.TestCase):
 def test_native_receipt_is_bound_to_actual_execution_sources(self):
  p=ROOT/'reports/artifacts/mission_rl_v1/berthing_attempt_02/native_validation_05.json'
  native=audit.read(p)
  self.assertTrue(audit.native_sources_match(native))
  altered=copy.deepcopy(native);altered['native_runtime_sources']['player.gd']='0'*64
  self.assertFalse(audit.native_sources_match(altered))
  del altered['native_runtime_sources']
  self.assertFalse(audit.native_sources_match(altered))
 def test_original_training_source_archive_is_required(self):
  receipt=audit.read(ROOT/'reports/artifacts/mission_rl_v1/berthing_attempt_02/receipt.json')
  self.assertTrue(audit.source_ok(receipt))
  changed=copy.deepcopy(receipt);changed['source_hashes']['tools/mission_rl/plant.c']='0'*64
  self.assertFalse(audit.source_ok(changed))
 def test_frozen_model_tampering_blocks_normal_admission(self):
  p=ROOT/'reports/artifacts/mission_rl_v1/berthing_attempt_02/receipt.json'
  real_read=audit.read
  def tampered(path):
   value=real_read(path)
   if Path(path)==p:value['frozen_model_sha256']='0'*64
   return value
  with patch.object(audit,'read',side_effect=tampered):
   entry=audit.candidate_entry(p)
  self.assertFalse(entry['live_switch_admitted'])
 def test_traffic_actor_requires_its_own_held_out_evidence(self):
  path='reports/artifacts/mission_rl_v1/traffic_lane_attempt_02/actor.json'
  config={'traffic_policy_path':path,'traffic_policy_sha256':audit.sha(ROOT/path)}
  self.assertTrue(audit.traffic_policy_qualified(config))
  config['traffic_policy_sha256']='0'*64
  self.assertFalse(audit.traffic_policy_qualified(config))
if __name__=='__main__':unittest.main()
