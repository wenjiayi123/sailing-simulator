# 视觉资产许可与完整发布审计

状态：`FULL_VISUAL_PACKAGE_READY`。

完整视觉包不再依赖来源未闭环的角色、岩石照片、背景、云桥纹理、声音或旧版小懿画像。运行时已经切换到
`assets/generated/release/` 中的项目自制 SVG 替代资源；旧素材保留在本地工作树，但明确列入公开包排除清单，未被删除，也不被重新许可。

机器可读权利台账为
`data/verification/visual_asset_release_manifest_v1.json`。其中逐项记录公开包内所有图片、矢量图、视频和截图的 SHA-256、来源、许可证与来源记录。用户授权的公开录屏及其海报/GIF 衍生物使用
`LICENSES/LicenseRef-User-Authorized-Public-Redistribution.txt`；项目自制矢量资源与运行时截图使用 Apache-2.0。

`python3 tools/audit_full_visual_release.py generate` 会生成
`reports/full_visual_asset_release_v1.json` 和 Markdown 摘要。审计同时执行：

1. 所有公开媒体逐项登记、哈希一致且许可证/来源非空；
2. 所有未登记媒体必须匹配本地排除规则，否则失败；
3. `project.godot`、场景、脚本、材质与着色器不得引用排除资产；
4. 项目自制 SVG 必须含可访问标题，且不得含外部链接；
5. 发布检查的严格资产模式必须读取并验证该报告，不能靠人工警告放行。

这项闭环只解决“可再分发的完整视觉模拟器包”。它不改变船舶运动模型、现有强化学习策略，也不授予现场生产控制权。
