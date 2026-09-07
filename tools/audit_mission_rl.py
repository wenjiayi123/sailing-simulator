#!/usr/bin/env python3
"""Build a source-linked RL inventory and admit only verified scene specialists."""
import json
from pathlib import Path
from datetime import datetime,timezone
from train_mission_rl import ROOT,sha,write
from mission_rl.environment import SCENARIOS

ARTIFACTS=ROOT/'reports/artifacts/mission_rl_v1'
RUNTIME_PATHS=['scripts/rl/mission_rl_controller.gd','scripts/rl/ship_fleet_manager.gd','scripts/training/ship_advanced_mission_controller.gd','scripts/physics/catamaran_three_dof_dynamics.gd','scripts/training/ship_advanced_mission_realism_controller.gd','player.gd']
def read(path):return json.loads(Path(path).read_text())
def native_sources_match(native):
 hashes=native.get('native_runtime_sources',{})
 paths=RUNTIME_PATHS+(['scripts/rl/mission_rl_traffic_controller.gd'] if native.get('traffic_policy_required') else [])
 return all(hashes.get(p)==sha(ROOT/p) for p in paths)
def source_ok(receipt):
 for p,h in receipt.get('source_hashes',{}).items():
  if (ROOT/p).is_file() and sha(ROOT/p)==h:continue
  # Training orchestration can evolve; retain its exact original source.
  # Geometry, plant and observation mismatches still fail closed.
  archive=ARTIFACTS/'training_sources'/(h+'.py')
  if p=='tools/train_mission_rl.py' and archive.is_file() and sha(archive)==h:continue
  return False
 return bool(receipt.get('source_hashes'))
def traffic_policy_qualified(config):
 if not config.get('traffic_policy_path'):return True
 path=ROOT/config['traffic_policy_path']
 if not path.is_file() or sha(path)!=config.get('traffic_policy_sha256'):return False
 actor=read(path);receipt=read(path.parent/'receipt.json');tests=read(path.parent/'test_results.json')
 model=path.parent/f"sac_{receipt.get('timesteps',0)}.zip"
 return bool(actor.get('admitted_numeric') and receipt.get('actor_critic_updates',0)>0 and source_ok(receipt)
   and model.is_file() and sha(model)==receipt.get('model_sha256')
   and sorted(x.get('seed') for x in tests)==list(range(31001,31021))
   and all(x.get('success') and x.get('collisions')==0 and x.get('controller_fallback_steps')==0 for x in tests))
def candidate_entry(receipt_path):
 r=read(receipt_path);directory=receipt_path.parent;actor=directory/'actor.json'
 native=sorted(directory.glob('native_validation_*.json'))
 verified=[]
 for p in native:
  n=read(p)
  realism=n.get('realism',{});debrief=realism.get('debrief',{})
  hydro=read(ROOT/'data/ports/default_port_profile.json')['scenarios'][r['scenario']].get('realism',{}).get('hydrodynamics',{})
  bank=debrief.get('minimum_bank_clearance_m');ukc=debrief.get('minimum_ukc_m')
  hydro_passed=(bank is None or bank>=hydro.get('minimum_bank_clearance_m',0)) and (ukc is None or ukc>=hydro.get('minimum_ukc_m',0))
  traffic_valid=not r.get('config',{}).get('traffic_policy_path') or (n.get('traffic_policy_required') and n.get('traffic_policy_verified'))
  if actor.is_file() and n.get('passed') and traffic_valid and native_sources_match(n) and hydro_passed and n.get('initial_spawn_error_m',999)<1 and n.get('inference_golden_max_error',999)<1e-5 and n.get('actor_sha256')==sha(actor) and n.get('controller_fallback_steps')==0 and n.get('trajectory_teleporting') is False:
   verified.append(p)
 test_path=directory/'test_results.json'
 tests=read(test_path) if test_path.exists() else []
 exact_test_set=sorted(row.get('seed') for row in tests)==sorted(r.get('test_seeds',[])) and len(tests)>=20
 valid_test=exact_test_set and all(row.get('success') and all(row.get('gates',{}).values()) and row.get('collisions')==0 and row.get('controller_fallback_steps')==0 for row in tests)
 valid_sources=source_ok(r)
 live=bool(r.get('admitted') and int(r.get('actor_critic_updates',0))>0 and verified and valid_test and valid_sources and traffic_policy_qualified(r.get('config',{})))
 model_path=ROOT/r['model_path'] if 'model_path' in r else directory/r.get('frozen_model','')
 expected=r.get('model_sha256',r.get('frozen_model_sha256',''))
 live=live and model_path.is_file() and sha(model_path)==expected
 entry={'strategy_id':r.get('strategy_id'),'status':r.get('status'),'timesteps':r.get('timesteps'),
  'actor_critic_updates':r.get('actor_critic_updates'),'numeric_admitted':bool(r.get('admitted')),
  'native_runtime_verified':bool(verified),'source_hashes_match':valid_sources,'live_switch_admitted':live,
  'receipt_path':str(receipt_path.relative_to(ROOT)),'native_receipts':[str(p.relative_to(ROOT)) for p in verified],
  'status_zh':'强化学习已通过数值与原生验收，可按场景切换' if live else ('数值任务验证通过，原生接管尚未准入' if r.get('admitted') else '强化学习候选仍未通过完整任务验收')}
 if live:
  deployment=ROOT/'data/rl/mission_rl_deployments_v1'/f"{directory.name}.json"
  actor_data=read(actor)
  actor_data.update(live_switch_admitted=True,native_runtime_verified=True,qualified_actor_sha256=sha(actor),native_receipts=entry['native_receipts'],
      native_runtime_sources=read(verified[-1])['native_runtime_sources'])
  write(deployment,actor_data);entry['actor_path']='res://'+str(deployment.relative_to(ROOT));entry['actor_sha256']=sha(deployment)
  entry['test_summary']={'episodes':len(tests),'success_rate':sum(x['success'] for x in tests)/len(tests),'collisions':sum(x['collisions'] for x in tests),
    'mean_duration_seconds':sum(x['duration_seconds'] for x in tests)/len(tests),'minimum_clearance_m':min(x['minimum_clearance_m'] for x in tests),
    'minimum_separation_m':min(x['minimum_separation_m'] for x in tests if x['minimum_separation_m'] is not None) if any(x['minimum_separation_m'] is not None for x in tests) else None}
 return entry

