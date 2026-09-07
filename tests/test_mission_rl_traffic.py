"""Traffic network parity and non-degenerate coupled encounter acceptance."""
import sys,unittest,json
from pathlib import Path
import numpy as np,torch
from stable_baselines3 import SAC
ROOT=Path(__file__).resolve().parents[1];sys.path.insert(0,str(ROOT/'tools'))
from mission_rl.traffic_lane import NumpyActor,observation,TrafficLaneEnv,CONFIG
from mission_rl.coupled_overtaking_v7 import CoupledOvertakingEnv,TRAFFIC_PATH
from mission_rl.coupled_curriculum_v9 import CoherentCurriculumEnv
from mission_rl.separation_curriculum_v10 import PassingClearanceCurriculumEnv

class TrafficRLTests(unittest.TestCase):
 def test_numpy_traffic_actor_matches_trained_sac(self):
  torch.set_num_threads(1)
  model=SAC.load(ROOT/'reports/artifacts/mission_rl_v1/traffic_lane_attempt_02/sac_20000.zip',device='cpu')
  actor=NumpyActor(ROOT/TRAFFIC_PATH);env=TrafficLaneEnv('validation')
  for seed in range(10):
   obs,_=env.reset(seed=seed);raw,_=model.predict(obs,deterministic=True)
   lo=np.array(CONFIG['action_low']);hi=np.array(CONFIG['action_high'])
   np.testing.assert_allclose(actor.command(obs),lo+(raw+1)*.5*(hi-lo),atol=1e-6,rtol=0)
 def test_coupled_target_retains_bank_physics_and_cannot_ground_to_win(self):
  env=CoupledOvertakingEnv('narrow_channel_overtaking','validation',config={'traffic_policy_path':TRAFFIC_PATH})
  np.testing.assert_array_equal(env.traffic_forcing,env.forcing)
  env.route_complete=True;env.passed_ahead=True;env.traffic_collisions=1
  self.assertFalse(env.gate()['traffic_lane_valid'])
 def test_prefix_curriculum_preserves_both_vessels_physical_clock(self):
  env=CoherentCurriculumEnv('narrow_channel_overtaking','train',config={'traffic_policy_path':TRAFFIC_PATH,'curriculum_probability':0.,'action_high':[1.,.65]})
  for seed in range(10):
   env.reset(seed=seed)
   if env.curriculum:break
  self.assertTrue(env.curriculum)
  self.assertAlmostEqual(env.plant.state[9],env.steps*.5,places=7)
  self.assertAlmostEqual(env.traffic[0].state[9],env.plant.state[9],places=7)
  self.assertEqual(env.collisions,0)
  evaluation=CoherentCurriculumEnv('narrow_channel_overtaking','validation',config={'traffic_policy_path':TRAFFIC_PATH})
  evaluation.reset(seed=10001)
  self.assertFalse(evaluation.curriculum);self.assertEqual(evaluation.steps,0);self.assertEqual(evaluation.waypoint,0)
 def test_training_clearance_curriculum_cannot_relax_held_out_gate(self):
  config={'traffic_policy_path':TRAFFIC_PATH,'curriculum_probability':0.}
  training=PassingClearanceCurriculumEnv('narrow_channel_overtaking','train',config=config)
  self.assertEqual(training.evaluation['minimum_passing_distance_m'],9.)
  training.training_steps_seen=60001;training.reset(seed=123)
  self.assertEqual(training.evaluation['minimum_passing_distance_m'],20.)
  for split in ['validation','test']:
   env=PassingClearanceCurriculumEnv('narrow_channel_overtaking',split,config=config)
   self.assertEqual(env.evaluation['minimum_passing_distance_m'],20.)
   self.assertEqual(env.waypoint,0);self.assertEqual(env.steps,0)
  env.traffic_collisions=0;env.traffic_max_xte=8
  self.assertFalse(env.gate()['traffic_lane_valid'])
if __name__=='__main__':unittest.main()
