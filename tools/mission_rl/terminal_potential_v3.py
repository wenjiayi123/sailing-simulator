"""RL reward uses distance through navigable water, without generating actions.

The cost field is a training-only potential. It never supplies a waypoint,
heading, steering command or demonstration to either SAC actor or runtime.
"""
import heapq,math
import numpy as np
from .terminal_curriculum_v2 import GoalBalancedTerminalEnv

class NavigableTerminalEnv(GoalBalancedTerminalEnv):
    _fields={}
    def __init__(self,*args,**kwargs):
        super().__init__(*args,**kwargs)
        if self.key not in self._fields:
            xs=np.arange(20.,111.);zs=np.arange(-45.,46.)
            points=np.array([[x,z] for x in xs for z in zs])
            valid=(self.clearances(points)>.6).reshape(len(xs),len(zs))
            dist=np.full(valid.shape,np.inf);queue=[]
            for i,x in enumerate(xs):
                for j,z in enumerate(zs):
                    if valid[i,j] and math.hypot(x-82,z-30)<self.arrival-.3:
                        dist[i,j]=0.;heapq.heappush(queue,(0.,i,j))
            while queue:
                d,i,j=heapq.heappop(queue)
                if d!=dist[i,j]:continue
                for di,dj in [(-1,0),(1,0),(0,-1),(0,1),(-1,-1),(-1,1),(1,-1),(1,1)]:
                    a,b=i+di,j+dj
                    if not(0<=a<len(xs) and 0<=b<len(zs)) or not valid[a,b]:continue
                    if di and dj and not(valid[i,b] and valid[a,j]):continue
                    nd=d+math.hypot(di,dj)
                    if nd<dist[a,b]:dist[a,b]=nd;heapq.heappush(queue,(nd,a,b))
            self._fields[self.key]=(xs,zs,dist)
        self.field=self._fields[self.key]

    def potential_distance(self):
        xs,zs,dist=self.field;x,z=self.plant.state[:2]
        i=int(np.clip(round(x-xs[0]),0,len(xs)-1));j=int(np.clip(round(z-zs[0]),0,len(zs)-1))
        values=[]
        for a in range(max(0,i-2),min(len(xs),i+3)):
            for b in range(max(0,j-2),min(len(zs),j+3)):
                if np.isfinite(dist[a,b]):values.append(dist[a,b]+math.hypot(x-xs[a],z-zs[b]))
        return min(values) if values else 150.

    def step(self,action):
        before=self.potential_distance();direct_before=self.distance()
        obs,reward,terminated,truncated,info=super().step(action)
        # Replace straight-line progress with navigable progress, preserving
        # collision and terminal business gates and their complete evidence.
        extra=3*(before-self.potential_distance())-(direct_before-self.distance())
        reward+=extra;self.reward_sum+=extra
        if terminated or truncated:
            info=self.result(info['success']);info['episode']={'r':self.reward_sum,'l':self.steps}
        return obs,float(reward),terminated,truncated,info

def main():
    import train_mission_terminal_rl as trainer
    trainer.TerminalHarborEnv=NavigableTerminalEnv
    trainer.main()
if __name__=='__main__':main()