def main():
 profile=read(ROOT/'data/ports/default_port_profile.json')
 entries={k:{'name':profile['scenarios'][k]['name'],'status':'UNTRAINED','status_zh':'尚无通过完整任务验收的场景强化学习策略','live_switch_admitted':False} for k in SCENARIOS}
 attempts=[]
 for p in sorted(ARTIFACTS.glob('*/receipt.json'),key=lambda p:p.stat().st_mtime):
  r=read(p)
  if r.get('scenario') not in SCENARIOS:continue
  e=candidate_entry(p);attempts.append(e)
  key=r.get('scenario')
  if key in entries:
   rank=lambda x:(bool(x.get('live_switch_admitted')),bool(x.get('numeric_admitted')))
   if rank(e)>=rank(entries[key]):entries[key]={**entries[key],**e}
 for p in ARTIFACTS.glob('*/progress.json'):
  if (p.parent/'receipt.json').exists() or (p.parent/'interruption_receipt.json').exists():continue
  if not (p.parent/'manifest.json').exists():continue
  r=read(p);m=read(p.parent/'manifest.json');key=m.get('scenario')
  if key in entries and not entries[key].get('numeric_admitted'):
   entries[key].update(status='TRAINING',status_zh=f"强化学习训练中：{r.get('timesteps',0):,} 步；尚未准入",progress_path=str(p.relative_to(ROOT)))
 modules=[]
 for filename in ['navigation_benchmark_v1.json','port_ops_benchmark_v2.json']:
  p=ROOT/'reports'/filename;report=read(p)
  for row in report['test_results']:
   if row['algorithm'] not in ('ppo','sac','td3','dqn','a2c','ddpg','trpo'):continue
   m=row['metrics'];modules.append({'module':filename,'algorithm':row['algorithm'],'held_out_episodes':row['episodes'],
     'success_rate':m.get('collision_free_arrival_rate',m.get('safe_completion_rate',m.get('success_rate'))),'collision_rate':m['collision_episode_rate'],
     'port_compliant_completion_rate':m.get('port_compliant_completion_rate'),'source':str(p.relative_to(ROOT))})
 cargo=read(ROOT/'reports/cargo_circuit_public_evidence_v1.json')['held_out_results']
 audit={'schema_version':'mission_rl_coverage_audit_v1','generated_at':datetime.now(timezone.utc).isoformat(),
   'scenarios':entries,'candidate_receipts':attempts,'existing_rl_benchmarks':modules,'frozen_cargo_results':cargo,
   'p47_previous':{'status':'NO_SAC_UPDATES','latest_preserved_attempt':13,'source':'reports/cargo_circuit_physics_difficulty_ladder_attempt_13.md',
     'reason':'Complete expert initialization did not produce a successful pure neural policy; interrupted before SAC actor/critic updates.'},
   'p47_current':[{'path':str(p.relative_to(ROOT)),**read(p)} for p in ARTIFACTS.glob('p47_*/receipt.json')],
   'traffic_rl':[{'path':str(p.relative_to(ROOT)),**read(p)} for p in ARTIFACTS.glob('traffic_lane_*/receipt.json')],
   'untrained_modules':[{'module':'410-cell cross-port and OOD generalization campaign','reason':'evaluation specification exists, no complete training campaign'},
      {'module':'tug/anchor/mooring/thruster procedural training','reason':'No force-bearing environment, action-transition-reward contract or learned model; procedural UI completion cannot establish RL training.'}],
   'business_metrics':['complete mission success','collision count','minimum passing distance','bank and under-keel clearance','berthing pose/speed/sway','completion time','actuator effort proxy'],
   'production_authority':False,'live_data_verified':False,'simulation_mode':True}
 write(ROOT/'reports/mission_rl_coverage_audit_v1.json',audit)
 write(ROOT/'data/rl/mission_rl_catalog_v1.json',{'schema_version':'mission_rl_catalog_v1','scenarios':entries,'production_authority':False})
 print(json.dumps({'admitted':[k for k,v in entries.items() if v['live_switch_admitted']],'candidates':len(attempts)},ensure_ascii=False))
if __name__=='__main__':main()
