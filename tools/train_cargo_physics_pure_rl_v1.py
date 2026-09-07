#!/usr/bin/env python3
"""Independent pure SAC attempt: no prerequisite that an untrained actor succeeds.

Keep all original map bodies, six traffic vessels, and the unchanged held-out
ladder gate. Stop at the first failed level; never replace frozen policies.
"""
import argparse,json,time,hashlib
from pathlib import Path
import torch,numpy as np
from stable_baselines3 import SAC
from stable_baselines3.common.monitor import Monitor
from stable_baselines3.common.callbacks import BaseCallback
from ship_rl.environment import load_experiment
from cargo_rl.physics_accelerated import AcceleratedCargoPhysicsEnv
from cargo_rl.physics_environment import CargoPhysicsV4Env
from train_mission_rl import ROOT,write,sha
import run_cargo_physics_difficulty_ladder_v4 as ladder

class Progress(BaseCallback):
 def __init__(self,out):super().__init__();self.out=out;self.rows=[]
 def _on_step(self):
  for info in self.locals.get('infos',[]):
   if 'episode' in info:self.rows.append({k:v for k,v in info.items() if k!='terminal_observation'})
  if self.n_calls%2000==0:
   write(self.out/'progress.json',{'phase':'pure_sac_training','timesteps':self.num_timesteps,'actor_critic_updates':int(self.model._n_updates),
       'expert_actions':0,'validation_fallback_actions':0,'episodes':len(self.rows),'test_accessed':False})
  return True

def main():
 p=argparse.ArgumentParser();p.add_argument('--output',required=True);p.add_argument('--steps',type=int,default=100000);a=p.parse_args()
 out=Path(a.output).resolve();out.mkdir(parents=True,exist_ok=False);torch.set_num_threads(1);torch.set_num_interop_threads(1)
 base,dataset,_=load_experiment(ROOT/'data/rl/cargo_circuit_physics_experiment_v4.json')
 level=base['cargo_parameters']['difficulty_ladder'][0];config=ladder._level_config(base,level)
 # Check equivalence against the original scalar environment before learning.
 kwargs=dict(split='train',seed=90747,task_index=0,max_steps=level['max_steps'],curriculum_route_length=level['route_length'],
             curriculum_obstacles_enabled=True,curriculum_randomization_enabled=False,curriculum_random_segment=level['random_segment'])
 fast=AcceleratedCargoPhysicsEnv(config,dataset,**kwargs);slow=CargoPhysicsV4Env(config,dataset,**kwargs)
 fast.reset(seed=90747);slow.reset(seed=90747);maximum=0.
 for i in range(30):
  action=np.array([.1,.2*np.sin(i/5)],dtype=np.float32)
  of,rf,tf,uf,inf=fast.step(action);os,rs,ts,us,ins=slow.step(action)
  maximum=max(maximum,float(np.max(np.abs(fast.state-slow.state))))
  if tf or uf:break
 if maximum>1e-8:raise RuntimeError(f'Accelerator parity failed: {maximum}')
 write(out/'plant_equivalence.json',{'max_state_error':maximum,'passed':True,'all_original_obstacles_preserved':True})
 ladder.CargoPhysicsV4Env=AcceleratedCargoPhysicsEnv
 env=ladder._make_env(config,dataset,level,split='train',seed=90747,monitor=True)
 obs,info=env.reset();raw=env.unwrapped
 rocks=sum(not o.dynamic for o in raw.obstacles);traffic=sum(o.dynamic for o in raw.obstacles)
 if rocks<32 or traffic<6:raise ValueError('Full map and traffic gate failed')
 source_paths=[Path(__file__),ROOT/'tools/cargo_rl/physics_accelerated.py',ROOT/'tools/mission_rl/plant.py',ROOT/'tools/mission_rl/plant.c',ROOT/'tools/cargo_rl/physics_environment.py',ROOT/'data/rl/cargo_circuit_physics_experiment_v4.json',ROOT/'data/rl/cargo_circuit_physics_dataset_v4.json']
 write(out/'manifest.json',{'algorithm':'SAC','expert_actions':0,'demonstrations_used':False,'level':level,'source_hashes':{str(p.relative_to(ROOT)):sha(p) for p in source_paths},'static_obstacles':rocks,'traffic':traffic,'seed':90747})
 model=SAC('MlpPolicy',env,policy_kwargs={'net_arch':[128,128]},learning_rate=3e-4,buffer_size=150000,batch_size=256,
           learning_starts=2000,train_freq=4,gradient_steps=1,ent_coef='auto_0.05',gamma=.995,device='cpu',seed=90747)
 initial=ladder._actor_sha256(model.actor);start=time.monotonic();cb=Progress(out)
 model.learn(total_timesteps=a.steps,callback=cb);model.save(out/'sac_p47_l1.zip')
 write(out/'training_episodes.json',cb.rows)
 rows,trajectory=ladder._evaluate(model,config,dataset,level,split='validation',sweeps=2,seed=147000)
 gate=ladder._gate(rows,int(model._n_updates),required_sweeps=2)
 write(out/'validation.json',rows)
 # A passed short-segment level still cannot represent a full-circuit policy.
 receipt={'status':'L1_PASS_ONLY' if gate['passed'] else 'L1_NOT_CONVERGED','gate':gate,'timesteps':model.num_timesteps,'actor_critic_updates':int(model._n_updates),
  'actor_weights_changed':initial!=ladder._actor_sha256(model.actor),'expert_actions':0,'test_accessed':False,'full_circuit_admitted':False,
  'model_sha256':sha(out/'sac_p47_l1.zip'),'elapsed_seconds':time.monotonic()-start,'production_authority':False,
  'decision':'Stop and diagnose first failed level; existing full-circuit policies remain unchanged.' if not gate['passed'] else 'Only L1 has passed; further ladder levels remain unverified.'}
 write(out/'receipt.json',receipt);write(out/'progress.json',receipt)
 print(json.dumps(receipt),flush=True)
if __name__=='__main__':main()
