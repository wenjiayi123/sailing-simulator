# 动力学、COLREG、HIL 与海试保障指南 / Dynamics, COLREG, HIL and Sea-Trial Assurance

## 结论 / Outcome

项目现在具备四条可执行、可重复核验的保障链：

1. 三自由度 surge–sway–yaw 船舶模型：附加质量、线性/二次阻尼、推进器与舵机一阶动态、执行器速率/幅值限制、风浪外力、流致对地漂移和 RK4 数值积分。
2. COLREG 会遇判定与动作回归：CPA/TCPA、相对方位、目标船舷角、能见度、追越/对遇/交叉/能见度不良、让路/直航责任、规则编号和正反动作案例。
3. HIL 准备层：UDP JSON 完整性帧、NMEA 0183 校验、单调序号/时效/范围/斜率门禁、watchdog 中性失效状态、故障注入和哈希回执链。
4. 海试保障层：逐级试验协议、遥测 CSV 合同、量化验收判据，以及没有物理 HIL、许可、标定、见证、原始日志和签字记录时拒绝宣称“完成海试”的证据完整性门禁。

The project now has four executable assurance chains: a calibratable 3-DOF plant, traceable COLREG encounter/action regression, HIL protocol/loopback/fault injection, and a progressive sea-trial protocol with an anti-fabrication evidence gate.

## 证据分层 / Evidence layers

| 层级 / Layer | 当前可完成 / Available now | 当前状态 / Current status |
|---|---|---:|
| 软件模型 / Software plant | 数学模型、数值稳定性、确定性、阻尼、舵向对称、执行器边界 | VERIFIED |
| 规则回归 / Rule regression | 6 类场景、规则追踪、11 个正反动作案例 | VERIFIED |
| 软件回环 / Software loopback | UDP/NMEA、完整性、重放/过期/损坏/丢包/越界故障 | VERIFIED |
| 指定船舶标定 / Named-vessel calibration | 需要指定船舶辨识数据 | NOT VERIFIED |
| 物理 HIL / Physical HIL | 需要目标控制器、真实 I/O 或认证植物模拟器、独立急停 | NOT VERIFIED |
| 实船海试 / Real-vessel sea trial | 需要船舶、许可、船长/操作员、见证、标定、原始日志和签字 | NOT COMPLETED |
| 生产授权 / Production authority | 需要主管机关/船级/运营方完整批准 | DISABLED |

历史 V1/V2/V3 RL checkpoint、指标和报告没有被重新标记或覆盖。新增模型用于下一版本校准与验证；在重新训练和冻结新实验之前，旧模型继续绑定旧动力学指纹。

Historic V1/V2/V3 RL checkpoints and metrics are not relabelled or overwritten. The new plant is a next-version calibration/verification contract; existing models remain bound to their original dynamics fingerprint until a new experiment is trained and sealed.

## 1. 动力学 / Dynamics

实现：[`tools/ship_assurance/dynamics.py`](../tools/ship_assurance/dynamics.py) 与 [`tools/ship_assurance/environment.py`](../tools/ship_assurance/environment.py)

参考参数：[`data/verification/vessel_dynamics_reference_v1.json`](../data/verification/vessel_dynamics_reference_v1.json)

坐标约定：位置为 east/north 米；航向从真北顺时针；船体坐标为 surge 向前、sway 向右舷、正 yaw 向右舷。动力方程包含惯性/附加质量耦合、非线性阻尼、螺旋桨推力、舵升力/阻力和外部力矩。执行器具有一阶滞后、速率限制和物理角度/指令限幅。

软件验收包括：

- 相同初值/指令的逐值确定性；
- 零推力下动能代理衰减；
- 左右舵转艏方向与对称性；
- 油门、舵角和舵速边界；
- 有限值检查和积分子步收敛；
- 一阶 Nomoto `T r_dot + r = K delta` 时间序列辨识接口。

`AssuredPortOpsEnv` 已把该 plant 接入下一版本港口环境：动作真实经过桨/舵执行器与 3-DOF 状态转移，COLREG 判定写入逐步轨迹；在原 45 维港口观测上新增 sway、yaw rate 和实舵角，形成独立 48 维合同。它与历史 checkpoint 明确不兼容，必须在指定船舶参数冻结后重新训练、validation 和 sealed test，不能把旧模型改名后沿用。

参考参数是通用排水型船舶参数，不是特定船舶辨识结果。指定船舶必须提交装载状态、主机/轴转速/推力、舵令/实舵角、GNSS/INS/ROT、风流估计，以及 zig-zag、回转圈、加速和停船数据；辨识结果必须另存版本并重新训练/测试，不得改写旧报告。

## 2. COLREG

实现：[`tools/ship_assurance/colreg.py`](../tools/ship_assurance/colreg.py)

场景：[`data/verification/colreg_encounter_catalog_v1.json`](../data/verification/colreg_encounter_catalog_v1.json)

