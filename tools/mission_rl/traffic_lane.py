"""Direct-action SAC for a slow traffic vessel holding its assigned channel lane."""
import math,json
import gymnasium as gym
from gymnasium import spaces
import numpy as np
from .environment import MissionEnv

CONFIG={'decision_frames':30,'target_x':18.,'target_speed_mps':3.,'action_low':[0.,-.4],'action_high':[.35,.4]}
def observation(plant,force):
 s=plant.state
 return np.clip(np.array([(s[0]-18)/30,math.sin(s[5]),math.cos(s[5]),s[2]/5,s[3]/2,s[4]/.5,s[6],s[7],s[8]/math.radians(18),force[0]],dtype=np.float32),-1,1)

class TrafficLaneEnv(gym.Env):
 def __init__(self,split='train'):
  self.base=MissionEnv('narrow_channel_overtaking','validation');self.plant=self.base.plant;self.split=split
  self.action_space=spaces.Box(-1,1,shape=(2,),dtype=np.float32);self.observation_space=spaces.Box(-1,1,shape=(10,),dtype=np.float32)
  self.reset()
 def reset(self,*,seed=None,options=None):
  super().reset(seed=seed);nominal=bool((options or {}).get('nominal'))
  self.base.reset(seed=seed,options={'nominal':nominal});self.force=self.base.forcing
  x=18. if nominal else float(self.np_random.uniform(14,22));h=0. if nominal else float(self.np_random.uniform(-.12,.12))
  speed=0. if self.split!='train' else float(self.np_random.uniform(0,3.3))
  self.plant.reset(x,-72,h,speed);self.steps=0;self.reward_sum=0.;self.max_xte=0.;self.max_h=0.;self.speed_errors=[];self.collisions=0
  return observation(self.plant,self.force),{}
 def step(self,action):
  lo=np.array(CONFIG['action_low']);hi=np.array(CONFIG['action_high']);command=lo+(np.clip(action,-1,1)+1)*.5*(hi-lo)
  samples=self.plant.advance(command,self.force,30);s=self.plant.state;self.steps+=1
  xte=abs(s[0]-18);herr=abs(s[5]);speederr=abs(s[2]-3.)
  self.max_xte=max(self.max_xte,xte);self.max_h=max(self.max_h,math.degrees(herr))
  if self.steps>20:self.speed_errors.append(speederr)
  self.collisions+=int(self.base.clearances(samples).min()<=0)
  reward=1.-.15*xte*xte-4.*herr*herr-.8*speederr*speederr-.03*abs(action[1])
  failed=self.collisions>0 or xte>18 or herr>1.
  if failed:reward-=100
  terminated=failed;truncated=self.steps>=180 and not failed
  self.reward_sum+=reward
  info={}
  if terminated or truncated:
   info=self.result();info['episode']={'r':self.reward_sum,'l':self.steps}
  return observation(self.plant,self.force),float(reward),terminated,truncated,info
 def result(self):
  mean=float(np.mean(self.speed_errors)) if self.speed_errors else 99.
  return {'success':self.steps==180 and self.collisions==0 and self.max_xte<7 and self.max_h<15 and mean<.5,
    'steps':self.steps,'max_cross_track_m':self.max_xte,'max_heading_error_deg':self.max_h,'mean_speed_error_after_10s_mps':mean,
    'collisions':self.collisions,'reward':self.reward_sum,'action_source':'traffic_SAC_direct','controller_fallback_steps':0}

class NumpyActor:
 def __init__(self,path):
  data=json.load(open(path));self.layers=[(np.array(l['weight']),np.array(l['bias']),l['activation']) for l in data['layers']]
  self.lo=np.array(data['action_low']);self.hi=np.array(data['action_high'])
 def command(self,obs):
  v=obs
  for w,b,activation in self.layers:
   v=w@v+b;v=np.maximum(v,0) if activation=='relu' else np.tanh(v)
  return self.lo+(v+1)*.5*(self.hi-self.lo)
