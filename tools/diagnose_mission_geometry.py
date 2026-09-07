#!/usr/bin/env python3
"""Check current mission targets and route legs against unchanged collision geometry."""
import json
import numpy as np
from mission_rl.environment import MissionEnv,SCENARIOS
from train_mission_rl import ROOT,write

def main():
 rows=[]
 for key in SCENARIOS:
  e=MissionEnv(key,'validation');s=e.scenario['spawn'];origin=np.array([s['x'],s['z']]);segments=[]
  for index,target in enumerate(e.route):
   samples=np.linspace(origin,target,max(2,int(np.linalg.norm(target-origin))*4))
   distances=e.clearances(samples)
   segments.append({'waypoint_index':index,'target_clearance_m':float(e.clearances(target[None,:])[0]),
                    'straight_segment_minimum_clearance_m':float(distances.min()),'straight_segment_requires_detour':bool(distances.min()<=0),
                    'closest_point':samples[int(distances.argmin())].tolist()})
   origin=target
  rows.append({'scenario_key':key,'spawn_clearance_m':float(e.clearances(np.array([[s['x'],s['z']]]))[0]),'route':segments,
               'note':'Negative route-leg clearance means detour is required; negative target clearance means the target center is inside an inflated solid. Arrival circles may still intersect navigable water.'})
 write(ROOT/'reports/mission_rl_geometry_diagnosis_v1.json',{'scenarios':rows,'geometry_modified':False})
 for r in rows:
  print(r['scenario_key'],[(x['waypoint_index'],round(x['target_clearance_m'],2),round(x['straight_segment_minimum_clearance_m'],2)) for x in r['route'] if x['straight_segment_requires_detour'] or x['target_clearance_m']<=0])
if __name__=='__main__':main()
