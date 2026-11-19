# GitHub Joy

把 GitHub Trending 变成每天可读的项目简报：扫描榜单 → 未收藏的进入 `unread` → 按数量阅读并总结「功能 + 实现逻辑」→ 生成 HTML 发布到 GitHub Pages → 已读的移入 `read`。

## 状态

**需求 + 设计 + 手册 v1.2；M1/M2/M3 完成（含控制台扫描与阅读按钮），M4 渲染/发布未实现。** 文档：[`REQUIREMENTS.md`](docs/REQUIREMENTS.md)、[`DESIGN.md`](docs/DESIGN.md)、[`RUNBOOK.md`](docs/RUNBOOK.md)。当前可运行：双击 `joy.bat` 起本地服务（`http://127.0.0.1:8787/`），页面可扫描、阅读 n 个、看进度与统计、配置模型；命令行 `scan.bat` / `run-joy.bat` 等价可用。

## 讨论结论速览

- `unread` / `read` 收藏夹：用 **GitHub GraphQL Lists**（`createUserList`、`updateUserListsForItem` 等）；REST 没有 Lists 管理端点。
- Playwright：**可选兜底**，默认不用；Trending 抓页面即可，登录用 PAT。
- `gh` CLI：可选，不是必需。
- 流程：Trending 抓取 → 去重/排名 → 队列 → 抓 README/目录树/关键文件 → LLM 总结 → HTML → Pages。

## 文件

| 文件 | 用途 |
|---|---|
| `docs/REQUIREMENTS.md` | **需求规格说明（v1.2）**：目标、范围、FR-1～FR-14、验收标准、决策记录、账号风险与合规评估 |
| `docs/DESIGN.md` | **实现设计（v1.2）**：架构、目录、数据模型、API 契约、扫描/阅读/发布/迁移算法、崩溃恢复、M0–M5 |
| `docs/RUNBOOK.md` | **操作手册（v1.2）**：首次部署、日常两次双击、凭据管理、故障排查（含代理）、备份恢复、回滚与升级 |
| `joy.bat` / `service/` | **M1 本地服务**：127.0.0.1 监听、`X-Joy-Token` + Host 校验、gh 登录/退出、页面对话 |
| `scripts/probe-lists.ps1` | **M1 Lists 只读探针**：验证 token 能否读取 Star Lists（R2） |
| `MEMORY.md` | 初始化记忆：需求原文、技术核实、方案、未决问题 |
| `AGENTS.md` | 给 AI 代理/接手者的工作约定 |
| `README.md` | 本文件 |

## 下一步

1. 在页面完成一次真实 gh 登录，点「探测 Lists 权限」记录 R2 结果（同时更新 DESIGN R2 / RUNBOOK 12.4）；
2. 按 `DESIGN.md` 继续 M2：`scan.ps1`（Search → 去重 → queue → Lists → star），先 `-DryRun`；
3. 每个脚本先干跑再真实写入；完成后回填 `RUNBOOK.md` 的实测项。