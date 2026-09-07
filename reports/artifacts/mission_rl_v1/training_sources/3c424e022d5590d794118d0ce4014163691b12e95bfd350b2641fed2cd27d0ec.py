#!/usr/bin/env python3
"""Train direct SAC scene specialists; publish only after independent full missions."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import time
import numpy as np
import torch
from stable_baselines3 import SAC
from stable_baselines3.common.callbacks import BaseCallback
from stable_baselines3.common.monitor import Monitor
from mission_rl.environment import MissionEnv, CONFIG, CONTRACT, SCENARIOS, PROFILE_PATH
from mission_rl.plant import DYNAMICS_PATH

ROOT=Path(__file__).resolve().parents[1]
def sha(path):return hashlib.sha256(Path(path).read_bytes()).hexdigest()
def write(path,value):
    path=Path(path);path.parent.mkdir(parents=True,exist_ok=True)
    def numpy_value(item):
        if isinstance(item,np.ndarray):return item.tolist()
        if isinstance(item,np.generic):return item.item()
        raise TypeError(f'Unsupported report value: {type(item).__name__}')
    tmp=path.with_suffix(path.suffix+'.tmp');tmp.write_text(json.dumps(value,ensure_ascii=False,indent=2,allow_nan=False,default=numpy_value)+'\n');tmp.replace(path)

def evaluate(model,key,split,seeds,config,record=False):
    env=MissionEnv(key,split,config=config,record=record);rows=[];trajectories=[]
    for seed in seeds:
        obs,_=env.reset(seed=seed,options={'nominal':seed==0})
        while True:
            action,_=model.predict(obs,deterministic=True)
            obs,r,term,trunc,info=env.step(action)
            if term or trunc:break
        rows.append({**env.result(info['success']),'seed':seed})
        if record:trajectories.append(env.trajectory)
    return rows,trajectories

class Progress(BaseCallback):
    def __init__(self,path,started,initial_timesteps=0):super().__init__();self.path=path;self.started=started;self.episodes=[];self.initial_timesteps=initial_timesteps
    def _on_step(self):
        for i in self.locals.get('infos',[]):
            if 'episode' in i and 'success' in i:self.episodes.append({**{k:v for k,v in i.items() if k!='terminal_observation'},'timestep':self.num_timesteps})
        if self.n_calls%2000==0:
            last=self.episodes[-40:]
            write(self.path,{'phase':'sac_learning','timesteps':self.num_timesteps,'actor_critic_updates':int(self.model._n_updates),
               'this_run_timesteps':self.num_timesteps-self.initial_timesteps,
               'steps_per_second':(self.num_timesteps-self.initial_timesteps)/max(time.monotonic()-self.started,1),
               'recent_episode_success_rate':sum(i['success'] for i in last)/max(len(last),1),
               'recent_mean_reward':sum(i['reward'] for i in last)/max(len(last),1),
               'episode_count':len(self.episodes),'test_accessed':False})
        return True

def export_actor(model,path,metadata):
    layers=[]
    for layer in model.actor.latent_pi:
        if isinstance(layer,torch.nn.Linear):layers.append({'weight':layer.weight.detach().cpu().tolist(),'bias':layer.bias.detach().cpu().tolist(),'activation':'relu'})
    layers.append({'weight':model.actor.mu.weight.detach().cpu().tolist(),'bias':model.actor.mu.bias.detach().cpu().tolist(),'activation':'tanh'})
    write(path,{**metadata,'layers':layers,'observation_contract':CONTRACT,'observation_size':40,'action_low':CONFIG['action_low'],'action_high':CONFIG['action_high']})

def main():
    p=argparse.ArgumentParser();p.add_argument('--scenario',choices=SCENARIOS,required=True);p.add_argument('--output',required=True)
    p.add_argument('--steps',type=int,default=300000);p.add_argument('--chunk',type=int,default=25000);p.add_argument('--seed',type=int,default=90701)
    p.add_argument('--parent');p.add_argument('--curriculum',type=float,default=.7);p.add_argument('--max-steps',type=int,default=1200)
    args=p.parse_args();torch.set_num_threads(1);torch.set_num_interop_threads(1)
    out=Path(args.output).resolve();out.mkdir(parents=True,exist_ok=False)
    config={**CONFIG,'curriculum_probability':args.curriculum,'max_steps':args.max_steps}
    source_paths=[PROFILE_PATH,DYNAMICS_PATH,Path(__file__),*sorted((ROOT/'tools/mission_rl').glob('*.py')),*sorted((ROOT/'tools/mission_rl').glob('*.c'))]
    sources={str(f.relative_to(ROOT)):sha(f) for f in source_paths}
    manifest={'strategy_id':f'SAC-MISSION-{args.scenario}-{out.name}','scenario':args.scenario,'config':config,'seed':args.seed,
        'source_hashes':sources,'contract':CONTRACT,'algorithm':'SAC','training_source':'online_environment_interaction',
        'demonstrations_used':False,'controller_fallback':False,'validation_seeds':[10001,10002,10003,10004,20001,20002,20003,20004],
        'test_seeds':list(range(30001,30021)),'production_authority':False,'parent':args.parent}
    write(out/'manifest.json',manifest)
    env=Monitor(MissionEnv(args.scenario,'train',seed=args.seed,config=config))
    if args.parent:
        model=SAC.load(args.parent,env=env,device='cpu');model.learning_starts=1000
    else:
        model=SAC('MlpPolicy',env,learning_rate=3e-4,buffer_size=300000,learning_starts=2000,batch_size=256,
            tau=.01,gamma=.99,train_freq=4,gradient_steps=1,ent_coef='auto_0.05',target_entropy=-2,
            policy_kwargs={'net_arch':[64,64]},seed=args.seed,device='cpu',verbose=0)
    initial_actor=hashlib.sha256(b''.join(t.detach().cpu().numpy().tobytes() for t in model.actor.parameters())).hexdigest()
    initial_timesteps=int(model.num_timesteps);initial_updates=int(model._n_updates)
    manifest.update(parent_total_timesteps=initial_timesteps,parent_actor_critic_updates=initial_updates)
    write(out/'manifest.json',manifest)
    archive=ROOT/'reports/artifacts/mission_rl_v1/training_sources'
    archive.mkdir(parents=True,exist_ok=True)
    (archive/(sha(Path(__file__))+'.py')).write_bytes(Path(__file__).read_bytes())
    started=time.monotonic();callback=Progress(out/'progress.json',started,initial_timesteps);history=[];admitted=False
    for step in range(args.chunk,args.steps+args.chunk,args.chunk):
        model.learn(total_timesteps=min(args.chunk,args.steps-(step-args.chunk)),reset_num_timesteps=False,callback=callback)
        frozen=out/f'sac_{model.num_timesteps}.zip';model.save(frozen)
        # Train diagnostics precede expensive held-out evaluation. No test selection.
        rows,_=evaluate(model,args.scenario,'validation',[0,10001,10002],config)
        summary={'timesteps':model.num_timesteps,'updates':int(model._n_updates),'episodes':rows,'model_sha256':sha(frozen)}
        history.append(summary);write(out/'validation_history.json',history)
        write(out/'training_episodes.json',callback.episodes)
        print(json.dumps({'scenario':args.scenario,'step':model.num_timesteps,'success':[r['success'] for r in rows],
               'gates':[r['gates'] for r in rows],'final_distance':[round(r['final_distance_m'],2) for r in rows],
               'duration_s':round(time.monotonic()-started)},ensure_ascii=False),flush=True)
        if all(r['success'] for r in rows):
            val,_=evaluate(model,args.scenario,'validation',manifest['validation_seeds'],config)
            write(out/f'validation_{model.num_timesteps}.json',val)
            if all(r['success'] for r in val):
                manifest['frozen_model']=frozen.name;manifest['frozen_model_sha256']=sha(frozen)
                write(out/'selection.json',{'validation_passed':True,'frozen_model':frozen.name,'sha256':sha(frozen)})
                tests,tracks=evaluate(model,args.scenario,'test',manifest['test_seeds'],config,True)
                write(out/'test_results.json',tests)
                for row,track in zip(tests,tracks):write(out/f"test_trajectory_{row['seed']}.json",{'result':row,'trajectory':track})
                admitted=all(r['success'] for r in tests)
                break
        if step>=args.steps:break
    final_actor=hashlib.sha256(b''.join(t.detach().cpu().numpy().tobytes() for t in model.actor.parameters())).hexdigest()
    changed=final_actor!=initial_actor
    receipt={**manifest,'status':'PASS' if admitted and changed else 'NOT_CONVERGED','admitted':bool(admitted and changed),
      'timesteps':model.num_timesteps,'actor_critic_updates':int(model._n_updates),'actor_weights_changed':changed,
      'this_run_timesteps':int(model.num_timesteps)-initial_timesteps,'this_run_actor_critic_updates':int(model._n_updates)-initial_updates,
      'initial_actor_sha256':initial_actor,'final_actor_sha256':final_actor,'elapsed_wall_seconds':time.monotonic()-started,
      'last_validation_success_rate':sum(r['success'] for r in history[-1]['episodes'])/len(history[-1]['episodes']),
      'test_accessed':(out/'test_results.json').exists(),'native_runtime_verified':False,'live_switch_admitted':False}
    write(out/'receipt.json',receipt);write(out/'progress.json',receipt)
    export_actor(model,out/'actor.json',receipt)
    print(json.dumps({'receipt':str(out/'receipt.json'),'status':receipt['status']},ensure_ascii=False),flush=True)

if __name__=='__main__':main()
