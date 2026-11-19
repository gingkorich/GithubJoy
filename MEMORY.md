# GitHub Joy · 初始化记忆（MEMORY）

> 本文件是 2026-11-16 ～ 2026-11-18 与用户讨论的沉淀，供在 `D:\AIproject\GithubJoy` 新开的会话直接接续。
> 讨论阶段：**只做了分析与方案讨论，尚未写任何实现代码**。

## 1. 项目定位

GitHub Joy 是一个 **GitHub Trending 每日简报**工具，目标是：

1. 每天扫描 GitHub Trending 的 **today / this week / this month** 三个榜单；
2. 把尚未收藏的项目加入 **unread 收藏夹**；
3. 用户输入数字 `n` 后，从 unread 中按当前顺序取前 `n` 个项目，逐个阅读，总结**主要功能**与**实现逻辑**，给出项目链接，生成 HTML；
4. 阅读完成后把项目移到 **read 收藏夹**；
5. HTML 发布到用户的 GitHub 仓库，通过 **GitHub Pages** 访问。

与 FreshRSS 简报（`D:\AIproject\FreshRSS\data\briefings\`）属于同类流程，但**代码完全独立**，不混在 FreshRSS 仓库里。

## 2. 原始需求（用户表述）

1. 登录我的 GitHub，每天扫描 GitHub Trending，按 today、this week、this month 三个榜单看，把没有收藏的项目都添加到 unread 收藏夹中；
2. 给我一个 bat 文件，输入数值 n，运行后从 unread 收藏夹中按当前顺序取排名前 n 的项目，逐条阅读，总结项目的主要功能和实现逻辑，给出项目链接，生成 HTML 文档，并把已阅读的项目移动到 read 收藏夹；
3. 把 HTML 文档挂载到我在 GitHub 上的项目下，可通过 GitHub Pages 访问。

## 3. 已核实的技术事实（2026-11-18 查官方文档）

### 3.1 GitHub Star Lists 有 GraphQL API

GraphQL Users 参考中存在：

- 类型：`UserList`、`UserListConnection`、`UserListItemsConnection`、`UserListSuggestion`
- Mutation：`createUserList`、`deleteUserList`、`updateUserList`、`updateUserListsForItem`
- Input：`CreateUserListInput`、`DeleteUserListInput`、`UpdateUserListInput`、`UpdateUserListsForItemInput`

结论：**unread / read 两个“收藏夹”可以用 GraphQL 程序化管理**。

### 3.2 REST 没有 Lists 管理端点

REST「Starring」只有：列出 stargazers、星标数、星标历史、列出已星标仓库、检查是否已星标、star、unstar。
**没有创建/修改 Lists 的 REST 端点**（已核对官方文档，API 版本 2026-03-10）。

### 3.3 Trending 没有官方 API

- 页面：`https://github.com/trending?since=daily|weekly|monthly`
- 服务端渲染的 HTML，可直接请求解析；页面结构变化时需要维护选择器。
- 备选：Search API（`created:>=日期` + `sort=stars`）只能近似，排名口径与 Trending 不同。

### 3.4 Playwright 的评估

- 技术上可以驱动浏览器完成：抓 Trending、登录、操作 Lists、Star、甚至提交文件。
- 但**不推荐作为主方案**：
  - 登录态会过期，2FA/设备验证/验证码会打断；
  - Lists 页面改版会导致选择器失效；
  - 速度慢；
  - 高频自动化账号操作可能触发风控；
  - 读 README/代码仍然要走 API/raw，Playwright 解决不了。
- 定位：**仅作为兜底**（例如 GraphQL 的 Lists 权限/顺序能力不足时）。

### 3.5 GitHub CLI（gh）

- **不是必需**：PAT + `Invoke-RestMethod` 可以直接调 REST/GraphQL；`git` 可以推送。
- 装了更方便：`gh auth login` 设备码登录、token 存系统凭据、`gh api graphql` 省去拼请求。
- 建议：脚本不依赖 `gh`，把它当人工排查工具；是否安装由用户决定。

## 4. 讨论阶段形成的方案要点

