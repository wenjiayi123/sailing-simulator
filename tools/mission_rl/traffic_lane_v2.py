"""Bounded positive task reward removes incentive to terminate lane training early."""
import math
from .traffic_lane import TrafficLaneEnv

class StableTrafficLaneEnv(TrafficLaneEnv):
 def step(self,action):
  previous=self.reward_sum
  obs,_,terminated,truncated,info=super().step(action)
  s=self.plant.state
  quality=math.exp(-((s[0]-18)/4)**2)*math.exp(-(s[5]/.2)**2)*math.exp(-((s[2]-3)/1.5)**2)
  reward=quality-.025
  if terminated:reward-=100
  self.reward_sum=previous+reward
  if terminated or truncated:
   info=self.result();info['episode']={'r':self.reward_sum,'l':self.steps}
  return obs,float(reward),terminated,truncated,info
