#!/usr/bin/env python3
"""Hierarchical RL: frozen transit SAC plus separately trained terminal SAC."""
import argparse,json,time
from pathlib import Path
import numpy as np,torch
from stable_baselines3 import SAC
from stable_baselines3.common.monitor import Monitor
from mission_rl.terminal_environment import TerminalHarborEnv
from mission_rl.environment import CONFIG,PROFILE_PATH
from mission_rl.plant import DYNAMICS_PATH
from train_mission_rl import ROOT,Progress,evaluate,write,sha,export_actor

class Composite:
 def __init__(self,transit,terminal):self.transit=transit;self.terminal=terminal
 def predict(self,obs,deterministic=True):
  return (self.terminal if obs[14]>.5 else self.transit).predict(obs,deterministic=deterministic)

def main():
 p=argparse.ArgumentParser();p.add_argument('--route-model',required=True);p.add_argument('--output',required=True);p.add_argument('--steps',type=int,default=100000);a=p.parse_args()
 torch.set_num_threads(1);torch.set_num_interop_threads(1);out=Path(a.output).resolve();out.mkdir(parents=True,exist_ok=False)
 route_path=Path(a.route_model).resolve();transit=SAC.load(route_path,device='cpu')
 cfg={**CONFIG,'curriculum_probability':0.,'max_steps':1200,'reward_profile':'terminal_harbor_curriculum_v1'}
 train_cfg={**cfg,'max_steps':300};env=Monitor(TerminalHarborEnv('harbor','train',seed=90719,config=train_cfg))
 terminal=SAC('MlpPolicy',env,learning_rate=3e-4,buffer_size=150000,learning_starts=1000,batch_size=256,gamma=.99,train_freq=4,gradient_steps=1,
    ent_coef='auto_0.05',policy_kwargs={'net_arch':[64,64]},seed=90719,device='cpu')
 policy=Composite(transit,terminal);started=time.monotonic();cb=Progress(out/'progress.json',started)
 files=[Path(__file__),route_path,PROFILE_PATH,DYNAMICS_PATH,*sorted((ROOT/'tools/mission_rl').glob('*.py')),*sorted((ROOT/'tools/mission_rl').glob('*.c'))]
 manifest={'scenario':'harbor','strategy_id':'SAC-MISSION-HARBOR-TRANSIT-TERMINAL-V1','config':cfg,
   'source_hashes':{str(p.relative_to(ROOT)):sha(p) for p in files},'algorithm':'hierarchical_SAC','seed':90719,'route_model':str(route_path.relative_to(ROOT)),
   'route_model_sha256':sha(route_path),'router':'last_waypoint_selects_terminal_neural_actor','controller_fallback':False,'demonstrations_used':False,
   'validation_seeds':[10001,10002,10003,10004,20001,20002,20003,20004],'test_seeds':list(range(30001,30021)),'production_authority':False}
 write(out/'manifest.json',manifest);history=[];passed=False
 for _ in range(0,a.steps,10000):
  terminal.learn(total_timesteps=10000,reset_num_timesteps=False,callback=cb);terminal.save(out/f'terminal_{terminal.num_timesteps}.zip')
  rows,_=evaluate(policy,'harbor','validation',[0,10001,10002],cfg)
  history.append({'timesteps':terminal.num_timesteps,'episodes':rows});write(out/'validation_history.json',history);write(out/'training_episodes.json',cb.episodes)
  print(json.dumps({'steps':terminal.num_timesteps,'success':[r['success'] for r in rows],'distance':[r['final_distance_m'] for r in rows]}),flush=True)
  if all(r['success'] for r in rows):
   val,_=evaluate(policy,'harbor','validation',manifest['validation_seeds'],cfg);write(out/'validation.json',val)
   if all(r['success'] for r in val):
    write(out/'selection.json',{'passed':True,'terminal_model':f'terminal_{terminal.num_timesteps}.zip','sha256':sha(out/f'terminal_{terminal.num_timesteps}.zip')})
    tests,tracks=evaluate(policy,'harbor','test',manifest['test_seeds'],cfg,True);write(out/'test_results.json',tests)
    for row,track in zip(tests,tracks):write(out/f"test_trajectory_{row['seed']}.json",{'result':row,'trajectory':track})
    passed=all(r['success'] for r in tests);break
 terminal_path=out/f'terminal_{terminal.num_timesteps}.zip'
 receipt={**manifest,'status':'PASS' if passed else 'NOT_CONVERGED','admitted':passed,'timesteps':terminal.num_timesteps,'actor_critic_updates':int(terminal._n_updates),
  'model_path':str(terminal_path.relative_to(ROOT)),'model_sha256':sha(terminal_path),'test_accessed':(out/'test_results.json').exists(),
  'native_runtime_verified':False,'live_switch_admitted':False,'elapsed_seconds':time.monotonic()-started}
 write(out/'receipt.json',receipt);write(out/'progress.json',receipt)
 export_actor(transit,out/'actor.json',receipt);export_actor(terminal,out/'terminal_actor.json',receipt)
 actor=json.loads((out/'actor.json').read_text());actor['terminal_layers']=json.loads((out/'terminal_actor.json').read_text())['layers'];write(out/'actor.json',actor)
 env_eval=TerminalHarborEnv('harbor','train',config=cfg);golden=[]
 for seed in range(50):
  o,_=env_eval.reset(seed=seed);act,_=policy.predict(o,deterministic=True);lo=np.array(cfg['action_low']);hi=np.array(cfg['action_high'])
  golden.append({'observation':o.tolist(),'command':(lo+(act+1)*.5*(hi-lo)).tolist()})
 write(out/'inference_golden.json',golden)
 print(json.dumps({'status':receipt['status'],'path':str(out)}),flush=True)
if __name__=='__main__':main()
