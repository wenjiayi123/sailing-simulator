# SAC-P47 Attempt 13 interruption receipt

Attempt 13 continued the complete P47 initialization experiment only because the
long-running goal record still requested a 47-dimensional champion. The user
then clarified that the new automatic-berthing and encounter maps are a
functionality expansion, not a new algorithm challenge, and directed the work
to use lower-difficulty assurance. The process was stopped immediately.

## Preserved result

- Attempt 12 supplied only two contract-bearing expert NPZ caches. No actor,
  critic, DAgger state or failed model was copied.
- DAgger 70% expert: 5/5 successful.
- DAgger 40% expert: 5/5 successful.
- DAgger 20% expert: 2/5 successful; tasks 1, 4 and 5 were retained as recovery
  labels.
- First 0% expert round: 0/5 successful.
- Second 0% expert round: 0/5 successful.
- Independent initialization evaluation: case 1/8 completed successfully; the
  remaining cases were interrupted by explicit user direction.
- SAC actor/critic updates started: false.
- New champion or strategy-dropdown admission: false.
- Existing 36D/44D policies modified: false.

The incomplete caches under
`output/cargo_physics_sac_p47_ladder_attempt_13/` are diagnostic evidence only.
They must not be described as a model, a converged policy or an admitted
strategy. Advanced mission maps are instead accepted through native runtime
function tests and may optionally be evaluated with already-trained 28D/44D
policies under a compatible adapter and fresh task-specific evaluation.
