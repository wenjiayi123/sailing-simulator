# SAC-P47 Attempt 11 non-convergence diagnosis

Attempt 11 tested the first throttle-specific correction on the complete P47-L5
circuit. It stopped before any SAC update because the deterministic initialized
policy failed the new fail-closed train-split gate.

## Preserved outcome

- Expert demonstrations: 95/95 successful (15 full circuits plus 80 one/two-leg
  randomized starts).
- DAgger mixed-control rounds: 5/5 at 70% expert, 5/5 at 40% expert, and 5/5 at
  20% expert.
- First pure-policy DAgger round: 1/5 successful; the other four trajectories
  were retained as labeled recovery states.
- Independent post-fit initialization gate: 0/5 successful, checkpoint progress
  4/7, 4/7, 3/7, 3/7, and 3/7. Three terrain collisions occurred; two episodes
  timed out without collision. SAC updates started: false.

## Complete failure localization

The problem remained throttle-dominant rather than rudder-dominant. Across the
five independent gate replays, tail rudder mean absolute error stayed between
0.124 and 0.153. Throttle mean absolute error ranged from 0.358 to 0.664.

The clearest failure occurred on train task 4 before
`GroundedPlate_03_ForkedGroundPillar`: in the final 500 steps the policy issued
strong reverse 99.8% of the time while the expert issued it 0% of the time. On
train task 2 before `GroundedPlate_06_TwistedButtressMesa`, the corresponding
ratios were 56.2% versus 4.8%. This reproduces the strong-reverse local optimum
from Attempt 10 even though ordinary aggregate cloning loss was low.

The first correction fitted latest pure-policy recovery states and then fitted
the much larger aggregate corpus. The latter operation overwrote the rare
recovery correction. Attempt 12 therefore reverses that order, finishing each
round on the latest policy-induced states, strengthens throttle loss from 2.0
to 3.0, and requires two consecutive pure-policy DAgger sampling rounds before
the independent 5/5 initialization gate.

Attempt 11 artifacts remain under
`output/cargo_physics_sac_p47_ladder_attempt_11/` and are not champions.
Existing 36D and 44D strategy artifacts were not modified.
