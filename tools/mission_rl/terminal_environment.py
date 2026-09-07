"""Terminal harbor curriculum for a separate, direct-action SAC specialist."""
import math
import numpy as np
from .environment import MissionEnv

class TerminalHarborEnv(MissionEnv):
    def reset(self,*,seed=None,options=None):
        obs,info=super().reset(seed=seed,options=options)
        if self.split!='train':return obs,info
        for _ in range(500):
            x=float(self.rng.uniform(45,88));z=float(self.rng.uniform(-24,26))
            if float(self.clearances(np.array([[x,z]]))[0])>1:break
        else:raise RuntimeError('No collision-free terminal curriculum spawn')
        target=self.route[-1];heading=math.atan2(target[0]-x,target[1]-z)+self.rng.uniform(-.8,.8)
        self.plant.reset(x,z,heading,float(self.rng.uniform(0,3)))
        self.waypoint=len(self.route)-1;self.initial_waypoint=self.waypoint
        self.route_complete=False;self.curriculum=True
        self.minimum_clearance=float(self.clearances(self.plant.state[None,:2])[0]);self.initial_distance=self.distance()
        self.trajectory=[]
        if self.record:self._record(np.zeros(2))
        return self.observation(),info
