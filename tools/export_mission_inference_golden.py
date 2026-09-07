#!/usr/bin/env python3
import argparse,json
from pathlib import Path
import numpy as np,torch
from stable_baselines3 import SAC
from mission_rl.environment import MissionEnv
from train_mission_rl import ROOT,write

def main():
 p=argparse.ArgumentParser();p.add_argument('directory');a=p.parse_args();out=Path(a.directory).resolve()
 r=json.loads((out/'receipt.json').read_text());model_path=ROOT/r['model_path'] if 'model_path' in r else out/r['frozen_model']
 torch.set_num_threads(1);m=SAC.load(model_path,device='cpu')
 if r.get('algorithm')=='hierarchical_SAC':
  from train_mission_terminal_rl import Composite
  m=Composite(SAC.load(ROOT/r['route_model'],device='cpu'),m)
 e=MissionEnv(r['scenario'],'validation',config=r['config'])
 obs,_=e.reset(seed=10001);rows=[]
 for i in range(250):
  act,_=m.predict(obs,deterministic=True);lo=np.array(e.config['action_low']);hi=np.array(e.config['action_high'])
  if i%5==0:rows.append({'observation':obs.tolist(),'command':(lo+(act+1)*.5*(hi-lo)).tolist()})
  obs,_,t,tr,_=e.step(act)
  if t or tr:obs,_=e.reset(seed=10002+i)
 write(out/'inference_golden.json',rows)
 print(out/'inference_golden.json')
if __name__=='__main__':main()
