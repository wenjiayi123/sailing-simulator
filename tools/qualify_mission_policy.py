#!/usr/bin/env python3
"""Independently qualify a saved scene candidate without any learner updates."""
import argparse,json,time
from pathlib import Path
import torch
from stable_baselines3 import SAC
from train_mission_rl import evaluate,write,sha,export_actor,ROOT
from mission_rl.environment import CONFIG,CONTRACT,PROFILE_PATH
from mission_rl.plant import DYNAMICS_PATH

def main():
 p=argparse.ArgumentParser();p.add_argument('--parent',required=True);p.add_argument('--output',required=True);p.add_argument('--finalize-existing',action='store_true');a=p.parse_args()
 parent=Path(a.parent).resolve();out=Path(a.output).resolve();out.mkdir(parents=True,exist_ok=a.finalize_existing)
 manifest=json.loads((parent.parent/'manifest.json').read_text());key=manifest['scenario'];config=manifest['config']
 torch.set_num_threads(1);torch.set_num_interop_threads(1)
 model=SAC.load(parent,device='cpu');started=time.monotonic()
 if a.finalize_existing:
  selection=json.loads((out/'selection.json').read_text())
  if selection['model_sha256']!=sha(parent):raise ValueError('frozen model changed')
  val=json.loads((out/'validation.json').read_text())
 else:val,_=evaluate(model,key,'validation',[0,*manifest['validation_seeds']],config)
 write(out/'validation.json',val);passed=all(r['success'] for r in val);tests=[]
 write(out/'selection.json',{'passed':passed,'model_path':str(parent),'model_sha256':sha(parent),'validation_seeds':[r['seed'] for r in val]})
 if passed:
  if a.finalize_existing:tests=json.loads((out/'test_results.json').read_text())
  else:
   tests,tracks=evaluate(model,key,'test',manifest['test_seeds'],config,True)
   write(out/'test_results.json',tests)
   for row,track in zip(tests,tracks):write(out/f"test_trajectory_{row['seed']}.json",{'result':row,'trajectory':track})
  passed=all(r['success'] for r in tests)
 sources=[PROFILE_PATH,DYNAMICS_PATH,*sorted((ROOT/'tools/mission_rl').glob('*.py')),*sorted((ROOT/'tools/mission_rl').glob('*.c'))]
 receipt={**manifest,'strategy_id':f'SAC-MISSION-{key}-{out.name}','source_hashes':{str(f.relative_to(ROOT)):sha(f) for f in sources},
  'training_manifest_path':str((parent.parent/'manifest.json').relative_to(ROOT)),
  'training_manifest_sha256':sha(parent.parent/'manifest.json'),
  'model_path':str(parent.relative_to(ROOT)),'model_sha256':sha(parent),
  'timesteps':int(model.num_timesteps),'actor_critic_updates':int(model._n_updates),
  'status':'PASS' if passed else 'NOT_CONVERGED','admitted':passed,'native_runtime_verified':False,'live_switch_admitted':False,
  'validation_success_rate':sum(r['success'] for r in val)/len(val),
  'test_accessed':bool(tests),'test_success_rate':sum(r['success'] for r in tests)/len(tests) if tests else None,
  'elapsed_wall_seconds':time.monotonic()-started}
 write(out/'receipt.json',receipt);export_actor(model,out/'actor.json',receipt)
 print(json.dumps({'status':receipt['status'],'validation':receipt['validation_success_rate'],'test':receipt['test_success_rate']}),flush=True)
if __name__=='__main__':main()
