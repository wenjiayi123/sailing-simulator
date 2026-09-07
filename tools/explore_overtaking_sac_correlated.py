#!/usr/bin/env python3
"""Training-only stochastic exploration of an existing SAC actor; no expert policy."""
import json,time
from pathlib import Path
import numpy as np
from mission_rl.coupled_overtaking_v7 import CoupledOvertakingEnv,TRAFFIC_PATH
from mission_rl.traffic_lane import NumpyActor
from train_mission_rl import ROOT,write,sha

def main():
 out=ROOT/'reports/artifacts/mission_rl_v1/overtaking_exploration_11';out.mkdir(parents=True,exist_ok=False)
 parent=ROOT/'reports/artifacts/mission_rl_v1/overtaking_constrained_04/actor.json';actor=NumpyActor(parent)
 env=CoupledOvertakingEnv('narrow_channel_overtaking','train',config={'traffic_policy_path':TRAFFIC_PATH,'action_high':[1.,.65],'curriculum_probability':0.})
 rng=np.random.default_rng(90751);rows=[];transitions=[];success_ids=[];started=time.monotonic()
 for episode in range(500):
  obs,_=env.reset(seed=900000+episode);start_index=len(transitions)
  noise=[.025,.05,.1,.15,.2][episode%5];correlated=0.
  while True:
   physical=actor.command(obs);raw=2*(physical-actor.lo)/(actor.hi-actor.lo)-1
   correlated=.9*correlated+np.sqrt(1-.9**2)*float(rng.normal(0,noise))
   action=np.clip(raw+np.array([0.,correlated]),-1,1).astype(np.float32)
   nxt,reward,term,trunc,info=env.step(action)
   transitions.append((obs,nxt,action,reward,float(term),float(trunc)));obs=nxt
   if term or trunc:break
  row={**env.result(info['success']),'training_seed':900000+episode,'exploration_std':noise,'episode_id':episode,'transition_start':start_index,'transition_end':len(transitions)};rows.append(row)
  if row['success']:success_ids.extend(range(start_index,len(transitions)))
  if (episode+1)%25==0:
   write(out/'progress.json',{'episodes':episode+1,'successes':sum(r['success'] for r in rows),'environment_steps':len(transitions),'elapsed_seconds':time.monotonic()-started})
   print(episode+1,sum(r['success'] for r in rows),flush=True)
  if sum(r['success'] for r in rows)>=25:break
 write(out/'episodes.json',rows)
 np.savez_compressed(out/'exploration_replay.npz',obs=np.stack([t[0] for t in transitions]),next_obs=np.stack([t[1] for t in transitions]),actions=np.stack([t[2] for t in transitions]),rewards=np.array([t[3] for t in transitions]),terminated=np.array([t[4] for t in transitions]),truncated=np.array([t[5] for t in transitions]),success_transition_ids=np.array(success_ids,dtype=np.int64))
 write(out/'receipt.json',{'status':'TRAINING_EXPLORATION_ONLY','algorithm':'SAC_actor_with_correlated_Gaussian_exploration','parent_actor_sha256':sha(parent),'traffic_policy_sha256':sha(ROOT/TRAFFIC_PATH),'source_sha256':sha(Path(__file__)),'episodes':len(rows),'successes':sum(r['success'] for r in rows),'environment_steps':len(transitions),'demonstrations_used':False,'controller_fallback_steps':0,'test_accessed':False,'admitted':False,'production_authority':False})
if __name__=='__main__':main()
