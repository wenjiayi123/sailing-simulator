#!/usr/bin/env python3
"""Generate human-readable evidence and unsmoothed validation curves from receipts."""
import json
from pathlib import Path
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from audit_mission_rl import ROOT,ARTIFACTS,read

LABELS={'open_water':'Open water','harbor':'Harbor pilotage','auto_berthing':'Berthing','auto_unberthing':'Unberthing',
        'narrow_channel_head_on':'Head-on','crossing_starboard':'Crossing','narrow_channel_overtaking':'Overtaking'}

def main():
 audit=read(ROOT/'reports/mission_rl_coverage_audit_v1.json')
 lines=['# 场景强化学习本轮验收结果','',
 '本报告由实际训练、模型冻结、独立测试和 Godot 原生闭环回执生成。所有接管动作来自 SAC 神经网络；不使用专家演示、传统控制器动作兜底或轨迹搬移。原有模型和失败实验均保留。','',
 '| 场景 | 数值独立测试 | 原生闭环与切换准入 | 平均完成时间 | 最小静态/动态净距 | 最小船间中心距 |',
 '|---|---:|---|---:|---:|---:|']
 for key,row in audit['scenarios'].items():
  s=row.get('test_summary',{});n=s.get('episodes',0)
  lines.append('| '+ ' | '.join([row['name'],f'{n}/{n}' if n else '未通过准入',
   '通过' if row.get('live_switch_admitted') else row.get('status','UNTRAINED'),
   f"{s['mean_duration_seconds']:.1f} 秒" if n else '—',f"{s['minimum_clearance_m']:.2f} 米" if n else '—',
   f"{s['minimum_separation_m']:.2f} 米" if s.get('minimum_separation_m') is not None else '不适用'])+' |')
 lines+=['','净距采用训练环境中半径 3.2 米的本船保守碰撞包络；船间中心距是另一项独立会遇指标。独立测试为各场景 20 个未参与训练与模型选择的种子：完整原始起点，位置 ±1 米、船首向 ±4 度、风浪流幅值 ±10%。模型选择使用另外八个验证种子，种子 0 仅用于标称诊断。','',
 '## 业务意义','',
 '1. 靠泊以船位、船首向、航速和横荡同时达标并保持三秒为终点，能评估低速稳船能力。离泊另查离开泊位距离和出口航速。','2. 对遇与交叉分别考察足够早的右转、右侧航道保持或从目标船船尾通过，并统计最小船间距离。','3. 接管入口统一在 N 航行任务面板；应用任务后启用场景强化学习，后续切换已准入场景会匹配对应网络。无合格网络或合同不匹配时不会接管。','4. 网络权重、训练代码、动力学与场景来源、独立测试和原生执行版本相互绑定；原生验证必须实际运行当前代码，不能只重新生成哈希来沿用旧结果。','',
 '## 仍未解决的范围','',
 '未准入候选的完整失败轨迹、训练进度与验证记录保存在各独立实验目录。训练回合成功率可能包含课程起点，不能代替从完整起点开始的验证成功率。', '']
 overtaking=audit['scenarios']['narrow_channel_overtaking']
 if not overtaking.get('live_switch_admitted') and overtaking.get('receipt_path'):
  r=read(ROOT/overtaking['receipt_path'])
  lines.append(f"- 完整追越仍未收敛：最后候选累计 {r.get('timesteps',0):,} 步，本次新增 {r.get('this_run_timesteps',0):,} 步（包含训练策略采样的回放预热）。最后三个完整起点验证回合全部失败：虽走完五个航点并保持本船安全净距，仍未在目标船抵达地图边界前完成驶过。正式 20 回合测试未启动，策略未准入。")
 for p in sorted(ARTIFACTS.glob('p47_*/receipt.json')):
  r=read(p);g=r.get('gate',{})
  lines.append(f"- 47 维 {p.parent.name}：{r['timesteps']:,} 步、{r['actor_critic_updates']:,} 次演员/评论家更新；最低难度验证 {g.get('success_rate',0):.1%} 成功、{g.get('total_collisions',0)} 次碰撞。状态 {r['status']}，未晋级，未访问正式测试集，未替换原有策略。")
 traffic=ARTIFACTS/'traffic_lane_attempt_02/receipt.json'
 if traffic.exists():
  r=read(traffic);tests=read(traffic.parent/'test_results.json');native=traffic.parent/'native_traffic_validation_03.json'
  lines+=['',f"目标慢船另有独立的 10 维 SAC 航道保持策略：{r['timesteps']:,} 步训练，20 个独立测试中 {sum(x['success'] for x in tests)}/20 成功，最大航道偏差 {max(x['max_cross_track_m'] for x in tests):.2f} 米；90 秒 Godot 原生验证状态为 {('PASS' if read(native).get('passed') else 'FAIL') if native.exists() else '待完成'}。这一结果不代替本船的完整追越验收。",'']
 lines+=['- 旧 45 维长滩港多算法基准主要属于短训练，原有不合格结果仍然有效；本轮场景策略不改变该基准的结论。',
 '- 跨港与分布外 410 单元泛化计划尚未完成训练；拖轮、锚泊、系泊和侧推程序模块缺少经过验证的受力转移环境，仍不能列为已训练强化学习能力。','',
 '## 证据边界','',
 '这是同一场景几何、单次训练种子、小范围扰动下的仿真任务验收，不能推出跨港泛化、实船收敛或现场部署安全。原生验收验证的是自主运动任务，人工任务前检查和培训资质评分单独记录；动作任务通过不代表所有程序训练步骤完成。动作量只是能耗代理，没有燃料或电池标定，未宣称节省费用。',
 '', '`simulation_mode=true`、`live_data_verified=false`、`production_authority=false`。公开版本提供离线仿真代码与证据，不代表外部系统部署。','',
 '## 复现入口','', '环境：项目 `.venv`，依赖见 `requirements-rl.txt`；训练使用 Stable-Baselines3 SAC，真实在线环境交互。编译物理加速器需要本机 C 编译器。','',
 '```bash','.venv/bin/python -m unittest tests.test_mission_rl -v',
 '.venv/bin/python tools/audit_mission_rl.py',
 '.venv/bin/python tools/report_mission_rl.py',
 '# 新实验输出目录必须不存在，避免覆盖历史证据',
 '.venv/bin/python tools/train_mission_rl.py --scenario auto_berthing --output reports/artifacts/mission_rl_v1/NEW_ATTEMPT --steps 300000',
 '```','',
 '原生闭环：Godot 执行 `tools/godot_mission_rl_validation.gd`，传入 `--mission-rl-validation`、`--actor=res://.../actor.json` 和独立 `--output=res://.../native_validation_XX.json`；同目录需有 `inference_golden.json`。`tools/godot_mission_rl_switch_smoke.gd` 检查起点、目标船碰撞恢复、合格策略启用与自动换网。','',
 '## 每次实验','', '| 实验 | 场景 | 累计模型步数 | 本次新增步数 | 状态 |', '|---|---|---:|---:|---|']
 for directory in sorted(p for p in ARTIFACTS.iterdir() if p.is_dir()):
  p=directory/'manifest.json';receipt=directory/'receipt.json';interrupted=directory/'interruption_receipt.json';progress=directory/'progress.json'
  if not (p.exists() or receipt.exists() or interrupted.exists()):continue
  manifest=read(p) if p.exists() else (read(receipt) if receipt.exists() else read(interrupted))
  r=read(receipt) if receipt.exists() else (read(interrupted) if interrupted.exists() else (read(progress) if progress.exists() else {}))
  link=p if p.exists() else (receipt if receipt.exists() else interrupted)
  role=manifest.get('scenario','P47-L1' if manifest.get('level') else manifest.get('role','训练探索或中断记录'))
  lines.append(f"| [{directory.name}]({link.relative_to(ROOT).as_posix()}) | {role} | {r.get('timesteps',r.get('checkpoint_timesteps','—'))} | {r.get('this_run_timesteps','见父模型及回执')} | {r.get('status','TRAINING')} |")
 # Links in report are rooted one directory above artifacts.
 content='\n'.join(lines)+'\n';content=content.replace('](reports/artifacts/','](artifacts/')
 (ROOT/'reports/mission_rl_remediation_results_v1.md').write_text(content)
 fig,axes=plt.subplots(2,4,figsize=(16,8),sharey=True);colors=plt.get_cmap('tab10')
 for ax,(key,name) in zip(axes.flat,LABELS.items()):
  count=0
  for p in sorted(ARTIFACTS.glob('*/validation_history.json')):
   m=read(p.parent/'manifest.json')
   if m.get('scenario')!=key:continue
   history=read(p);xx=[h['timesteps']/1000 for h in history];yy=[sum(r['success'] for r in h['episodes'])/len(h['episodes']) for h in history]
   ax.plot(xx,yy,'o',markersize=4,linestyle='None',label=p.parent.name,color=colors(count%10));count+=1
  ax.set(title=name,xlabel='Model steps (thousands)',ylim=(-.05,1.05));ax.grid(alpha=.2)
  if count:ax.legend(fontsize=5.5,loc='best')
  else:ax.text(.5,.5,'Frozen checkpoint qualification\nSee 20 held-out test episodes',ha='center',va='center',transform=ax.transAxes,fontsize=9)
 axes.flat[-1].axis('off');axes.flat[-1].text(.05,.8,'Actual validation checkpoints\nNo interpolation or smoothing\n\nFull-spawn missions, 3 diagnostic seeds\nCurriculum training success is not plotted\n\nDifferent attempts retain their failures\nParent steps are cumulative',va='top',fontsize=10)
 axes[0,0].set_ylabel('Full mission validation success');axes[1,0].set_ylabel('Full mission validation success')
 fig.suptitle('Direct SAC scene training: observed validation outcomes',fontsize=15);fig.tight_layout()
 fig.savefig(ROOT/'reports/artifacts/mission_rl_v1/validation_curves.png',dpi=160);plt.close(fig)
 print('Wrote mission RL report and measured validation curves.')
if __name__=='__main__':main()
