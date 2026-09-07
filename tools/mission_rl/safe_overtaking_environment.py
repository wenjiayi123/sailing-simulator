"""Constrained direct SAC: irreversible passing/bank violations end training episodes."""
from .business_environment import BusinessMissionEnv
from .environment import CONFIG

class SafeOvertakingEnv(BusinessMissionEnv):
    def step(self,action):
        obs,reward,terminated,truncated,info=super().step(action)
        unsafe=self.minimum_separation<self.evaluation['minimum_passing_distance_m'] or self.minimum_bank<8
        if unsafe:
            reward-=1000;self.reward_sum-=1000
            terminated=True;truncated=False
            info=self.result(False);info['episode']={'r':self.reward_sum,'l':self.steps};info['safety_abort']=True
        elif truncated:
            reward-=400;self.reward_sum-=400
            info=self.result(False);info['episode']={'r':self.reward_sum,'l':self.steps}
        return obs,float(reward),terminated,truncated,info

def main():
    import train_mission_rl as trainer
    trainer.MissionEnv=SafeOvertakingEnv
    trainer.CONFIG={**CONFIG,'reward_profile':'constrained_overtaking_v4','action_high':[1.,.65],'restart_exploration':True}
    trainer.main()
if __name__=='__main__':main()
