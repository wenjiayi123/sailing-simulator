#!/usr/bin/env python3
"""Re-evaluate frozen policies after scenario changes without rewriting old evidence.

source_hashes binds this qualification's numerical contract. The immutable
training receipt/hash and training_source_hashes retain the training lineage.
Native validation and deployment remain separate, mandatory steps.
"""
import argparse
import copy
import json
import shutil
from pathlib import Path
import numpy as np
import torch
from stable_baselines3 import SAC
from train_mission_rl import ROOT, write, sha, export_actor, evaluate
from mission_rl.environment import MissionEnv, PROFILE_PATH
from mission_rl.plant import DYNAMICS_PATH
from mission_rl.coupled_overtaking_v7 import CoupledOvertakingEnv

ARTIFACTS = ROOT / 'reports/artifacts/mission_rl_v1'

def read(path):
    return json.loads(Path(path).read_text())

def sources():
    paths = [PROFILE_PATH, DYNAMICS_PATH, Path(__file__), ROOT / 'tools/train_mission_rl.py',
             *sorted((ROOT / 'tools/mission_rl').glob('*.py')),
             *sorted((ROOT / 'tools/mission_rl').glob('*.c'))]
    return {str(p.relative_to(ROOT)): sha(p) for p in paths}

def requalify_traffic(tag):
    from train_traffic_lane_rl_v2 import evaluate as evaluate_traffic
    parent = ARTIFACTS / 'traffic_lane_attempt_02'
    receipt = read(parent / 'receipt.json')
    model_path = parent / f"sac_{receipt['timesteps']}.zip"
    model = SAC.load(model_path, device='cpu')
    validation, golden = evaluate_traffic(model, [0, 11001, 11002, 11003, 11004])
    if not all(r['success'] for r in validation):
        raise RuntimeError('traffic policy validation failed')
    tests, _ = evaluate_traffic(model, list(range(31001, 31021)))
    out = ARTIFACTS / f'traffic_lane_requalified_{tag}'
    out.mkdir(exist_ok=False)
    passed = all(r['success'] for r in tests)
    updated = {**receipt, 'source_hashes': sources(),
               'training_source_hashes': receipt['source_hashes'],
               'training_receipt_path': str((parent / 'receipt.json').relative_to(ROOT)),
               'training_receipt_sha256': sha(parent / 'receipt.json'),
               'qualification_only': True, 'this_run_timesteps': 0,
               'this_run_actor_critic_updates': 0,
               'status': 'PASS' if passed else 'NOT_CONVERGED', 'admitted_numeric': passed}
    shutil.copy2(model_path, out / model_path.name)
    for name, value in [('receipt', updated), ('manifest', updated), ('validation', validation),
                        ('test_results', tests), ('inference_golden', golden)]:
        write(out / f'{name}.json', value)
    actor = read(parent / 'actor.json')
    write(out / 'actor.json', {**actor, **updated})
    if not passed:
        raise RuntimeError('traffic independent tests failed')
    print('traffic qualification PASS: 20/20', flush=True)
    return out / 'actor.json'

