"""Fine-tune encounter SAC using CPA risk and physical bank margins.

Only the reward changes. Actions remain direct neural commands and all original
full-spawn validation/test gates, traffic and environmental variation remain.
"""
from .environment import MissionEnv, CONFIG


class EncounterRefinementEnv(MissionEnv):
    def step(self, action):
        obs, reward, terminated, truncated, info = super().step(action)
        extra = 0.0
        for distance, relative, velocity, tcpa, dcpa, target in self._dynamic():
            # Penalize a predicted close approach while vessels are closing;
            # do not keep penalizing a receding contact after passing.
            if float(relative @ velocity) < 0 and tcpa < 60:
                margin = self.evaluation['minimum_passing_distance_m'] + 6
                extra -= .25 * max(0., 1 - dcpa / margin)
        if self.minimum_bank < 12:
            extra -= .2 * (12 - self.minimum_bank)
        reward += extra
        self.reward_sum += extra
        if terminated or truncated:
            info = self.result(info['success'])
            info['episode'] = {'r': self.reward_sum, 'l': self.steps}
        return obs, float(reward), terminated, truncated, info


def main():
    import train_mission_rl as trainer
    trainer.MissionEnv = EncounterRefinementEnv
    trainer.CONFIG = {**CONFIG, 'reward_profile': 'cpa_bank_refinement_v11',
                      'policy_replay_warmup_steps': 2000,
                      'fine_tune_learning_rate': 1e-5}
    trainer.main()


if __name__ == '__main__':
    main()
