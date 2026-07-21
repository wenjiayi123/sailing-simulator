# Release checklist

## Repository

- [ ] 工作区干净；版本号与 `CHANGELOG.md` 一致。
- [ ] README 中的克隆地址、截图、锚点和文档链接有效。
- [ ] `LICENSE`、`NOTICE`、`CITATION.cff` 与第三方清单完整。
- [ ] 没有本机绝对路径、凭据、缓存、虚拟环境、训练输出或申请材料。
- [ ] 与航行无关或来源不明的资产未进入发布清单。

## Validation

- [ ] `make test` 通过。
- [ ] `make godot-check` 通过。
- [ ] `make godot-smoke` 输出 `SHIP_RL_OK`。
- [ ] 完整 train → checkpoint → test → recorded replay smoke 通过。
- [ ] README 截图由当前 `main.tscn` 重新生成并完成目视检查。
- [ ] 短预算失败结果没有被描述为策略收敛。

## GitHub

- [ ] CI 在目标提交上通过。
- [ ] Issue / PR 模板与安全报告入口可用。
- [ ] 仓库描述、Topics、默认分支和可见性设置正确。
- [ ] 发布说明包含已知限制、升级说明与数据来源变化。
- [ ] 在确认前保持私有；只有仓库所有者明确批准后才切换为公开。