每次判定输出 encounter、own-ship role、risk-of-collision、相对方位、目标舷角、range、TCPA、DCPA、适用规则和可读原因。当前场景覆盖：

- Rule 14 对遇；
- Rules 15/16 右舷交叉让路；
- Rules 15/17 左舷交叉直航；
- Rule 13 追越；
- Rule 19 能见度不良；
- Rule 7 当前未形成碰撞危险的监视案例；
- Rules 5/6/7/8 的共同瞭望、安全航速、危险判断和早期明显行动追踪。

每类危险会遇同时包含应通过和应拒绝的动作案例，避免只验证“正确答案”。这仍不是完整法规推理：船舶操纵受限/失控/吃水受限/捕鱼/帆船优先关系、狭水道、分道通航、多船博弈、地方规则、灯号声号和法律解释还需要专门场景与主管机关审查。

## 3. HIL

实现：[`tools/ship_assurance/hil.py`](../tools/ship_assurance/hil.py)

配置：[`data/verification/hil_loopback_profile_v1.json`](../data/verification/hil_loopback_profile_v1.json)

软件 HIL 准备层提供：

- 只在 localhost 默认启用的 UDP 端点；
- 版本、session、sequence、monotonic timestamp、payload 和 SHA-256 完整性帧；
- 带 XOR checksum 的 NMEA 0183 `PXIYT` 遥测句；
- 损坏、重放/乱序、过期/未来、越界和错误类型拒绝；
- 油门/舵令限幅与 slew-rate 限制；
- 超时后强制 `FAIL_SAFE_NEUTRAL`；
- drop、corrupt、replay、stale、out-of-range、未授权 session change 故障注入，以及 watchdog 后人工授权 session restart；
- 命令回执哈希链。

`software_loopback_verified=true` 不能写成 `physical_hardware_verified=true`。物理 HIL 还必须接入目标控制器/RTOS、真实 GNSS/INS/AIS/雷达或获批传感接口、真实操舵/推进 I/O 或认证植物模拟器、独立急停/手动优先权、时钟同步和 WCET 证据，并完成见证故障/恢复测试。

## 4. 海试 / Sea trial

实现：[`tools/ship_assurance/sea_trial.py`](../tools/ship_assurance/sea_trial.py)

协议：[`data/verification/sea_trial_protocol_v1.json`](../data/verification/sea_trial_protocol_v1.json)

证据清单模板：[`data/verification/sea_trial_evidence_manifest.template.json`](../data/verification/sea_trial_evidence_manifest.template.json)

协议要求按“文件/风险审查 → 码头检查 → shadow mode → 受监督低速保护水域 → 有界会遇与降级模式”逐级扩大包线。默认中止条件包括定位/航向完整性丢失、watchdog/指令反馈不一致、人工接管/急停、越出地理/速度/天气包线、CPA/TCPA 阈值失守、非计划交通或值班人员判断。

遥测合同至少包含：时间戳、航向、速度、横向误差、DCPA、指令延迟、GNSS 有效性、人工接管和急停事件。当前默认量化判据是 300 秒以上、GNSS 有效率 ≥99.5%、P95 XTE ≤15 m、最小 DCPA ≥100 m、P95 指令延迟 ≤100 ms，并必须观察到人工接管和急停。

即使一份仿真轨迹满足所有数值判据，门禁也保持 `BLOCKED_NO_REAL_VESSEL_EVIDENCE`。同时具备 `execution_context=real_vessel`、原始日志 SHA-256、指定船舶/海域、许可、船长或操作员、独立见证、传感器/执行器标定、风险评估、物理 HIL 和签字试验记录后，软件只会给出 `READY_FOR_EXTERNAL_REVIEW`；因为它无法鉴定外部材料真伪，仍保持 `sea_trial_completed=false`，最终结论由有权限的外部审查方签发。

软件只能检查清单完整性、原始日志哈希和遥测指标，不能鉴定许可证、人员身份、签名、标定报告或见证独立性；这些材料仍须外部人工审查。填好清单后可运行：

```bash
.venv/bin/python tools/evaluate_sea_trial.py \
  --manifest /absolute/path/to/evidence_manifest.json \
  --telemetry /absolute/path/to/immutable_trial_telemetry.csv \
  --output /absolute/path/to/sea_trial_evaluation.json
```

## 运行 / Run

```bash
# 重新生成版本化报告
.venv/bin/python tools/run_maritime_assurance.py generate

# 确定性复算并核对已保存报告
.venv/bin/python tools/run_maritime_assurance.py verify

# 模块级测试
.venv/bin/python -m unittest tests.test_maritime_assurance -v
```

机器可读结果见 [`reports/maritime_assurance_v1.json`](../reports/maritime_assurance_v1.json)，摘要见 [`reports/maritime_assurance_v1.md`](../reports/maritime_assurance_v1.md)。
