# 航行模拟器按钮与流程验收清单

更新时间：2026-08-25

## 验收结论

- 运行时共发现 117 个可交互控件，覆盖 9 个业务面板及 H 总控返回层。
- 实际点击、选择、切换、启动与终止共完成 175 项交互断言，结果为 175/175 通过。
- 主场景导航与面板联动完成 42 项断言，结果为 42/42 通过。
- 公开版货运 RL 面板的 5 个精确训练入口因依赖未公开训练包而主动禁用；冻结测试证据仍可查看和回放。这是 fail-closed 边界，不是按钮故障。

## 控件盘点

| 面板 | 控件数 | 核心流程 |
|---|---:|---|
| 货运电路 RL / H 总控 | 23 | 策略选择、冻结回放、速度、镜头、8 个模块入口 |
| 系统与指标总览 | 9 | 数据契约校验、指标页、训练顾问、证据矩阵、边界审查 |
| RL 训练中心 | 26 | 船舶、数据集、算法、策略、训练、测试回放、安全设置 |
| 航线规划 | 8 | 任务、联动场景、船舶重定位、规划参数、任务快照 |
| 风险决策 | 6 | 策略预设、验证刷新、规则与证据入口 |
| 海况与时间 | 11 | 公共天气、天气模式、时间倍率、昼夜锁定 |
| AIS 船队态势 | 3 | 船舶选择、跟随/取消跟随 |
| 训练与仿真复盘 | 6 | 记录、评分、导出、策略归因 |
| 小懿系统助手 | 25 | 船舶/风险/障碍/天气/模式/报告联动 |
| **合计** | **117** | **175 项交互断言** |

## 已修复与完善

1. 数据契约校验由“只显示子进程 PID”改为同步读取真实退出码和输出；失败时不会显示成功。
2. 公开版缺失精确训练脚本和配置时，相关入口主动禁用，并显示 `READ-ONLY EVIDENCE` 边界提示。
3. RL 算法、复盘策略、航线任务及联动开关现在均有即时状态反馈，不再出现“选择后界面无反应”的歧义。
4. 新增运行时按钮盘点和全流程交互回归，覆盖动态生成按钮、弹窗、文件导出、短时训练进程启动与立即终止。

## 回归证据

- `reports/godot_button_inventory_v1.json`：117 个运行时控件及其 handler、可见性、禁用原因和选项。
- `reports/godot_button_interaction_smoke_v1.json`：175 项实际交互及预期结果。
- `reports/godot_ui_navigation_smoke_v1.json`：42 项导航与面板联动结果。
- `reports/godot_acceptance_v1.json`、`reports/godot_acceptance_v3.json`：Godot/Python 跨平台接受测试。

## 复现命令

```bash
make GODOT="/Applications/Godot.app/Contents/MacOS/Godot" godot-button-inventory
make GODOT="/Applications/Godot.app/Contents/MacOS/Godot" godot-button-interaction-smoke
make GODOT="/Applications/Godot.app/Contents/MacOS/Godot" godot-ui-navigation-smoke
.venv/bin/python -m unittest discover -s tests -v
```

交互回归中的“启动训练”仅验证进程能够从界面按正确参数启动，并立即终止；它不等于训练收敛、实船测试或生产部署。
