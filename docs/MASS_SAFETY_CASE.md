# RL 航行模拟器法规与安全案例 V1

更新时间：2026-08-28

## 定位

本安全案例服务于强化学习航行模拟器的训练、评估、教员演练和证据准备。它把安全主张、运行设计域、危险、控制措施、证据、最小风险状态、故障树、人员责任和外部审查连接为机器可读闭环。

它不改变船舶三自由度运动模型，不加载或改写现有策略，也不授予实船控制权限。

## 已实现内容

- 12 个运行设计域维度：场景授权、富余水深、风、浪、能见度、交通复杂度、全球卫星导航系统完整性、多源融合质量、执行器反馈、远程控制中心链路、网络完整性和航速包络。
- 运行设计域在线检查器：正常输入保持 `within_odd=true`；任一维度缺失或越界都会给出具体越界维度和最小风险状态编号，永远不直接授予生产控制权。
- 12 类危险：碰撞、搁浅、导航完整性丧失、操舵故障、推进故障、电源故障、通信中断、传感欺骗、网络攻击、火灾/进水、人因和不安全强化学习输出。
- 24 项预防、探测或缓解控制；每项控制绑定已有测试证据。
- 6 种最小风险状态：人工立即接管、受控减速停止、降速保持并请求接管、授权远程接管、紧急中性锁存和安全待命区保持。
- 5 棵故障树：碰撞、搁浅、失控、不安全自主动作、人因/事故响应；检查器验证节点引用、控制引用、危险覆盖和无环结构。
- 远程控制中心设计合同：人员配置、主备链路、交接复诵、值班、掉线响应和同步记录要求。当前 `site_authorized=false`。
- 9 个责任角色和7项RACI职责，确保每项关键安全活动都有明确执行者和唯一责任承担者。
- 5类法规/合规适用性路由：国际海上避碰规则、海上人命安全公约、海员培训/发证和值班标准、船旗国/沿海国要求、船级与独立保障要求。项目只分配证据路径，不自行作法律适用性或符合性结论。
- 10项证据注册表，所有当前输入文件均计算SHA-256并纳入安全案例报告。
- 外部接受清单覆盖指定船舶、运行海域、批准运行设计域、责任人员、主管机关决定、独立审查、剩余风险接受、物理硬件在环、指定船舶标定、海试和网络安全评估。

## Godot 操作

按 `Q` 打开“法规与安全论证”面板，也可从系统总览进入。面板支持：

- 浏览12项危险及其控制、风险所有者和最小风险状态；
- 浏览6种最小风险状态及触发、动作、完成标准、超时和回退；
- 浏览安全主张和证据；
- 逐项演示运行设计域越界到最小风险状态的路由；
- 浏览外部证据缺口；
- 重新运行真实安全案例检查器；
- 导出安全案例、接受清单和当前评估报告。

运行设计域演示只展示安全路由，不向船舶或执行器下发指令。

## 证据文件

- 安全案例：`data/verification/mass_safety_case_v1.json`
- 外部接受模板：`data/verification/mass_safety_case_acceptance_manifest.template.json`
- 检查器：`tools/ship_assurance/safety_case.py`
- 评估报告：`reports/mass_safety_case_assessment_v1.json`
- Godot验收：`reports/godot_safety_case_smoke_v1.json`

## 外部准入边界

当前项目可以证明安全案例结构、内部引用、运行设计域越界路由和拒绝门禁能够执行，但不能鉴定外部人员、签名、法规决定、剩余风险接受或现场证据的真伪。

即使外部材料填写完整，软件最多返回 `READY_FOR_INDEPENDENT_SAFETY_CASE_DECISION`，仍不会自行改变：

- `independent_review_complete=false`
- `flag_state_approval=false`
- `coastal_state_approval=false`
- `class_approval=false`
- `type_approval=false`
- `mass_safety_certificate=false`
- `sea_trial_completed=false`
- `production_authority=false`

## 复现

```bash
make mass-safety-case-verify
make GODOT="/Applications/Godot.app/Contents/MacOS/Godot" godot-safety-case-smoke
.venv/bin/python -m unittest tests.test_mass_safety_case -v
```
