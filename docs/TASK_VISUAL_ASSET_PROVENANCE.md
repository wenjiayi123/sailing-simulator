# 任务场景视觉资产来源记录

本记录覆盖 2026-08-29 为五个高级船舶任务场景生成并进入运行时的位图资产。生成方式为项目授权的位图生成工具；图片没有使用第三方照片、商标或文字。运行时只引用下列最终版本，旧试做图保留在工作树但不进入发布包。

## 最终资产与哈希

- `assets/generated/tasks/auto_berthing/auto_berthing_horizon_v4.png` — `b861474dd0b38e97c006dc94cfc23068d84968447032590523496ee91b8de11c`
- `assets/generated/tasks/auto_unberthing/auto_unberthing_horizon_v1.png` — `a9ac8fb497fd3ea1f1dd918d9b5646bf988727eaefcfabd82ea31e4e44215370`
- `assets/generated/tasks/narrow_channel_head_on/narrow_channel_head_on_horizon_v1.png` — `1be72a2feaccdd026f406f2474a2f65267212b013b1409021b624150c307ea5d`
- `assets/generated/tasks/crossing_starboard/crossing_starboard_horizon_v1.png` — `febbec02fe968fd822a46a79a0111f102f1bc23e63ddeb156cd9459bdd476b7c`
- `assets/generated/tasks/narrow_channel_overtaking/narrow_channel_overtaking_horizon_v1.png` — `f9900cd711d5b90fd3fdabe09f4f3445c41a4bd14a40ebd76b5822a5e867d19d`
- `assets/generated/tasks/shared/task_water_v2.png` — `b321b256fb44b98eb6d33d3710e09703dd701986d91807e76e5e4da11d9b921f`

## 地平线基础提示词组

所有地平线图均使用 `stylized-concept`，资产类型为 Godot 三维环境的方形竖直墙面壁纸，风格为写实、高质量航海训练模拟器背景。各场景主体分别为：

1. 自动靠泊：集装箱码头、岸桥与低矮港区陆线。
2. 自动离泊：引航服务港、拖轮码头、防波堤与清晰出口。
3. 狭水道对遇：长直商业航道、低矮护岸与远处航标。
4. 右舷来船交叉：开阔外海、远处低岛与小型灯塔轮廓。
5. 狭水道追越：工业运河、低矮仓库、岸吊与绿色堤岸。

共同约束为：船桥视平线机位、地平线完全水平、无俯视、无鱼眼、无相机横滚、无近景物体、无文字、无标志、无水印和无界面元素。

## 底边贴合编辑提示词

最终五张地平线图统一执行以下定向编辑：

> 只改变图片底部的纵向构图，使壁纸自然衔接独立的三维实体水面；保持方形画布和水平地平线；按需向下重构天空；远处陆地、港区建筑、护岸或岛屿直接贴住底边；可见海面最多只占图片底部 1% 至 3%；图片主体应为天空和低矮陆线。保留场景身份、光照、配色、写实感和既有远景结构；所有竖直物保持竖直；不得新增近景物体、文字、标志、水印或界面元素。

## 共享水面提示词

> 方形、可平铺的 Godot 实体水面反照率纹理；正交俯视的写实平静沿岸海水，中等蓝青色，细小低振幅波纹和均匀微光；全图尺度与光照一致，只含水面；无地平线、天空、陆地、船舶、尾流、泡沫带、强烈单向斜浪、透视、文字、标志、水印或界面元素。

## 使用边界

这些图片只用于模拟器视觉背景，不构成港区测绘、实景复原或现场数据。发布权利说明见 `LICENSES/LicenseRef-Project-Generated-Asset.txt`；发布清单以 `data/verification/visual_asset_release_manifest_v1.json` 中的路径与 SHA-256 为准。
