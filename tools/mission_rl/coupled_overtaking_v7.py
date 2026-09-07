"""Both encounter vessels act through independently trained SAC networks."""
from pathlib import Path
from .overtaking_full_mission_v5 import FullMissionOvertakingEnv
from .traffic_lane import NumpyActor,observation
from .environment import CONFIG
from .plant import ROOT

TRAFFIC_PATH='reports/artifacts/mission_rl_v1/traffic_lane_attempt_02/actor.json'
class CoupledOvertakingEnv(FullMissionOvertakingEnv):
 def __init__(self,*args,**kwargs):
  config=kwargs.get('config') or {};self.traffic_actor=NumpyActor(ROOT/config.get('traffic_policy_path',TRAFFIC_PATH))
  super().__init__(*args,**kwargs)
 def reset(self,*,seed=None,options=None):
  obs,info=super().reset(seed=seed,options=options)
  self.traffic_forcing=self.forcing.copy() # Godot applies bank forces to every vessel.
  self.traffic_max_xte=0.;self.traffic_collisions=0
  return self.observation(),info
 def step(self,action):
  self.traffic_actions=[self.traffic_actor.command(observation(p,self.traffic_forcing)) for p in self.traffic]
  obs,reward,t,u,info=super().step(action)
  for p in self.traffic:
   self.traffic_max_xte=max(self.traffic_max_xte,abs(float(p.state[0])-18))
   self.traffic_collisions+=int(self.clearances(p.state[None,:2])[0]<=0)
  # A grounded target is never a successful overtaking exercise.
  if self.traffic_collisions or self.traffic_max_xte>7:
   reward-=1000;self.reward_sum-=1000;t=True;u=False
   info=self.result(False);info['episode']={'r':self.reward_sum,'l':self.steps}
  return obs,float(reward),t,u,info
 def gate(self):
  gates=super().gate();gates['traffic_lane_valid']=getattr(self,'traffic_max_xte',0)<7 and getattr(self,'traffic_collisions',0)==0
  return gates
 def result(self,success=False):
  return {**super().result(success),'traffic_max_cross_track_m':getattr(self,'traffic_max_xte',0),
   'traffic_collisions':getattr(self,'traffic_collisions',0),'traffic_action_source':'SAC_neural_network_direct'}

def main():
 import train_mission_rl as trainer
 from train_mission_rl import sha
 import json
 receipt=json.loads((ROOT/TRAFFIC_PATH).read_text())
 if not receipt.get('admitted_numeric'):raise RuntimeError('Traffic SAC has not passed independent validation')
 trainer.MissionEnv=CoupledOvertakingEnv
 trainer.CONFIG={**CONFIG,'reward_profile':'two_vessel_direct_sac_v7','action_high':[1.,.65],
  'restart_exploration':True,'traffic_policy_path':TRAFFIC_PATH,'traffic_policy_sha256':sha(ROOT/TRAFFIC_PATH)}
 trainer.main()
if __name__=='__main__':main()
