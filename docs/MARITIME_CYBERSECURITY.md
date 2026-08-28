# 船舶网络安全功能层与外部准入门禁

## 定位

本层服务于强化学习航行模拟器的船桥网络安全训练、攻击复现和控制验证。它把网络安全从代码扫描、软件物料清单和静态哈希，扩展为可操作、可回执、可篡改检测的 Godot 离线靶场。它不是生产船桥网络，不向船舶执行器转发任何报文，也不改变船舶运动模型、观测空间、动作空间、奖励函数或已有策略。

运行入口为系统总览中的“船舶网络安全 / 分区 · 身份 · 签名更新 · IDS · 恢复”，快捷键为 `F11`。

## 已实现能力

### 网络分区与最小权限

- 七个安全域：安全关键控制区、导航传感区、驾驶台操作区、教员训练区、工程维护区、审计监控区和外部交换隔离区。
- 默认拒绝；只有配置文件中的八条源域、目标域、服务三元组可进入许可判定。
- 每条许可流还必须通过会话和角色权限校验；外部交换隔离区到安全关键控制区的直接控制始终拒绝。
- “允许”只生成模拟回执，`packet_forwarded=false`、`mapped_to_actuation=false`。

### 身份认证与审计

- 四类训练身份：操作员、教员、安全管理员、审计员。
- 有盐 SHA-256 训练口令、会话有效期、三次失败锁定、随机数重放检测和逐动作授权。
- 身份方案只用于离线训练，明确不是生产密码存储、身份提供方、多因素认证或特权访问管理证据。
- 每个动作产生前向 SHA-256 链式回执；导出时会话令牌被脱敏。

### 软件完整性与签名更新

- 七文件软件启动哈希清单覆盖安全配置、运行控制器、操作面板、更新载荷、签名、公钥和外部验收模板。
- 离线更新载荷使用 RSA PKCS#1 v1.5 / SHA-256 签名；公钥入库，生成签名用的临时私钥已删除且不在仓库。
- 正确签名只得到 `SIGNATURE_VALID_QUARANTINED`，不会安装；任何载荷改动都使签名验证失败并触发严重告警。
- 这是软件哈希许可清单，不是硬件信任根、可信平台模块、安全启动或度量启动证明。

### 入侵检测、恢复和渗透测试

- 八类规则：暴力认证、随机数重放、角色越权、禁止跨区流、无效更新签名、启动完整性失败、审计链篡改、未经确认恢复。
- 告警带序号、严重级别、确认人和确认时间，且明确 `production_sensor_event=false`。
- 恢复点是带哈希的内存训练快照；恢复需要重新授权和人工确认。
- 八用例渗透活动覆盖上述攻击面，所有用例只攻击离线靶场，不能替代独立渗透测试。

## 外部验收门禁

`data/verification/maritime_cybersecurity_acceptance_manifest.template.json` 只接受逐文件 SHA-256 绑定的外部证据：

1. 实建网络拓扑、防火墙导出、虚拟局域网和数据二极管测试；
2. 生产身份提供方、多因素认证和特权访问复核；
3. 硬件信任根、度量启动日志、生产签名密钥仪式、安装和回滚测试；
4. 入侵检测传感器、安全运营中心转发、防篡改硬件日志和事件响应演练；
5. 离线备份、裸机恢复、实测恢复时间目标和恢复点目标；
6. 独立测试人员身份、签名报告、零未关闭严重/高危发现和整改复测；
7. 船旗国或船级社决定、合格评估人和签名验收。

布尔值自我声明不能绕过缺失证据。即使模板完整，系统也只进入“可交独立评估”状态，不能自行签发生产授权。

## 证据与复现

- 功能配置：`data/verification/maritime_cybersecurity_profile_v1.json`
- 软件启动清单：`data/verification/bridge_secure_boot_manifest_v1.json`
- Godot 运行报告：`reports/godot_bridge_cybersecurity_smoke_v1.json`
- 独立保障报告：`reports/maritime_cybersecurity_assurance_v1.json`

```bash
make GODOT="/Applications/Godot.app/Contents/MacOS/Godot" godot-bridge-cybersecurity-smoke
make maritime-cybersecurity-assurance-verify
.venv/bin/python -m unittest tests.test_maritime_cybersecurity -v
```

当前门禁固定为：`production_network_segmentation_verified=false`、`hardware_secure_boot_verified=false`、`production_ids_verified=false`、`disaster_recovery_field_verified=false`、`independent_penetration_test_completed=false`、`class_or_flag_cyber_approval=false`、`production_authority=false`。