| 主题 | 结论 |
|---|---|
| unread/read 收藏夹 | 首选 **GitHub GraphQL Lists**；备选本地队列 / Issues+标签 / Projects |
| 登录方式 | **PAT**（本地 `gh.json`，git 忽略）；Actions 用 Secrets |
| Trending 取数 | 抓页面为主，Search API 兜底；两者都记录数据来源 |
| 阅读材料 | README（≤20k 字符）+ 目录树（≤200 项）+ 3–5 个关键文件 |
| 总结结构 | 主要功能 / 架构与关键模块 / 数据流 / 技术栈 / 适用场景 / 链接 |
| 顺序定义 | 周期优先级 today > week > month，同周期按榜单排名；跨周期去重取最优 |
| 输出 | 自包含 HTML（复用 briefings 的样式思路），按日期归档 + 最新索引 |
| 发布 | push 到发布仓库的 `docs/`（或 `gh-pages`），开启 Pages |
| 调度 | 本机任务计划 或 GitHub Actions（Actions 更适合每日扫描） |

## 5. 环境与相关路径

- 系统：Windows 11 家庭中文版，PowerShell 5.1
- 已安装：Node（`D:\SoftWare\nodejs`）、Python 3.11、Docker Desktop（有 `freshrss` 容器，但**本项目不要求 Docker**）
- 新项目根目录：`D:\AIproject\GithubJoy`
- FreshRSS 参考资产（**只读参考，不修改**）：
  - `D:\AIproject\FreshRSS\data\briefings\REQUIREMENTS.md`
  - `D:\AIproject\FreshRSS\data\briefings\DESIGN.md`
  - `D:\AIproject\FreshRSS\data\briefings\RUNBOOK.md`
  - 可复用思路的脚本：`export-unread.php`、`llm-stage1.ps1`、`llm-stage2.ps1`、`md-to-html.php`、`assemble.php`
  - 模型配置示例：`D:\AIproject\FreshRSS\data\briefings\llm-config.sample.json`（**不要复制真实 key 到本仓库**）

## 6. 可沿用的工程约定（FreshRSS 实战经验）

1. **PowerShell 5.1 编码坑**：`.ps1` 必须保持纯 ASCII；中文文案放到 `.md`/`.json`，用 `-Encoding UTF8` 读取。
2. 数据文件统一 **UTF-8 无 BOM**；读 JSON 时容忍 BOM。
3. HTTP 调用要带：超时、重试、错误详情（状态码 + 响应体）。
4. `Invoke-RestMethod` 在 PS 5.1 下可能把 UTF-8 当 Latin-1，需要按字节还原。
5. 大任务要支持**断点续跑**（已完成项跳过）、`-Force` 重做、`-OnlyId` 单条重试、`-IdsFile` 并行分片。
6. LLM 内容审核失败要降级（缩短输入/拆分批次/占位说明），不能中断整轮。
7. HTML 要自包含（内联 CSS、深色模式、打印友好），所有外部文本转义，只放行 `<br>`。
8. 破坏性操作（移动收藏夹、提交仓库）前先做可回滚备份/记录。
9. 文档三件套：REQUIREMENTS / DESIGN / RUNBOOK，随代码同步更新。
10. 先 `-NoPublish`/`-NoMark` 试跑，再执行真实写入。

## 7. 尚未确认的问题（新会话先问）

1. “unread / read 收藏夹”确认用 **GraphQL Lists** 吗？（备选：本地队列、Issues+标签、Projects）
2. 是否同时 **star** 这些项目？还是只加入 Lists？
3. Trending 取数：抓页面（一致）还是 Search API（稳定）？
4. 发布仓库：已有还是新建？名称？public/private（免费 Pages 需 public）。
5. 每天扫描：本机任务计划 还是 GitHub Actions？
6. 每次 n 的上限（建议 ≤20）、HTML 保留策略（仅最新 / 按日期归档）。
7. “实现逻辑”深度：README+目录树（便宜）还是读关键源码（更准、更贵）。
8. 是否需要 Playwright 兜底（默认不装）。

## 8. 建议的 MVP 路线

