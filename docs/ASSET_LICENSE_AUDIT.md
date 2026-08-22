# 资产许可审计（发布前必须处理）

代码已经按 Apache-2.0 准备，但当前仓库中的图片、纹理和角色素材没有完整的逐项来源台账，因此不能把根许可证理解为自动覆盖全部素材。

已发现的高风险或待确认项：

- `characters/download.png`：文件名无法证明来源或再分发许可。
- `characters/ChatGPT Image 2026年6月21日 15_30_22.png`：需要记录生成账号、生成日期与使用条款依据。
- `assets/art/terrain/premium_reference_cliff_rock_32471782690108.jpg`：当前没有来源和许可证记录。
- `characters/` 下其余角色序列帧：需要确认是自制、委托、生成式产物还是第三方素材。
- `assets/ui/xiaoyi/xiaoyi-maritime-officer.png`：来自作者现有“小懿”项目的指定 Q 版海事形象，文件 SHA-256 为 `8f56a569dcb098ef08cd2bed92ffc098474c7d6ef911141760982e9323ffe714`；发布前仍应在资产台账中确认创作/委托/生成来源与再分发依据。

正式公开 GitHub 仓库前，逐项选择以下处理之一：

1. 在 `THIRD_PARTY_ASSETS.md` 记录作者、原始链接、许可证和必要署名；
2. 用具有明确开源许可的素材替换；
3. 从公开版本中排除，并提供占位资源或下载脚本。

`soft_copyright_materials/`、`soft_copyright_template_work/`、`backups/`、`草稿/` 和 ZIP 已加入 `.gitignore`，不应进入公开仓库。

## 公开录屏边界

`docs/media/cargo-circuit-sac-heldout-test.mp4` 是项目作者提供并明确要求公开的屏幕录制成片；公开版仅包含渲染画面，外部录音已全部移除。发布该成片不等于允许从仓库分发其画面中可能出现的原始纹理、角色序列帧或三维资源，完整视觉资产包仍受上述门禁约束。

## 当前可发布路径

在上述视觉资产逐项解决前，完整 Godot 视觉包继续阻断发布，不以根目录 Apache-2.0 自动覆盖。`tools/build_research_core_release.py` 提供独立的 headless 研究核心包：只收录 Python 环境、固定数据、模型/checkpoint、机器可读报告、测试与文档，并在构建和校验时拒绝图片、音频、三维资产、路径穿越和清单哈希不一致。该路径不会删除本地视觉资产，也不会把未核验资产带入公开压缩包。