def requalify_scene(key, receipt_path, tag, traffic_path):
    import train_mission_rl as trainer
    receipt = read(receipt_path)
    model_path = ROOT / receipt['model_path'] if receipt.get('model_path') else receipt_path.parent / receipt.get('frozen_model', f"sac_{receipt['timesteps']}.zip")
    model = SAC.load(model_path, device='cpu')
    if receipt.get('algorithm') == 'hierarchical_SAC':
        from train_mission_terminal_rl import Composite
        model = Composite(SAC.load(ROOT / receipt['route_model'], device='cpu'), model)
    config = copy.deepcopy(receipt['config'])
    if config.get('traffic_policy_path'):
        config.update(traffic_policy_path=str(traffic_path.relative_to(ROOT)), traffic_policy_sha256=sha(traffic_path))
    env_type = CoupledOvertakingEnv if config.get('traffic_policy_path') else MissionEnv
    trainer.MissionEnv = env_type
    val, _ = evaluate(model, key, 'validation', [0, 10001, 10002, 10003, 10004, 20001, 20002, 20003, 20004], config)
    out = ARTIFACTS / f'{key}_requalified_{tag}'
    out.mkdir(exist_ok=False)
    write(out / 'validation.json', val)
    passed = all(r['success'] for r in val)
    tests, tracks = evaluate(model, key, 'test', list(range(30001, 30021)), config, True) if passed else ([], [])
    passed = passed and all(r['success'] for r in tests)
    updated = {**receipt, 'strategy_id': f'SAC-MISSION-{key}-{out.name}', 'config': config,
               'source_hashes': sources(), 'training_source_hashes': receipt['source_hashes'],
               'training_receipt_path': str(receipt_path.relative_to(ROOT)), 'training_receipt_sha256': sha(receipt_path),
               'qualification_only': True, 'this_run_timesteps': 0, 'this_run_actor_critic_updates': 0,
               'model_path': str(model_path.relative_to(ROOT)), 'model_sha256': sha(model_path),
               'status': 'PASS' if passed else 'NOT_CONVERGED', 'admitted': passed,
               'native_runtime_verified': False, 'live_switch_admitted': False,
               'validation_success_rate': sum(r['success'] for r in val) / len(val),
               'test_seeds': list(range(30001, 30021)), 'test_accessed': bool(tests),
               'test_success_rate': sum(r['success'] for r in tests) / len(tests) if tests else None}
    for name, value in [('receipt', updated), ('manifest', updated), ('test_results', tests)]:
        write(out / f'{name}.json', value)
    for row, track in zip(tests, tracks):
        write(out / f"test_trajectory_{row['seed']}.json", {'result': row, 'trajectory': track})
    # Export the loaded frozen network, never hand-edit model parameters.
    if receipt.get('algorithm') == 'hierarchical_SAC':
        export_actor(model.transit, out / 'actor.json', updated)
        export_actor(model.terminal, out / 'terminal_actor.json', updated)
        actor = read(out / 'actor.json'); actor['terminal_layers'] = read(out / 'terminal_actor.json')['layers']
        write(out / 'actor.json', actor)
    else:
        export_actor(model, out / 'actor.json', updated)
    env = env_type(key, 'validation', config=config)
    obs, _ = env.reset(seed=10001)
    golden = []
    for step in range(250):
        action, _ = model.predict(obs, deterministic=True)
        low, high = np.array(config['action_low']), np.array(config['action_high'])
        if step % 5 == 0:
            golden.append({'observation': obs.tolist(), 'command': (low + (action + 1) * .5 * (high - low)).tolist()})
        obs, _, terminated, truncated, _ = env.step(action)
        if terminated or truncated:
            obs, _ = env.reset(seed=10002 + step)
    write(out / 'inference_golden.json', golden)
    print(key, updated['status'], f"validation {sum(r['success'] for r in val)}/{len(val)} test {sum(r['success'] for r in tests)}/{len(tests)}", flush=True)
    return passed

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--tag', required=True)
    args = parser.parse_args()
    torch.set_num_threads(1); torch.set_num_interop_threads(1)
    # Snapshot the catalog before any deployment mutation.
    catalog = read(ROOT / 'data/rl/mission_rl_catalog_v1.json')
    traffic = requalify_traffic(args.tag)
    passed = True
    for key, entry in catalog['scenarios'].items():
        receipt_path = ROOT / entry['receipt_path']
        if key == 'narrow_channel_head_on':
            receipt_path = ARTIFACTS / f'head_on_refinement_{args.tag}/receipt.json'
        passed = requalify_scene(key, receipt_path, args.tag, traffic) and passed
    raise SystemExit(0 if passed else 1)

if __name__ == '__main__':
    main()
