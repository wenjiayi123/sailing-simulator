"""Reward-only V2 curriculum: planned berth speed and actual overtaking progress.

The 40D observations, actions, physical plant, geometry and every terminal
acceptance gate remain unchanged. Both maneuver and stopping actions are SAC
outputs. The extra terms value task outcomes, never expert control commands.
"""
import math
import numpy as np
from .environment import MissionEnv,CONFIG,wrap

class BusinessMissionEnv(MissionEnv):
    def reset(self, *, seed=None, options=None):
        observation,info=super().reset(seed=seed,options=options)
        if self.split=='train':
            # Interpolated curriculum resets may start inside an inflated pier
            # or rock even though the full mission spawn is valid. Do not ask
            # RL to recover from an already invalid initial physical state.
            for _ in range(128):
                if self.minimum_clearance>2:return observation,info
                observation,info=super().reset(options=options)
            old=self.curriculum_probability
            self.curriculum_probability=0
            try:observation,info=super().reset(options=options)
            finally:self.curriculum_probability=old
        return observation,info

    def step(self,action):
        was_dock=self.key=='auto_berthing' and self.waypoint==len(self.route)-1
        before_dist=self.distance()
        before_gap=self._along_gap()
        observation,reward,terminated,truncated,info=super().step(action)
        s=self.plant.state;extra=0.
        if self.key=='auto_berthing':
            if not was_dock:
                planned=self.mission['planned_speed_knots']*.514444
                extra+=.08*((s[2]-3.5)**2-(s[2]-planned)**2)
            else:
                # A waypoint arrival is insufficient: reward the complete berth
                # basin, with low speed and aligned heading, on every nearby step.
                target=self.evaluation['berth_target'];distance=self.distance()
                heading_error=wrap(math.radians(target['heading_degrees'])-s[5])
                basin=math.exp(-distance/12)
                extra+=3*basin*(math.cos(heading_error)-.8*abs(s[2])-.5*abs(s[3]))
                if distance<7 and abs(heading_error)<math.radians(8) and abs(s[2])<.42 and abs(s[3])<.25:
                    extra+=3
        if self.key=='narrow_channel_overtaking':
            after_gap=self._along_gap()
            # Until genuinely clear ahead, closing the moving vessel's gap is
            # an objective independent of reaching static route markers.
            if before_gap> -8:
                extra+=2.5*(before_gap-after_gap)
                extra-=.4
            if before_gap>=-5.7 and after_gap < -5.7:extra+=35
            h=self.scenario.get('realism',{}).get('hydrodynamics',{})
            minimum=h.get('minimum_bank_clearance_m',8)
            if self.minimum_bank<minimum+4:extra-=max(0,minimum+4-self.minimum_bank)*.5
        if self.key=='harbor':
            # Continuous turn-in reward prevents a stationary local optimum in
            # front of a waypoint whose shortest straight route is obstructed.
            target=self.route[self.waypoint]-s[:2]
            heading_error=wrap(math.atan2(target[0],target[1])-s[5])
            extra+=.3*math.cos(heading_error)-.3
        reward+=extra;self.reward_sum+=extra
        if terminated or truncated:
            info=self.result(info['success']);info['episode']={'r':self.reward_sum,'l':self.steps}
        return observation,float(reward),terminated,truncated,info

    def _along_gap(self):
        if not self.traffic:return 0.
        target=self.traffic[0].state
        return float(np.dot(target[:2]-self.plant.state[:2],[math.sin(target[5]),math.cos(target[5])]))

def main():
    # Reuse the evidence/selection pipeline unchanged. This module is included
    # in its source fingerprints, and the reward profile is stored in config.
    import train_mission_rl as trainer
    trainer.MissionEnv=BusinessMissionEnv
    trainer.CONFIG={**CONFIG,'reward_profile':'business_v2'}
    trainer.main()

if __name__=='__main__':main()
