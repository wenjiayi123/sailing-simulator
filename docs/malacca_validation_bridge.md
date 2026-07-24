# 马六甲 Web 沙盘验证桥接

## 文件位置

- 桥接脚本：`res://scripts/integration/malacca_validation_bridge.gd`
- 主场景节点：`Main/MalaccaValidationBridge`
- 请求文件：`user://malacca_validation_request.json`
- 结果文件：`user://malacca_validation_result.json`

## 运行方式

`MalaccaValidationBridge` 默认每 1 秒轮询一次请求文件。没有请求文件时不执行任何动作，不影响原来的手动驾驶、舰队管理、HUD 和 RL 控制面板。

当 Web 写入请求文件后，桥接节点会：

1. 读取并解析 Web 生成的 JSON 请求。
2. 根据 `vesselId` 查找现有船舶，找不到时通过 `ShipFleetManager.spawn_ship_at()` 生成验证船。
3. 将 `vesselId` 映射到 Godot 船舶的 `ship_agent_id`。
4. 根据 `origin`、`destination` 和 `progressPercent` 计算本地验证起点。
5. 根据 `headingDeg` 设置初始航向。
6. 根据 `speedProfile.targetKnots` 和 `speedProfile.maxSafeKnots` 写入外部航速控制。
7. 通过 `ShipRouteSystem.configure_route()` 设置验证航段。
8. 在 `GeneratedMalaccaValidationScene` 下生成验证起点、终点和风险区标记。
9. 根据风险事件临时写入 `ShipNavigationObstacles`：事故封航生成阻断盒，碰撞风险生成临时礁石，港口瘫痪生成靠港阻断区，危险级极端天气生成禁航盒。
10. 在验证窗口结束后写回结果 JSON，并恢复原 `ShipNavigationObstacles` 配置。

有窗口运行时，验证按 `validation_duration_seconds` 的时间窗口持续推进；headless 批处理运行时，`finalize_immediately_in_headless` 默认开启，会在加载真实船舶、航线、风险区和临时障碍后快速写出最终结果，便于 Web/Godot 文件桥接自动测试。

## 返回结果

结果字段与 Web 的 `GodotValidationResult` 保持一致，包含：

- `requestId`
- `vesselId`
- `status`
- `safePass`
- `estimatedTravelMinutes`
- `riskLevel`
- `recommendedSpeedKnots`
- `simulatedDurationSeconds`
- `reachedDestination`
- `averageSpeedKnots`
- `minClearanceMeters`
- `collisionCount`
- `groundingCount`
- `riskEventResolvedCount`
- `delayDeltaMinutes`
- `carbonDeltaTons`（模型估算，非流量计观测）
- `carbonModel`
- `loadedScene.routePointCount`
- `loadedScene.riskZoneCount`
- `loadedScene.temporaryObstacleCount`
- `summary`

第 32 步新增的关键回传字段含义：

- `safePass`：是否安全通过；只有未碰撞、未搁浅且最小安全间距不低于阈值时为 `true`。
- `estimatedTravelMinutes`：按验证航段距离、推荐航速和风险事件附加延误估算的预计耗时。
- `riskLevel`：综合风险等级，取值为 `low`、`medium`、`high`、`critical`。
- `recommendedSpeedKnots`：结合风险等级、安全航速上下限和目标航速计算出的推荐航速。
- `carbonDeltaTons`：基于航段米制距离、三次方推进功率曲线、酒店负荷和比油耗参数的相对碳排模型；负数表示模型减排，不代表实船流量计观测。
- `carbonModel`：记录模型名称、系数与 `measured=false`，便于港口接入时用校准船型参数替换。
- `riskEventResolvedCount`：只统计请求中明确带有 `resolved=true` 的事件，不再因验证窗口结束而默认全部解决。

## 保护边界

- 不改 `player.gd` 的移动、转向、动画和输入逻辑。
- 不改 `ShipFleetManager` 的原有舰队管理逻辑。
- 不永久修改 `ShipNavigationObstacles` 的原始障碍配置；验证完成后自动恢复。
- 不改原 UI 面板行为。
- 只在收到外部请求时调用已有公开方法进行验证。
