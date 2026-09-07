"""Full-spawn overtaking RL: temporal encounter consistency and hard failure cost."""
from .safe_overtaking_environment import SafeOvertakingEnv
from .environment import CONFIG

class FullMissionOvertakingEnv(SafeOvertakingEnv):
    def step(self,action):
        obs,reward,terminated,truncated,info=super().step(action)
        if self.collisions and not info.get('safety_abort'):
            reward-=1000;self.reward_sum-=1000
            info=self.result(False);info['episode']={'r':self.reward_sum,'l':self.steps}
        return obs,float(reward),terminated,truncated,info

def main():
    import train_mission_rl as trainer
    trainer.MissionEnv=FullMissionOvertakingEnv
    trainer.CONFIG={**CONFIG,'reward_profile':'full_mission_overtaking_v5','action_high':[1.,.65],
                    'curriculum_probability':0.,'restart_exploration':True}
    trainer.main()
if __name__=='__main__':main()