1. 本地状态队列 + 手动触发扫描（不写 GitHub Lists，先跑通数据）；
2. 接入 GraphQL Lists（createUserList / updateUserListsForItem）；
3. 阅读前 n 个 → LLM 总结 → 本地 HTML；
4. 发布到 Pages 仓库（先手工开启 Pages）；
5. 加每日调度（Actions 或任务计划）；
6. 最后再考虑 Playwright 兜底。

## 9. 变更记录

| 日期 | 内容 |
|---|---|
| 2026-11-18 | 建立初始化记忆：需求、技术核实、方案结论、环境、约定、未决问题 |
| 2026-11-19 | 需求定稿：Q1–Q10 全部确认，见 `docs/REQUIREMENTS.md` v1.0 |
| 2026-11-19 | 需求变更 v1.1：本地控制台（`joy.bat` → 127.0.0.1 服务 + 页面）、gh 登录/退出、页面配置模型 Key；报告改为 overview + Q&A；新增账号风险与合规评估 |
| 2026-11-19 | 设计文档完成（`docs/DESIGN.md` v1.1）：Node + PowerShell 分层、数据模型、GraphQL 替换语义、崩溃恢复、M0–M5 |
| 2026-11-19 | 操作手册完成（`docs/RUNBOOK.md` v1.1）：首次部署、日常操作、凭据、排错、备份恢复、回滚、检查清单 |
| 2026-11-19 | M1 认证探针落地：`joy.bat`、Node 本地服务（127.0.0.1:8787、令牌/Host 校验）、gh 登录/退出、Lists 只读探针；实测 R1 通过 |
| 2026-11-19 | 需求 v1.2 + 代理支持：自动探测 Windows 系统代理并注入 gh；页面显示代理来源；实测登录恢复 |
| 2026-11-19 | M2 扫描脚本落地：`scan.ps1`（三周期 Search/去重/队列/Lists 保留其它排序/star 上限）+ `scan.bat`；DryRun 实测 75 条、计划 star 25、未写远端 |

## 10. 决策结果（2026-11-19）

第 7 节列出的 8 个问题已全部拍板，另新增 2 个决策点（Q9 / Q10）。完整表述与验收标准见 `docs/REQUIREMENTS.md` 第 10 节。

| # | 决策 |
|---|---|
| Q1 | `unread` / `read` 用 GitHub GraphQL Star Lists |
| Q2 | 加入 unread 时**默认同时 star**（`-NoStar` 可关） |
| Q3 | **不抓 Trending 页面，只用 Search API**（`created:>=` 时间窗 + `sort=stars`）；排名口径与官方 Trending 不同，会漏「老仓库突然爆火」 |
| Q4 | 发布到**本仓库 `docs/`**（`main`），仓库需设为 public；需提交 `docs/.nojekyll` |
| Q5 | **本期不做自动调度**，手动双击 `scan.bat` 扫描 |
| Q6 | n 上限 20、默认 5；`reports/` 永久保留 |
| Q7 | 阅读**默认 deep**（README + 目录树 + 3–5 个关键文件），`-Lite` 降级 |
| Q8 | 不引入 Playwright |
| Q9 | 队列 FIFO：新条目追加到尾部，扫描不改动已有顺序 |
| Q10 | **发布成功后才迁移**（unread → read）；发布失败保留在 unread，下次补发 |

> 下一步：编写 `docs/DESIGN.md` / `docs/RUNBOOK.md`，再实现 MVP。

## 11. 需求变更 v1.1（2026-11-19）

用户提出的三点变更与结论（详见 `docs/REQUIREMENTS.md` v1.1）：

1. **入口改成「双击 bat → 本地服务 + 网页控制台」**：可行。Node 24 已装，用 Node 标准库写 HTTP 服务（不装 npm 依赖），只绑 `127.0.0.1:8787`；页面提供扫描按钮、上次扫描时间、本次新增 unread、累计 unread、GitHub 主页链接、`reports/` 报告列表、gh 登录/退出、模型 Key 配置。安全上必须加随机 `X-Joy-Token` + `Host` 校验（防任意网页 POST localhost、防 DNS rebinding）。
2. **报告改成「一段话讲功能 + 问答讲实现」**：可行。`overview` 单段 80–150 字；`qa` 3–6 组，问题落在调用链/数据结构/依赖/状态/错误处理/取舍上；`qa[].refs` 指向真实文件，禁止编造。
3. **封号风险**：按本设计（只走官方 API、不抓页面、单轮 star ≤25、串行退避、单人自用）风险低；红线是多账号、绕限流、刷 star、抓登录页面。

