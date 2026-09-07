"""Overtaking SAC with the complete physical ahead-thrust action range.

The generic 65-percent throttle envelope made the requested closing speed
unreachable after shallow-water drag. This version restores the physical
[-0.6, 1.0] throttle range; safety/arrival/passing gates stay unchanged.
"""
from .business_environment import BusinessMissionEnv
from .environment import CONFIG

def main():
    import train_mission_rl as trainer
    trainer.MissionEnv=BusinessMissionEnv
    trainer.CONFIG={**CONFIG,'reward_profile':'business_v2_full_ahead','action_high':[1.,.65]}
    trainer.main()

if __name__=='__main__':main()
