#!/usr/bin/env python3
"""Train, freeze and independently test lane-keeping traffic SAC; no expert actions."""
import argparse,time,json
from pathlib import Path
import torch,numpy as np
from stable_baselines3 import SAC
from stable_baselines3.common.monitor import Monitor
from mission_rl.traffic_lane import TrafficLaneEnv,CONFIG
from train_mission_rl import ROOT,write,sha

def evaluate(model,seeds):
 env=TrafficLaneEnv('validation');rows=[];golden=[]
 for seed in seeds:
  o,_=env.reset(seed=seed,options={'nominal':seed==0})
  while True:
   a,_=model.predict(o,deterministic=True)
   if seed==0 and len(golden)<50:
    lo=np.array(CONFIG['action_low']);hi=np.array(CONFIG['action_high']);golden.append({'observation':o.tolist(),'command':(lo+(a+1)*.5*(hi-lo)).tolist()})
   o,_,t,u,info=env.step(a)
   if t or u:break
  rows.append({**env.result(),'seed':seed})
 return rows,golden

def main():
 p=argparse.ArgumentParser();p.add_argument('--output',required=True);a=p.parse_args();out=Path(a.output).resolve();out.mkdir(parents=True,exist_ok=False)
 torch.set_num_threads(1);torch.set_num_interop_threads(1);env=Monitor(TrafficLaneEnv('train'))
 model=SAC('MlpPolicy',env,policy_kwargs={'net_arch':[32,32]},learning_rate=3e-4,buffer_size=100000,batch_size=256,learning_starts=1000,train_freq=4,gradient_steps=1,ent_coef='auto_0.05',gamma=.99,seed=90731,device='cpu')
 files=[Path(__file__),ROOT/'tools/mission_rl/traffic_lane.py',ROOT/'tools/mission_rl/plant.py',ROOT/'tools/mission_rl/plant.c',ROOT/'tools/mission_rl/environment.py',ROOT/'data/ports/default_port_profile.json',ROOT/'data/verification/catamaran_usv_dynamics_reference_v2.json']
 manifest={'algorithm':'SAC','role':'slow_traffic_lane_holding','config':CONFIG,'source_hashes':{str(p.relative_to(ROOT)):sha(p) for p in files},'seed':90731,'demonstrations_used':False,'controller_fallback':False,'production_authority':False}
 write(out/'manifest.json',manifest);history=[];passed=False;start=time.monotonic()
 for step in range(10000,150001,10000):
  model.learn(10000,reset_num_timesteps=False);model.save(out/f'sac_{step}.zip');rows,golden=evaluate(model,[0,11001,11002,11003,11004])
  history.append({'timesteps':step,'episodes':rows});write(out/'validation_history.json',history)
  write(out/'progress.json',{'phase':'traffic_SAC_training','timesteps':step,'actor_critic_updates':int(model._n_updates),'validation_success_rate':sum(r['success'] for r in rows)/len(rows)})
  print(step,[r['success'] for r in rows],flush=True)
  if all(r['success'] for r in rows):
   write(out/'selection.json',{'model':f'sac_{step}.zip','sha256':sha(out/f'sac_{step}.zip'),'test_accessed':False})
   tests,_=evaluate(model,list(range(31001,31021)));write(out/'test_results.json',tests);passed=all(r['success'] for r in tests);break
 layers=[]
 for layer in model.actor.latent_pi:
  if isinstance(layer,torch.nn.Linear):layers.append({'weight':layer.weight.detach().tolist(),'bias':layer.bias.detach().tolist(),'activation':'relu'})
 layers.append({'weight':model.actor.mu.weight.detach().tolist(),'bias':model.actor.mu.bias.detach().tolist(),'activation':'tanh'})
 receipt={**manifest,'status':'PASS' if passed else 'NOT_CONVERGED','admitted_numeric':passed,'timesteps':model.num_timesteps,'actor_critic_updates':int(model._n_updates),'elapsed_seconds':time.monotonic()-start,'model_sha256':sha(out/f'sac_{model.num_timesteps}.zip')}
 write(out/'receipt.json',receipt);write(out/'actor.json',{**receipt,'layers':layers,'action_low':CONFIG['action_low'],'action_high':CONFIG['action_high'],'observation_size':10,'observation_contract':'traffic_lane_sac_10d_v1'})
 write(out/'inference_golden.json',golden);print(receipt['status'],flush=True)
if __name__=='__main__':main()