环境核实：`node v24.20.0`、`gh 2.103.3`（`--web` / `--scopes` / `auth token` / `auth logout` / `auth status --json` 均可用）。

M1 探针（2026-11-19）：
- 已实测 R1：gh 在无 TTY 子进程中直接输出 `! One-time code (XXXX-XXXX) copied to clipboard` 与 device URL，不等待回车；正则解析稳定；取消（taskkill /T）有效。
- 已实测本地服务安全：无 `X-Joy-Token` 的 POST 返回 403；`Host` 非 `127.0.0.1/localhost` 返回 403；首页注入 token 且 CSP 生效。
- 端口回退可用（8787 被占用时落到 8788），`--stop` 可结束服务。
- R2 读取已实测（2026-11-19）：scope 为 `gist, read:org, repo, user`；共 13 个 List 均可读；`unread` 已存在（35 项），**`read` 不存在**（M2 自动创建）；写入权限待 M2 首次 mutation 验证。
- 前端修复：`/api/gh/lists` 是 GET，页面原先不带 `X-Joy-Token` 导致 `bad_token`；已改为按需附带令牌（实测带令牌 200、不带 403）。

M2 扫描（2026-11-19，DryRun 通过）：
- `scripts/scan.ps1` + `scan.bat` 完成；三周期 Search 共 75 条（today total 33、week 1038、month 789，各取前 25），去重后 75；
- 读取 13 个 List（unread 35 项），`read` 不存在 → dry-run 标记「将创建」；
- 计划入队 75、计划 star 25（单轮上限）、跳过 50（star 上限）；
- DryRun 不写 `queue.json`/`state.json`/`trending-*.json`，不改远端。

真实小批（2026-11-19，`-MaxAdd 5 -NoStar`）：
- 创建 `read` List（`UL_kwDOBnn_is4Akc2X`），`unread` 35 → 40，失败 0；
- 写 `trending-2026-11-19.json`、`queue.json`（5 条 pending，`inUnread=true`）、`state.json`（lastScan.added=5、unreadTotal=40）；
- 未 star（`-NoStar`），`starSkipped=5`；
- 复跑 DryRun：`already_unread=5`、新增计划 5 条、unread 40→45，幂等成立；
- R2 写入随之确认：`createUserList` 与 `updateUserListsForItem` 均成功，`user` scope 足够。

入选规则 v2（2026-11-19）：
- 阈值改为严格大于：today >80、week >1000、month >3000；实测 totalCount 5 / 13 / 50；
- 过滤：排除已 star（`viewerHasStarred`）、已在 read/unread、queue done/moved、denylist；
- 选择：配额 today 5 / week 8 / month 12，不足按 star 降序补齐，每轮 ≤25；入队数不超过当日剩余 star 额度，保证「加入即 star」；
- DryRun：候选 43（去重后）、选中 25（today 0 + week 8 + month 12 + 补齐 5）、计划 star 25、`skipped.capped=13`；
- today 为 0 的原因：此前真实小批已把 today 的 5 条加入 unread，被 `already_unread` 过滤，配额顺延。
- `-NoStar` 真实运行会**跳过 List 写入**（Star List 只保留已 star 的仓库，未 star 会被清除）；队列里 `inUnread=false` 的条目下次由 `toEnsure` 补 star + 补 List。
- 控制台扫描按钮（2026-11-19）：`POST /api/scan`（`{dryRun:true}` 可选）、`GET /api/jobs/:id` 进度、页面概览（上次扫描/新增/累计 unread/队列）。DryRun 联调：候选 68、added 20、ensured 5、star 25、unread 35→60（计划值）。

