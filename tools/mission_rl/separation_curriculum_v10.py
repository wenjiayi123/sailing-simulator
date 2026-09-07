"""Train passing clearance progressively; every held-out task still requires 20 m.

Collision geometry, target traffic dynamics, all route points and held-out
acceptance are unchanged. This is a training curriculum, never a relaxed test.
"""
from .coupled_overtaking_v7 import CoupledOvertakingEnv,TRAFFIC_PATH
from .environment import CONFIG
from .plant import ROOT

class PassingClearanceCurriculumEnv(CoupledOvertakingEnv):
 def __init__(self,*args,**kwargs):
  self.training_steps_seen=0
  super().__init__(*args,**kwargs)
 def reset(self,*,seed=None,options=None):
  if hasattr(self,'evaluation'):
   if self.split=='train':
    self.evaluation['minimum_passing_distance_m']=9. if self.training_steps_seen<20000 else (13. if self.training_steps_seen<40000 else (17. if self.training_steps_seen<60000 else 20.))
   else:self.evaluation['minimum_passing_distance_m']=20.
  return super().reset(seed=seed,options=options)
 def step(self,action):
  if self.split=='train':self.training_steps_seen+=1
  return super().step(action)
 def result(self,success=False):
  return {**super().result(success),'training_clearance_curriculum':self.split=='train','required_passing_distance_m':self.evaluation['minimum_passing_distance_m']}

def main():
 import train_mission_rl as trainer
 from train_mission_rl import sha
 trainer.MissionEnv=PassingClearanceCurriculumEnv
 trainer.CONFIG={**CONFIG,'reward_profile':'training_clearance_curriculum_v10','action_high':[1.,.65],
  'restart_exploration':False,'policy_replay_warmup_steps':2000,'fine_tune_learning_rate':1e-4,
  'training_clearance_schedule':[[0,9],[20000,13],[40000,17],[60000,20]],'held_out_minimum_passing_distance_m':20,
  'traffic_policy_path':TRAFFIC_PATH,'traffic_policy_sha256':sha(ROOT/TRAFFIC_PATH)}
 trainer.main()
if __name__=='__main__':main()
