# GitHub Joy

把 GitHub Trending 变成每天可读的项目简报：扫描榜单 → 未收藏的进入 `unread` → 按数量阅读并总结「功能 + 实现逻辑」→ 生成 HTML 发布到 GitHub Pages → 已读的移入 `read`。

## 状态

**M1–M4c 完成并已上线：<https://gingkorich.github.io/GithubJoy/>**（报告在 `/reports/`，根路径为归档入口）。文档：[`REQUIREMENTS.md`](docs/REQUIREMENTS.md)、[`DESIGN.md`](docs/DESIGN.md)、[`RUNBOOK.md`](docs/RUNBOOK.md)。点一次「阅读」自动完成 阅读→渲染→发布→迁移；架构口径（2026-11-20）：**GitHub Star Lists 是唯一状态源**，`data/queue.json` 只是 read 运行期的临时工作集。Star List 约束与跨进程工作流锁见 v1.5 文档。

## 讨论结论速览

- `unread` / `read` 收藏夹：用 **GitHub GraphQL Lists**（`createUserList`、`updateUserListsForItem` 等）；REST 没有 Lists 管理端点。
- 榜单取数：**只用 GitHub Search API**，不抓 Trending 页面（排名口径与官方 Trending 不同，属已确认取舍）。
- Playwright：**不引入**；所有 GitHub 操作走 GraphQL / REST / `gh` / git。
- `gh` CLI：登录优先走 `gh`（设备码），PAT 兜底；令牌只存本机。
- 流程：Search 三周期榜 → 去重/配额选择 → star + 入 unread → 阅读前 n（LLM 总结）→ HTML → Pages → 迁入 read。

## 文件

| 文件 | 用途 |
|---|---|
| `docs/REQUIREMENTS.md` | **需求规格说明（v1.5）**：目标、范围、FR-1～FR-14、验收标准、决策记录、账号风险与合规评估 |
| `docs/DESIGN.md` | **实现设计（v1.5）**：架构、目录、数据模型、API 契约、扫描/阅读/发布/迁移算法、崩溃恢复、偏差登记 |
| `docs/RUNBOOK.md` | **操作手册（v1.5）**：首次部署、日常操作、凭据管理、故障排查（含代理）、备份恢复、回滚与升级 |
| `joy.bat` / `service/` | 本地控制台：127.0.0.1 监听、`X-Joy-Token` + Host 校验、gh 登录/退出、扫描/阅读/发布/迁移编排、模型配置 |
| `scan.bat` / `run-joy.bat` | 无界面入口：分别透传 `scan.ps1` / `read.ps1` |
| `scripts/{scan,read,render,publish,migrate,status,probe-lists}.ps1` | 流水线脚本（均可单独干跑） |
| `templates/` | 报告/索引模板与中文文案（`labels.json`） |
| `MEMORY.md` | 初始化记忆 + 里程碑实测记录 |
| `AGENTS.md` | 给 AI 代理/接手者的工作约定 |
| `README.md` | 本文件 |

## 下一步

- 无待办里程碑（M1–M4c 上线）。已知未做项：每日自动调度（Q5 本期不做）、`self-test.ps1` 离线测试与 `-Repair` 一键修复（DESIGN D7/M5 记录）、概览的「报告列表」入口；需求变化先回写 `REQUIREMENTS.md` 再动代码。