阈值 v3（2026-11-19）：today >100 / week >2000 / month >5000。实测 totalCount 2 / 5 / 30，去重 37；已 unread 19、已 star 1；剩余 17 全部入选（month 12 + 补齐 5），无 capped；计划 star 17、unread 60→77。

M3b 阅读与总结（2026-11-19）：
- 新增 `scripts/read.ps1`、`scripts/lib/llm.ps1`、`scripts/prompts/*`（system/user/repair/cliches）、`run-joy.bat`；
- 流程：选 pending 前 n（或 OnlyId/IdsFile）→ `summarizing` → 抓 repo/README/目录树（deep 另抓 3–5 关键文件）→ LLM → 校验/修复 → 写 `data/summaries/<o>__<r>.json` → 队列 `done`；
- 试跑开关：`-DryRun`（只选）、`-NoWrite`（抓+调模型不落盘）、`-NoLlm`（只抓材料）、`-Lite`（不读源码）、`-Force`；
- 实测：chronytop（Lite）materials README 4339 / tree 16；LLM 真实输出 overview 126 字、qa 6 组、warnings 0；summary 6604 字节，queue `done`、state.lastRead 更新；
- 踩坑与修复：
  1) `auto` 拒绝 `temperature` → 400；测试与正式调用均改为默认不发送，显式配置才带；
  2) 推理模型把 max_tokens 用在 reasoning，导致 content 为空/被截断 → 初始 12000，`finish_reason=length` 时自动翻倍（上限 12000）重试；超时调到 240s；
  3) 模型偶发输出带裸换行/尾逗号的 JSON → 增加修复器（转义字符串内控制字符、去尾逗号），失败时把原始输出写到 `data/last-llm-raw.txt`；
  4) `.ps1` 混入中文导致 PS 5.1 解析失败 → 中文全部移到 `prompts/*.txt/.tpl`，脚本保持纯 ASCII。

M3a 模型配置（2026-11-19）：
- 新增 `GET/PUT /api/llm`、`POST /api/llm/test`，页面「模型」区（接口/模型/Key/超时/保存/测试）；
- 写入 `llm.json` 原子替换，ACL 只授当前用户 `(F)`（实测 `(R,W)` 会因缺少删除权限导致 rename EPERM）；
- 实测：PUT 保存 → 掩码 `sk-t****abcd`；不带 Key 的 PUT 保留原值；非法 URL 返回 400；测试连接命中 DeepSeek（171ms，401 假 Key，错误被截断返回）；删除 `llm.json` 后回到未配置。
- 用户真实配置（`token-plan.maas.qianwenaiapi.com`，模型 `auto`）首次测试 400：`auto does not support parameter(s): temperature`；已从测试请求移除 `temperature`，复测 `ok=true, 200, 445ms`。正式调用（`read.ps1`）同样必须支持「去掉 temperature 重试」。

关键实测（2026-11-19）：**Star List 只保留已 star 的仓库**。此前 `-NoStar` 加的 5 个条目在约 1 小时后从 `unread` 消失（40→35），这 5 个 `viewerHasStarred=false`，剩余 35 个全部 true。因此流程改为「先 star → 再写 List」，`-NoStar` 只做计划、不写 List；队列里 `inUnread=false` 的条目下次由 `toEnsure` 补 star + 补 List。

代理问题（2026-11-19 实测）：
- 现象：点登录报 `failed to authenticate via web browser ... wsarecv: connection attempt failed`；
- 原因：本机 `github.com:443` 直连被阻断，而 `api.github.com` 直连正常；`gh` 不读 Windows 系统代理，只认 `HTTPS_PROXY` / `ALL_PROXY`；
- 本机系统代理 `127.0.0.1:10808` 可用（`curl --proxy` 返回 200）；
- 修复：服务读取 `config.network.proxy`，为空时自动读注册表 `ProxyEnable/ProxyServer`，统一注入 gh 子进程与 Lists 探针；页面显示「网络代理」；
- 实测：修复后点登录 2 秒内拿到设备码，说明连通性恢复。

待确认：无。Q11–Q14 已于同日确认：页面提供「阅读 n 个」、`gh` 优先 + PAT 兜底、`llm.json` 明文 + ACL、Q&A 3–6 自适应。