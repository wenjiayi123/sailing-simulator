"""Fine-tune the existing route skill using near-policy replay in the new encounter."""
from .coupled_overtaking_v7 import CoupledOvertakingEnv,TRAFFIC_PATH
from .environment import CONFIG
from .plant import ROOT
def main():
 import train_mission_rl as trainer
 from train_mission_rl import sha
 import json
 if not json.loads((ROOT/TRAFFIC_PATH).read_text()).get('admitted_numeric'):
  raise RuntimeError('Unqualified traffic policy')
 trainer.MissionEnv=CoupledOvertakingEnv
 trainer.CONFIG={**CONFIG,'reward_profile':'two_vessel_finetune_v8','action_high':[1.,.65],
  'restart_exploration':False,'policy_replay_warmup_steps':2000,'fine_tune_learning_rate':1e-4,
  'traffic_policy_path':TRAFFIC_PATH,'traffic_policy_sha256':sha(ROOT/TRAFFIC_PATH)}
 trainer.main()
if __name__=='__main__':main()
