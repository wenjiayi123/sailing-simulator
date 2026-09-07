"""Balance terminal curriculum with valid goal-neighborhood states, never test resets."""
import math
import numpy as np
from .terminal_environment import TerminalHarborEnv

class GoalBalancedTerminalEnv(TerminalHarborEnv):
    def reset(self,*,seed=None,options=None):
        obs,info=super().reset(seed=seed,options=options)
        if self.split!='train' or self.rng.random()>.65:return obs,info
        for _ in range(1000):
            x=float(self.rng.uniform(78,88));z=float(self.rng.uniform(10,27))
            if float(self.clearances(np.array([[x,z]]))[0])>1 and math.hypot(x-82,z-30)<18:break
        else:raise RuntimeError('No safe goal-basin sample')
        target=self.route[-1];heading=math.atan2(target[0]-x,target[1]-z)+self.rng.uniform(-1.2,1.2)
        self.plant.reset(x,z,heading,float(self.rng.uniform(0,1.5)))
        self.minimum_clearance=float(self.clearances(self.plant.state[None,:2])[0]);self.initial_distance=self.distance()
        return self.observation(),info

def main():
    import train_mission_terminal_rl as trainer
    trainer.TerminalHarborEnv=GoalBalancedTerminalEnv
    trainer.main()
if __name__=='__main__':main()
