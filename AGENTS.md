# AGENTS.md · GitHub Joy

本文件是给 AI 编码代理（以及接手的人）的入口说明。**开始任何工作前，先完整阅读 `MEMORY.md`。**

## 项目一句话

GitHub Trending 每日简报：扫描 today / week / month 榜单 → 未收藏项目进入 `unread` 收藏夹 → 按 `n` 阅读并总结「功能 + 实现逻辑」→ 生成 HTML 发布到 GitHub Pages → 项目移入 `read` 收藏夹。

## 当前状态

- 阶段：**M1/M2/M3/M4a 完成；M4b 发布与迁移脚本已实现并干跑验证，真实推送/迁移待配置 remote 与 Pages**。
- 已有：`MEMORY.md`、`docs/*`；代码：`joy.bat`、`scan.bat`、`service/*`（扫描按钮 + 进度 + 概览）、`scripts/scan.ps1`、`scripts/lib/*`、`config.sample.json`。
- 未创建：`read.ps1`、`render.ps1`、`publish.ps1`、`migrate.ps1`；控制台尚未接扫描按钮。

## 开工前必须先确认

`docs/REQUIREMENTS.md` 第 10 节的 Q1–Q10 已确认（2026-11-19），可直接进入设计与实现。若实现中出现文档未覆盖的歧义，先回写需求文档并标注版本，不要凭猜测写代码。

## 不可违背的约束

1. **独立项目**：不修改 `D:\AIproject\FreshRSS`，不依赖其 Docker 容器与 PHP 环境。
2. **API 优先**：榜单只走 Search API，其余 GitHub 操作走 REST/GraphQL；**不抓页面**，不引入 Playwright 或浏览器自动化。
3. **密钥安全**：PAT、LLM API Key 只放本地忽略文件（如 `gh.json`、`llm.json`）或 GitHub Actions Secrets；**绝不写入代码、文档、提交历史**。
4. **不伪造数据**：总结必须基于实际抓取的 README/目录树/代码；信息不足时注明“基于 README/结构推断”。
5. **可回滚**：移动收藏夹、推送仓库前保留状态快照或备份。

## 技术约定

- Windows 11 + PowerShell 5.1：`.ps1` **保持纯 ASCII**；中文放 `.md`/`.json`，以 UTF-8 读取。
- 本地控制台：Node ≥18 **仅标准库**（不 `npm install`），只绑 `127.0.0.1`；写操作校验 `X-Joy-Token` 与 `Host`；页面不用 CDN/前端框架。
- GitHub 登录优先 `gh`，PAT 兜底；`gh auth token` 只在内存使用，不写盘、不入日志。
- 数据文件 UTF-8 无 BOM；读取时容忍 BOM。
- HTTP：超时、重试、错误详情（状态 + 响应体）；速率限制退避。
- 大任务支持断点续跑：已完成项跳过、`-Force` 重做、`-OnlyId` / `-IdsFile` 定向重试或并行分片。
- HTML 自包含（内联 CSS、深色模式、打印友好）；所有外部文本转义，仅放行 `<br>`。
- 文档三件套（REQUIREMENTS / DESIGN / RUNBOOK）与代码同步更新。

## 可参考的既有实现（只读）

`D:\AIproject\FreshRSS\data\briefings\` 下的三份文档与脚本，可借鉴：
- 两阶段阅读与断点续跑
- LLM 调用封装（重试、编码修复、内容审核降级）
- 自包含 HTML 渲染
- 配置外置、模板外置、纯 ASCII 脚本

## 下一步（设计已定稿）

1. 按 `docs/DESIGN.md` 的 M0–M5 实现；
2. 每步先干跑（`-DryRun` / `-NoPublish`）再真实写入；
3. 实现中发现的偏差先回写 DESIGN（第 15 节）与 REQUIREMENTS，再改代码；
4. 每完成一个里程碑，回填 `RUNBOOK.md` 第 12.4 节的实测项（R1/R2、输出样例、AC 结果）。