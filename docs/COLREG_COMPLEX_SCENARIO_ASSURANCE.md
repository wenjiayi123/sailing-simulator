# 复杂避碰规则场景保障 V2

本模块面向强化学习航行模拟器的场景生成、策略评测和教员复盘，不改变任何既有策略，也不改变船舶运动模型。原有 V1 双船判定器和 6 个场景、11 个正反动作案例继续作为回归基线；V2 只增加复杂场景责任与信号验收层。

## 已实现功能

- 多船责任图：对每个目标分别保存会遇、责任、最近会遇距离、到达最近会遇点时间和规则追踪，并按船舶身份与时间风险选择优先目标；不会把三船会遇压成一个匿名告警。
- 狭水道：核对靠近右舷外缘、横越不妨碍、追越明确协调，以及动作后的水域状态。
- 分道通航制：核对顺交通流、避免进入分隔带，以及近直角横越。
- 特殊船舶身份：覆盖操纵能力受到限制的船舶、失去控制的船舶和从事捕鱼的船舶，并把身份优先关系与规则 18 责任写入逐目标证据。
- 灯号号型：核对失去控制、操纵能力受到限制、非拖网捕鱼和拖网捕鱼的灯号/号型组合。
- 能见度不良：区分目标在正横以前或正横以后，检查安全航速、明显行动和向左转向限制；同时核对在航机动船与失去控制船的声号模式及不超过 120 秒的间隔。
- 地方规则：提供版本化仿真港区规则模板，检查限速、禁止追越和报告要求；模板始终标记为非官方来源。

## 场景与证据

- V1 基线：[`data/verification/colreg_encounter_catalog_v1.json`](../data/verification/colreg_encounter_catalog_v1.json)
- V2 场景：[`data/verification/colreg_complex_scenario_catalog_v2.json`](../data/verification/colreg_complex_scenario_catalog_v2.json)
- 地方规则模板：[`data/verification/local_navigation_rules_template_v1.json`](../data/verification/local_navigation_rules_template_v1.json)
- 规则引擎：[`tools/ship_assurance/colreg_complex.py`](../tools/ship_assurance/colreg_complex.py)
- 机器报告：[`reports/colreg_complex_assurance_v2.json`](../reports/colreg_complex_assurance_v2.json)
- 人读报告：[`reports/colreg_complex_assurance_v2.md`](../reports/colreg_complex_assurance_v2.md)
- Godot 专项验收：[`reports/godot_colreg_complex_smoke_v1.json`](../reports/godot_colreg_complex_smoke_v1.json)

当前冻结目录包含 16 个复杂场景和 45 个正反动作/信号案例，要求十类能力全部覆盖并逐项匹配。界面按 `R` 可打开，也可从系统总览进入；教员可浏览逐目标责任图、规则、水域约束、身份信号和案例判定，并导出带 SHA-256 的场景证据包。

## 对强化学习的接法

V2 复杂规则层是独立判定和评测接口，不接管策略动作。后续统一训练时，可把场景目录转换为环境初始化分布，把逐目标责任、规则约束和动作结果写入 episode 轨迹及评分；是否作为奖励项、约束项或仅作独立评测，应由新实验版本明确声明。现有策略 checkpoint、旧训练报告和旧观测/动作合同均不改写。

## 边界

场景引擎是确定性的工程验证器，不是完整法律推理。地方规则模板的 `source_class=SIMULATOR_AUTHORED_EXERCISE_RULES`、`official_authorization_verified=false`；在接入主管机关授权、带生效时间和适用水域的正式规则源前，不得声称地方规则合规。场景通过也不构成《国际海上避碰规则》认证、船级/型式认可、值班人员替代或实船控制授权。

## 复现

```bash
.venv/bin/python tools/run_colreg_complex_assurance.py verify
.venv/bin/python -m unittest tests.test_colreg_complex -v
make GODOT="/Applications/Godot.app/Contents/MacOS/Godot" godot-colreg-complex-smoke
```
