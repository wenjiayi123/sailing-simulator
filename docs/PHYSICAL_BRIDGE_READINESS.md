# 物理驾驶台、硬件在环与标准准入

更新时间：2026-08-28

## 已补齐的可执行运行时

- `PhysicalHilRuntime` 位于现有船舶运动模型和执行器 I/O 之间，只接收候选指令，不加载、训练或改写强化学习策略。
- 9 状态安全状态机覆盖安全中性、已武装、掉线、恢复等待、时钟/传感时间异常、最坏执行时间超期、人工优先、输入异常和急停锁存。
- 目标控制器 UDP 适配器使用现有 SHA-256 帧合同、序号和单调时间戳；非回环目标必须显式启用物理输入输出。
- 每周期检查传感数据时效、控制器时钟偏差、执行期限、序号、有限数值和命令限幅。任一失败立即输出中性油门和中性舵令。
- 掉线恢复必须达到连续健康帧数量，并同时进行人工确认和钥匙确认；恢复后仍处于安全中性状态，不会自动重新武装。
- 双通道急停采用任一通道动作即锁存；两通道都恢复、人工确认和钥匙确认全部满足后才能复位。
- 功能烟测采集至少 1000 个实际执行时间样本，并注入掉线、时钟漂移、执行超期、人工接管、重放和双通道急停故障。
- 每个状态变化和输出都进入 SHA-256 链式回执，可检测事后修改。

运行时配置位于 `data/verification/physical_hil_runtime_profile_v1.json`，功能报告位于 `reports/physical_hil_runtime_functional_smoke_v1.json`。当前烟测只使用台架功能输入，不是物理 HIL。

## 物理设备与见证证据门禁

- 15 类硬件角色：舵轮、车钟、双通道急停、人工接管、全球导航卫星系统、首向、计程仪、舵角/油门反馈、驾驶台显示、目标控制器、真实输入输出机架、安全继电器和时钟源。
- 15 类输入输出通道：位置、首向、航速、舵令/反馈、油门令/反馈、双通道急停、复位钥匙、人工接管、看门狗、控制器/机架健康和时钟同步。
- 12 类独立安全联锁：原有独立急停、人工优先、掉电中性化、独立看门狗、网络隔离与风险审查，并增加双通道独立性、控制器期限监视、反馈不一致跳闸和人工恢复。
- 时序证据：至少 1000 个样本，传感与命令 P95 延迟、最大抖动、看门狗动作时间、时钟同步和最坏情况执行时间引用。
- 12 个必须见证的物理试验：正常闭环、时钟偏移、执行超期、传感/命令链路掉线、输入输出机架掉电、控制器重启、人工接管、急停 A、急停 B、双通道复位和反馈不一致。
- 现场证据：安装、网络、电源/不间断电源、传感器/执行器校准、物理 HIL 原始日志及 SHA-256、故障注入、独立见证和签字验收。

证据清单位于 `data/verification/physical_bridge_hil_manifest.template.json`，见证记录模板位于 `data/verification/physical_hil_witnessed_test_csv_template.csv`。Godot 的 U 面板可以原样导出这三份现场文件。

## 标准追踪

`data/verification/simulator_standards_mapping_v1.json` 路由 13 项要求/主题，包括 STCW Code A-I/12 的训练目标、设备能力与错误、行为真实度、环境、交互、教员控制/记录/复盘、雷达和自动雷达标绘，以及 DNV-ST-0033 2025 版的真实度、安装与认证主题。

该映射只用于证据追踪和缺口分派，不是条款解释、主管机关批准、DNV 评估、符合性声明或产品认证。映射明确保留当前未实现的两套可独立操纵本船站、20 目标训练、完整雷达真运动/传播效应、指定船舶真实度验证等缺口。

## 强制拒绝边界

即使现场把所有引用填写完整，软件最多返回 `READY_FOR_WITNESSED_EXTERNAL_ASSESSMENT`，仍保持：

- `physical_hil_verified=false`
- `site_delivery_ready=false`
- `stcw_approved=false`
- `dnv_certified=false`
- `production_authority=false`

外部硬件、人员、见证、签名、校准记录和主管机关/船级结论必须由有权限的独立方鉴定。清单中的自报授权布尔值反而会使证据包保持阻断。

`physical_hil_runtime_functional_smoke_v1.json` 中的通过只证明状态机、故障注入、限幅、回执和模板导出可以运行。因为没有连接目标控制器、真实输入输出机架、实时操作系统和独立急停接线，其字段必须保持：`target_controller_connected=false`、`real_io_connected=false`、`rtos_verified=false`、`physical_hil_verified=false`。

## 复现

```bash
make physical-bridge-readiness-verify
make physical-hil-runtime-smoke-verify
make GODOT="/Applications/Godot.app/Contents/MacOS/Godot" godot-physical-bridge-readiness-smoke
.venv/bin/python -m unittest tests.test_physical_bridge_readiness -v
.venv/bin/python -m unittest tests.test_physical_hil_runtime -v
```
