# GitHub Joy · 需求规格说明（REQUIREMENTS）

| 项目 | 内容 |
|---|---|
| 文档版本 | 1.5（增加跨进程工作流互斥） |
| 更新日期 | 2026-11-21 |
| 状态 | v1.0 的 Q1–Q10 继续有效；v1.1 新增 FR-13 / FR-14、改写 FR-5 / FR-6、新增第 11 节；v1.2 为 FR-14 补充代理能力；v1.3 按实际实现修正干跑开关并明确队列不持久化；v1.4 明确 Star List 成员约束；v1.5 增加跨进程工作流锁 |
| 对应实现 | M1–M4c 已实现并上线：`joy.bat`、`scan.bat`、`run-joy.bat`、`service/`、`scripts/{scan,read,render,publish,migrate,status,probe-lists}.ps1` |
| 依据 | `MEMORY.md`（2026-11-18 需求原文与技术核实）、`AGENTS.md`（工程约定） |
| 相关文档 | `DESIGN.md`（实现设计 v1.5）、`RUNBOOK.md`（操作手册 v1.5） |

> 本文回答「为什么做、做什么、做到什么算完成」，不含具体命令与实现细节。
> 文中「已确认（2026-11-19）」标记的条目来自需求方拍板；第 10 节是完整决策记录。若 `DESIGN.md` 阶段发现某项不可行，回来改本文件并升版本。

---

## 1. 背景与目标

用户每天关注 GitHub Trending，但真实流程很费手工：三个榜单（today / week / month）要各看一遍，热门项目要逐个打开 README 才能判断值不值得读，看过的项目又容易忘。Star Lists（收藏夹）可以囤项目，却没有「读完」的闭环。

GitHub Joy 把这件事做成一条流水线：

1. 每天跑一次扫描（双击 `joy.bat` 打开控制台点「立即扫描」，或直接双击 `scan.bat`），把**还没收藏**的项目收进 `unread` 收藏夹；
2. 用户给出一个数字 `n`，系统按顺序取 `unread` 里的前 `n` 个项目，逐个阅读并总结「**主要功能 + 实现逻辑**」，附仓库链接；
3. 生成一份可直接浏览的 HTML 简报，发布到 GitHub Pages；
4. 读过的项目从 `unread` 移到 `read`，下次不会再出现。

> 2026-11-19 变更：以上流程收敛到一个**本地 Web 控制台**（FR-13）——双击 bat 打开页面，扫描、看统计、查报告、登录 GitHub、配置模型都在页面上完成；报告正文改为「**一段话讲功能 + 问答讲实现**」（FR-5 / FR-6）。

**核心目标**

1. **不漏**：三个周期榜的并集在每次扫描中都被覆盖，条目可追溯来源与名次；
2. **不重**：同一项目跨榜单、跨天只加入 `unread` 一次，读过的永不再读；
3. **可控**：读多少由 `n` 决定，成本随时可预算，可断点续跑；
4. **可读**：产出一页 HTML，讲清「这项目干什么、怎么实现的」，而不是复述 README 摘要；
5. **闭环**：收藏夹状态自动迁移（unread → read），失败可回滚；
6. **好用**：双击一次打开控制台，扫描与状态一眼可见，不用记命令与参数。

**非目标**

- 不做 Web 服务、不做账号体系：单人、本机 + 个人 GitHub 账号；
- 不做推荐算法：顺序由 `unread` List 顺序决定（扫描时只记录周期与名次），不做兴趣打分；
- 不抓私有仓库、不绕过登录、不处理 2FA/验证码；
- 不做全文翻译，不做视频/播客转写；
- 不做刷 star、刷 trending 等操纵榜单的行为；star 只是收藏动作（默认随 unread 一起 star，见 Q2），不存在批量刷 star 逻辑；
- 不修改 `D:\AIproject\FreshRSS` 及其容器/数据库，本项目的代码、数据、配置完全独立；
- 不生成 Markdown 简报（只产出 HTML）；
- 不做可公网访问的 Web 服务：控制台只绑 `127.0.0.1`，没有账号体系与 HTTPS。

**成功判据**

- 连续 7 天手动运行的扫描均不出现「漏抓/重复加入」；
- 一次 `n=10` 的运行在 25 分钟内产出可打开的页面（模型正常时）；
- 任意一次运行中断后，重跑不重复计费、不产生半成品页面；
- `unread` / `read` 两个收藏夹的内容与本地状态始终一致，偏差可一键修复。

---

## 2. 术语

| 术语 | 定义 |
|---|---|
| 榜单 / 周期 | 由 Search API 取出的 today / week / month 三个周期榜（`created:>=` 时间窗 + `sort=stars`），**不是** GitHub Trending 页面上的实时榜 |
| 条目（item） | 榜单上的一个仓库，唯一键为 `owner/name`（比较时忽略大小写） |
| 排名 | 条目在某周期榜搜索结果中的顺序（按总 star 降序），从 1 开始 |
| 队列 | 本地 `data/queue.json`，**本轮阅读的临时工作集**：阅读开始时写入选中的 n 条，阅读结束清空；扫描不写队列 |
| unread / read | 用户 GitHub 账号下的两个 Star List（GraphQL `UserList`） |
| 扫描（scan） | 抓榜单 → 去重排序 → 按配额选择 → star + 加入 `unread` 的一整轮动作（不写本地队列） |
| 阅读（read） | 从 `unread` 取前 n 条写入临时队列 → 抓 README/目录树/关键文件 → LLM 总结 → 生成 HTML → 清空队列 |
| 迁移（move） | 把条目从 unread 移除并加入 read |
| 轮次（RunId） | 每次 scan / read 的唯一标识，默认 `yyyyMMdd-HHmmss-<kind>` |
| lite / deep | 阅读深度：lite = README + 目录树；deep = 额外读 3–5 个关键源码文件 |

---

## 3. 用户与场景

| 用户 | 场景 |
|---|---|
| 站点所有者（单人） | 早上双击 `joy.bat` 打开控制台，点「立即扫描」；晚上在页面输入 `5` 点「阅读」，或双击 `run-joy.bat`；收藏夹自动迁移 |
| 站点所有者（临时） | 只想补读某几个项目：`run-joy.bat -OnlyId owner/repo`，或 `-IdsFile ids.txt` |
| 维护者 / 接手者 | 按 RUNBOOK 重建环境、更换 PAT / 模型、修复 Trending 解析、回滚收藏夹 |
| 智能体（AI） | 按 DESIGN/RUNBOOK 分步执行；每步先 `-DryRun` / `-NoWrite` / `-NoPush` 干跑 |

**典型一天**

```
08:00  双击 joy.bat → 浏览器打开 http://127.0.0.1:8787/ → 点「立即扫描」
08:02  页面刷新：上次扫描时间、本次新增 unread 8、累计 unread 23、报告列表
20:30  页面输入 5 → 点「阅读 5 个」：自动完成阅读→渲染→发布→迁移
       （run-joy.bat 5 只完成阅读与总结，发布/迁移需随后手动跑 render/publish/migrate）
20:45  生成 reports/<时间戳>.html，推送到 Pages
20:46  unread 移除 5 个，read 增加 5 个；页面统计同步更新
```

---

## 4. 范围

**范围内**

- 三个周期榜（today / week / month）的 Search API 查询；
- 跨榜单/跨天去重、排序、加入 `unread`；
- 通过 GraphQL 管理 `unread` / `read` 两个 List（创建、添加、移除），可选 star；
- README / 目录树 / 关键文件的抓取与截断策略；
- LLM 总结（主要功能、实现逻辑、技术栈、适用场景、亮点与风险）；
- 自包含 HTML 生成、按日期归档、索引页；
- 推送到发布仓库并依赖 GitHub Pages 展示；
- 手动触发入口（`joy.bat` 控制台 / `scan.bat` / `run-joy.bat`），不做自动调度（见 FR-9）；
- 本地 Web 控制台（仅 `127.0.0.1`）：扫描/阅读触发、统计概览、报告列表、账号与密钥管理（FR-13）；
- GitHub CLI（`gh`）的登录 / 退出集成，PAT 作为兜底（FR-14）；
- 配置、密钥、日志、断点续跑、快照与回滚。

**范围外**

- 多用户、多账号、团队共享；
- 对仓库代码做静态分析/编译/运行，或复现项目效果；
- 抓取 Issue/PR/Discussion 做舆情分析（后续可选）；
- 自动生成 README 以外的多媒体内容（截图、视频）；
- 付费墙、登录态内容；
- 浏览器自动化（Playwright）：所有 GitHub 操作走 GraphQL / REST / git；
- 自动调度（GitHub Actions / Windows 任务计划 / 常驻服务）：本期只做双击手动入口；
- 控制台的公网访问、HTTPS、多用户与权限体系；
- 通过浏览器自动化操作 GitHub 网页（仍走 API / `gh`）；
- 榜单口径变更后的自动适配（页面结构变化需人工修选择器，但必须报错而不是静默出错）。

---

## 5. 功能需求

### FR-1 每日扫描（Search API 单一路径）

> 已确认（2026-11-19）：**不抓 Trending 页面，只用 GitHub Search API**。代价是排名口径与官方 Trending 不同，见第 9 节。项目文案仍保留 today / week / month 三个「周期榜」的说法。

- 三个周期各一条 Search 查询，均 `sort=stars&order=desc`，单周期取前 100 条（单页上限，可配）：

  | 周期 | 查询 | 默认 star 阈值（严格大于） |
  |---|---|---|
  | today | `created:>=<昨天 UTC 日期>` | 100 |
  | week | `created:>=<7 天前 UTC>` | 2000 |
  | month | `created:>=<30 天前 UTC>` | 5000 |

  阈值与条数写入 `config.search`（`minStars`、`perPage`、`strict`），日期一律按 UTC 计算；
- 每个条目记录：`owner/name`、描述、主语言、总 star、fork、topics、`created_at`、`pushed_at`、`archived`、所属周期、搜索结果顺序（作为「名次」）、抓取时间；
- 因 Search 只按总 star 排序，**无法反映「老仓库突然爆火」**，也会纳入「历史 star 高但近期不活跃」的项目；页面与日志各标注一次 `source=search` 与口径说明；
- **入选规则（2026-11-19 修订）**：先剔除已 star 的项目，再按周期配额取 `today 5 / week 8 / month 12`；不足 25 时用其余候选按 star 降序补齐；每轮最多 25 条，且不超过「每日剩余 star 额度」，保证「加入 unread 的每一条都会 star」；
- 结果写入 `data/trending-<yyyy-MM-dd>.json`，同时记录三个周期实际使用的 query 与 `total_count`（便于事后核对口径）；
- **结果必须可验证**：任一周期返回 0 条或 `total_count=0`，视为该周期为空（警告并继续）；**三个周期全为空**才判定失败——退出码非 0、写错误日志，**不写空结果、不覆盖上一次文件**；
- 请求失败（网络/5xx/超时）重试 3 次（1s/2s/4s）；403/429 读 `Retry-After` 退避；Search 限额较低（认证后 30 次/分钟），三周期 + 少量分页须控制在限额内，超限即中止本轮，**不降级为「少抓几个周期」**；
- Search 单查询最多返回 1000 条，本项目只取前 25 条，不受上限影响；
- 扫描幂等：同一天重复运行只更新榜单快照，不重复加入 `unread`。

**验收**：同一日期连续运行两次，`queue.json` 条目数不变；把 `minStars` 全调成 999999 制造全空结果，运行退出码非 0 且上一次 `trending-*.json` 未被覆盖；单周期为空只告警；日志中三周期 query、`total_count`、`selectionUsed` 均可见。

### FR-2 去重、排序与加入 unread

- 跨榜单去重键为 `owner/name`（不区分大小写）；
- 候选集的**周期优先级**：today > week > month；同周期按 star 降序；
- 过滤规则（每条都要有可统计的跳过原因）：
  - 已在 `unread` → `already_unread`；
  - 已在 `read` → `already_read`；
  - 已 star（`viewerHasStarred`）→ `starred`；
  - 命中断链名单（`config.denylist`：组织名、仓库名、语言、关键词）→ `denied`；
- 选中条目执行「**先 star → 再加入 unread**」；**扫描不写本地队列**，队列只在阅读时作为本轮工作集；
- 队列条目字段（阅读阶段创建）：`id`、`full_name`、`status`（`pending` / `summarizing` / `done` / `failed` / `moved` / `gone`）、`added_at`、`scanned_from`、`attempts`、`last_error`、`summary_path`、`read_run_id`；
- 扫描不改变已有顺序；阅读顺序由 `unread` List 决定。

**验收**：同一仓库同时出现在 today#3 与 week#40，只加入 unread 一次且记录两个名次；日志中 `scanned = added + already_unread + already_read + starred + denied + capped`。

### FR-3 收藏夹同步（GraphQL Lists）

- 启动时查询用户的 Lists，按配置名（默认 `unread` / `read`）匹配；不存在则 `createUserList` 创建；
- 新条目通过 `updateUserListsForItem` 加入 `unread`；
- 若本轮新建 star 成功、但加入 `unread` 失败，则尝试撤销本轮新建的 star；若仓库原本已 star（PUT 返回 304），不得 unstar；补偿失败必须记录并标记本轮部分失败；
- **幂等**：写入前以 API 查询结果为准确认是否已在目标 List，不依赖本地状态猜测；
- 单条失败不中断整轮：记录失败清单，最后汇总，支持 `-OnlyId` / `-IdsFile` 重试；
- 默认 **star**（已确认 2026-11-19）：加入 `unread` 时对条目执行 star；`-NoStar` 或 `config.star_on_add=false` 可关闭；star 已存在时不重复调用；
- **Star List 只保留已 star 的仓库**（2026-11-19 实测）：未 star 就写 List，条目会在之后被 GitHub 清除。因此顺序必须是「**先 star，再写 List**」；`-NoStar` 时跳过 List 写入并告警，不做「加进去但没 star」的假成功；
- **成员关系约束（2026-11-21）**：本工具管理的 `unread` / `read` 条目不加入其它 Star List。迁移使用整体替换语义，将成员集合直接设为 `[read]`，不遍历或保留其它 List 成员；用户不得手工把这两个 List 中的仓库加入其它 List，否则后续迁移可能移除该额外归属；
- 扫描只对 `unread` / `read` 做常规成员查询。候选仓库的 star 状态若查询失败或未知，则遍历 Lists 核实这些未知仓库；若已属于其它 List，按已收藏处理并跳过，若未属于任何 List 才继续 star + 加入 unread；核实失败时本轮失败关闭，不执行相关写入；
- 不重命名或删除 List；
- List 权限/作用域不足时给出明确修复提示（见 9. 约束与假设）。

**验收**：首次运行创建两个 List；同一批条目在扫描、阅读各跑两次的情况下，第二次的 GraphQL mutation 次数为 0；从网页手工把一个项目加进 unread，本地队列不受影响。

### FR-4 按 n 阅读

- 入口 `run-joy.bat`：
  - 双击运行 → 提示 `How many projects to read today? (1-20, default 5)`；
  - `run-joy.bat 5` → 直接使用参数；
  - 非法输入（非整数 / ≤0 / 超过上限）→ 提示后退出，不产生任何远端写入；
- 取 **`unread` List 中按 List 顺序的前 `n` 条**（选中后写入本地临时队列作为本轮工作集，阅读结束清空；`-OnlyId` 的条目必须存在于 unread List）；
- 支持 `-OnlyId <owner/name>`、`-IdsFile <path>` 定向阅读、`-Force` 重读已完成项、`-DryRun` 只打印将要读的清单；
- 每条抓取的材料：
  - 仓库元数据（描述、语言、star、license、最后提交时间、topics）；
  - README：优先 API/raw 取默认分支 README，上限默认 **20,000 字符**，截断必须注明；
  - 目录树：默认分支递归树，上限 **200 项**，优先展示源码目录，跳过大体积资源目录；
  - 关键文件（默认 3–5 个，deep 模式）：入口文件、配置文件、核心模块，按启发式（README 中出现次数 + 路径常见性）挑选；
  - 拿不到 README（404/超大/非文本）→ 标记 `no_readme`，仍可基于描述 + 目录树给结论，但必须注明依据；
- 单条阅读失败（API/LLM/编码）不中断整轮：该条 `failed`，其余继续；全部失败时仍生成页面并说明原因；
- 页面点一次「阅读」后自动串行执行「渲染 → 发布 → 迁移」，无需再点其他按钮；发布失败则停在发布阶段、不迁移；
- 阅读产生的任何中间结果写入 `.work/run-<RunId>/`。

**验收**：`run-joy.bat 3` 恰好处理 3 条且顺序与队列一致；输入 `0`、`abc`、`21` 均被拒绝且无远端写入；`-OnlyId` 能单条重试且不影响其他条目状态。

### FR-5 讲解内容与结构（2026-11-19 变更）

每个项目按「**先用一段通俗的话讲清主要功能，再用问答讲关键实现**」输出，缺字段视为失败：

| 字段 | 要求 |
|---|---|
| `overview` | **一段话**（150–350 字，不加列表、不加小标题）：解决什么问题、给谁用、主要能做什么（具体到使用方式/场景）、有什么特别之处；语言尽量通俗，少堆术语 |
| `qa` | 3–6 组「问题 + 回答」，只讲**关键实现方式**；问题必须具体，回答 2–5 句 |
| `stars` | 当前累计 star 数（由仓库元数据写入，不由模型生成） |
| `sources` | 抓取了哪些文件（含字符数与截断标记），仅用于校验与追溯，不在页面展示 |

- Q&A 的问题聚焦：入口与调用链、核心数据结构、外部依赖/接口、状态与持久化、错误处理与并发、关键设计取舍；**按项目实际结构选题，不套固定模板**；
- 每个回答要能对应 `sources` 中的文件/目录；无法确认时写「基于 README/目录结构推断」；
- `overview` 与 `qa` 不重复：overview 讲「是什么、给谁用、能做什么」，qa 讲「怎么做到」；
- 禁止「该项目非常优秀」类空话；star / license / 最后提交时间以 API 返回为准；
- 语言：中文叙述，仓库名 / 命令 / 技术名词保留原文；
- 深度两档（默认 deep，已确认 2026-11-19）：`deep` = README + 目录树 + 3–5 个关键文件；`-Lite` 只读 README + 目录树，`qa` 至少 3 组并标注「未读源码」；
- **不再输出技术栈、适用场景、风险**（2026-11-19 用户要求）；模型多返回的字段一律忽略；
- 输出 `data/summaries/<owner>__<repo>.json`：`overview`、`qa[]`（含 `q`、`a`、`refs[]`）、`stars`、`sources`、`model`、`generated_at`、`mode`、`warnings`。

**验收**：抽 3 条核对——`overview` 是单段通俗叙述且无列表标记；每个回答能在 `sources` 找到依据；`qa` 组数 3–6；页面卡片标题旁显示 star 数；卡片不再出现技术栈/场景/风险/抓取区块。

### FR-6 HTML 输出

- 产物：
  - `reports/<yyyyMMddHHmmss>.html`：本次简报，文件名为生成时刻（本地时间，精确到秒）；同一秒冲突时追加 `-1`、`-2`；
  - `reports/index.html`：归档索引，按日期倒序列出历史页面；
  - 同日多次运行**不覆盖**已有文件（追加时间后缀），索引每条都可点开；
- 页面结构：
  - 顶部：日期、n、成功/失败/跳过统计、周期分布（today/week/month 各几条）、模式（deep/lite）、总耗时；
  - 每个项目一张卡片，**顺序固定**：标题（含 ★ star 数）→ `overview` 一段通俗叙述 → 「实现逻辑」问答（问题加粗带序号 Q1…Qn，回答成段，可折叠）→ 仓库链接；**不再展示技术栈 / 适用场景 / 风险 / 抓取信息**；
  - 问答按 `qa[]` 原顺序渲染，回答中的文件路径用等宽字体；`refs` 悬停或脚注标出来源文件；
  - 底部：数据来源与口径说明（`source=search`）、生成时间与 RunId（失败项不进报告，明细见任务日志）；
- 自包含：内联 CSS，无外部字体/脚本/CDN；支持深色模式（`prefers-color-scheme`）、打印友好、移动端可读；
- 安全：所有外部文本（README 片段、描述、仓库名）HTML 转义，仅放行 `<br>`；不渲染原始 HTML；
- 生成采用「先写临时文件再原子替换」，中断不留下半成品。

**验收**：断网、打印预览、手机宽度三种方式打开均正常；构造含 `<script>alert(1)</script>`、`&`、`<` 的描述，页面只显示文本不执行；同日跑两次产生两个文件，`index.html` 有两条记录。

### FR-7 状态迁移（unread → read）

- 触发条件（已确认 2026-11-19）：**总结成功 + 页面已生成 + 发布成功**，三者齐备才迁移；发布失败时项目留在 `unread`，摘要保留，不重复计费；
- 不执行 publish/migrate（如只跑 `read.ps1`）时本轮不迁移，收藏夹不变；
- **补发与补迁移**：下次正常运行时，migrate 只处理「`reports-index` 中 published 且仍在 unread List」的条目；补发重跑 `render.ps1` + `publish.ps1`，补迁移重跑 `migrate.ps1`（各环节幂等，无 `-Repair` 一键开关）；
- 迁移步骤：单次 `updateUserListsForItem`，目标成员集合为 `[read]`；这是基于「unread 条目不属于其它 List」的项目约束，**不保留其它 List 成员**；失败条目留在 unread，下次补偿；
- 迁移前写快照 `data/state/lists-<RunId>.json`（迁移前后 unread/read 条目清单），支持 `-Rollback <RunId>`；
- 幂等：`read` 已包含该条目时只做移除；条目不在 `unread` 时跳过并记录；
- 单条迁移失败不影响其他条目：该条保持可重试状态，重跑只补迁移，不重复调用模型。

**验收**：只跑 `read.ps1` 后收藏夹不变、`data/summaries/` 有产物、`reports-index` 无新 published 条目；补发布时不产生新的 LLM 调用，发布后 unread 减少数 = 本次补发条目数；人为让 push 失败，收藏夹不变且退出码非 0。

### FR-8 发布到 GitHub Pages（本仓库发布目录）

> 已确认（2026-11-19）：发布到**当前 `GithubJoy` 仓库**的 `docs/`、`main` 分支；仓库需设为 **public**（免费账号的 Pages 要求）。

- 配置：`publish.repo` = 本仓库（`owner/GithubJoy`）、`branch=main`、`dir=docs/`、`url=https://<login>.github.io/GithubJoy/`；
- 发布时把本轮产物从 `reports/` 复制到 `docs/`：`index.html`（归档索引）、`<yyyy-MM-dd>-n<n>.html`；不生成 `latest.html` 别名；**必须提交 `docs/.nojekyll`**，避免 Jekyll 处理改写文件；
- 与文档共存：`docs/REQUIREMENTS.md` 等继续保留；生成器只写 HTML，不改动 `.md`；
- 只提交生成的页面：`git add` 明确列出 `docs/*.html` 与 `docs/.nojekyll`，**禁止 `git add -A`**；`data/`、`reports/`、`.work/`、`gh.json`、`llm.json` 永不提交；
- 推送前检查：工作区存在与本轮无关的未提交改动时提示用户，不自动 stash / commit；
- 推送流程：`git fetch` → 检查本地与远端是否分叉（分叉即中止并提示手动处理）→ 提交（`joy: 2026-11-19 n=5`）→ `git push`；
- `publish.ps1 -DryRun`：只列出将发布的文件；`-NoPush`：本地提交但不推送；两者都不标 published、不触发迁移；
- 常见错误要给出修复建议：仓库仍为私有 / Pages 未开启 / 分支保护 / 无写权限 / 远端分叉；
- 发布失败：本地页面保留、**不做迁移**（见 FR-7），退出码非 0，并在页面顶部标注「未发布」；
- **公开风险**：仓库设为 public 后，`MEMORY.md`、`AGENTS.md`、`docs/*.md` 及全部历史提交都会公开；发布前须确认这些文件不含个人信息与密钥（`gh.json`、`llm.json` 必须在 `.gitignore` 中，历史提交里也不得出现过）。

**验收**：`publish.ps1 -DryRun` / `-NoPush` 不产生远端变更；正常发布后 `https://<login>.github.io/GithubJoy/` 可访问且与 `reports/` 内容一致；`git show --stat` 只包含发布目录下的 HTML 与 `.nojekyll`；用无写权限的 token 运行，错误信息包含具体原因而不是只说 403。

### FR-9 触发方式（本期不做调度）

> 已确认（2026-11-19）：**本期不实现自动调度**，扫描与阅读都由用户手动触发；调度能力留作后续版本，文档只保留做法说明，不写代码。

- 三个入口：
  - `joy.bat`：**主入口**，启动本地控制台（FR-13）；页面上的「立即扫描」「阅读 n 个」与下两个 bat 等价；
  - `scan.bat`：无界面扫描，供排障或批处理使用；
  - `run-joy.bat`：无界面阅读（透传 `read.ps1` 的 `-N` / `-OnlyId` / `-IdsFile` / `-Lite` / `-DryRun` / `-NoWrite` / `-NoLlm` / `-Force`，见 FR-4）；
- bat 只是薄封装：检查 Node / `gh` / `gh.json` / `llm.json` 与 PowerShell 执行策略 → 调 `.ps1` 或 Node → 透传退出码；
- 并发控制：所有会改动共享数据、Git 工作区或 GitHub Lists 的流程共用 `data/locks/workflow.lock.json` 跨进程工作流租约；控制台阅读流水线从 read 持锁到 migrate 完成，独立 bat/PowerShell 入口必须申请同一把锁；冲突时提示并退出，不允许绕过；失效 owner 依据 PID 与进程启动时间回收；
- 日志：`logs/scan-<yyyy-MM-dd>.log`、`logs/read-<yyyyMMdd-HHmmss>.log`，控制台任务日志同时可在线查看；
- **不实现**：Actions workflow、Windows 任务计划、常驻服务、开机自启；RUNBOOK 中给出「将来如何加调度」的说明；
- 若将来加调度，仍保持文件锁与「同一时间只跑一个 scan」的约束。

**验收**：三个入口都能跑通且统计一致；扫描或控制台完整阅读流水线运行期间启动任一独立写操作脚本，后者被工作流锁拦下；脚本崩溃后锁能识别失效 owner 并恢复；`run-joy.bat` 无参数进入交互输入、有参数直接执行；退出码与对应脚本一致。

### FR-10 配置与密钥

| 文件 | 内容 | 是否入库 |
|---|---|---|
| `gh.json` | `token`（未用 gh 登录时的兜底 PAT）、`login`、`unread_list`、`read_list`、`publish{repo,branch,dir,base_url}` | 否（已 gitignore） |
| `llm.json` | `base_url`、`api_key`、`model`、`timeout_sec`、`max_retries`、`temperature`（可选）；可由控制台读写 | 否 |
| `config.json` | `network`、`search`（含 `minStars/quota/starFilter` 等）、`queue.denylist`、`star` 限流、`read` 深度与截断参数 | 是（唯一业务配置，`config.sample.json` 已删除；模型参数在 `llm.json`） |
| `data/service-token` | 控制台写操作令牌（每次启动重新生成） | 否（运行时，仅本机） |

- 配置缺失/字段非法时立即报错并指出缺哪个字段，不产生半成品；
- 日志、HTML、错误信息、控制台接口中 token / api_key 一律脱敏（如 `***` 或前 4 后 4）；
- 控制台保存 `llm.json` 时先写临时文件再替换，避免半截 JSON；写后立即 `icacls` 收紧为仅当前用户（已确认 2026-11-19）；
- 本期不接入 Actions：密钥只在 `gh.json` / `llm.json`；将来若加 Actions，再从 Secrets 注入；本机文件不得出现在提交历史（`.gitignore` 已覆盖，提交前人工确认）。

### FR-11 失败处理与续跑

| 场景 | 期望行为 |
|---|---|
| 401 / 403（token 失效、权限不足） | 不重试，提示具体 scope 与修复步骤 |
| 404（仓库被删/改名） | 该条标记 `gone`，移出队列，并在页面「已失效」区说明 |
| 429 / 5xx | 指数退避重试（≤6 次），记录 `Retry-After`；仍失败则本条 `failed` |
| GraphQL 返回 `errors` 数组 | 解析错误码与 message，按 `NOT_FOUND` / `FORBIDDEN` 分流，不吞异常 |
| Search 查询返回 422 / 字段缺失 | 记录 query 与响应体，判定本轮失败，不写空结果 |
| LLM 超时 / 非 JSON / 内容审核失败 | 重试 → 缩短输入/拆批（降级）→ 仍失败则本条 `failed`，不写空总结 |
| 磁盘或推送失败 | 保留本地产物与状态，退出码非 0，可重跑 |

- **断点续跑**：已生成 summary 的条目默认跳过；`-Force` 重做；`-OnlyId` / `-IdsFile` 定向重试；`-Resume <RunId>` 继续未完成的轮次；
- 所有远端写入（加/移 List）都可重入，重跑不会重复添加或误删。

### FR-12 可追溯

- 每轮在 `.work/run-<RunId>/` 保留：Search 原始 JSON 响应与查询参数（query、`total_count`）、每条抓取的原始内容与截断信息、LLM 请求摘要与响应、统计 `meta.json`（起止时间、条目数、耗时、成本估算）；
- `data/state.json` 记录最近一次 scan / read 的时间、数量、结果；
- 归档清理按 `retention`：`.work/` 默认保留 90 天，`reports/` 永久保留。

### FR-13 本地控制台（双击启动）

> 2026-11-19 新增。目标：不再记命令，双击一次打开页面，扫描与状态一眼可见。

- 入口 `joy.bat`：
  - 双击 → 检查 Node（≥18，本机 `v24.20.0`）与 `gh`（可选）→ 启动 `service/server.js`（**仅 Node 标准库，无 npm 依赖**）；
  - 端口默认 `8787`，被占用则依次试 8788 / 8789 / 8790，仍失败则报错退出（不静默换随机端口）；`joy.bat -Port 9000` 可指定；
  - 服务就绪后 1 秒内用默认浏览器打开 `http://127.0.0.1:<port>/`；`-NoOpen` 不打开；
  - 控制台窗口保留，打印访问地址、工作目录与请求日志；**关闭窗口即停止服务**；
  - `joy.bat --stop` 读取 `data/service.json` 中的 PID 结束服务；PID 失效时清理文件并提示；
- **只绑 `127.0.0.1`**，不监听 `0.0.0.0`；无 HTTPS、无账号体系（单机单用户）；
- 页面（`service/public/`，无 CDN、无外部字体、无前端框架）包含：
  - 顶部：登录名 + GitHub 主页链接（未连接显示「未连接」）、服务版本、数据目录；
  - 概览卡片：**上次扫描时间**（绝对 + 相对）、**本次新增 unread 数**、**累计 unread 数**、队列待读 / 已读 / 失败数；
  - 「立即扫描」：`POST /api/scan`；运行中按钮禁用，显示当前阶段、已处理条目数与日志尾部（每秒刷新）；
  - 「阅读 n 个」：数字输入（默认 5，范围 1–20）+ 按钮 → `POST /api/read`，与 bat 等价（见 Q11）；
  - **报告列表**：`reports/*.html` 的文件名、生成时间、大小、条目数、是否已发布；点击新标签打开；旁边给出 Pages 地址；
  - **GitHub 账号区**：未登录 → 「使用 GitHub 登录」并显示一次性代码与 `https://github.com/login/device`；已登录 → 用户名 + 「退出登录」；
  - **模型设置区**：`base_url`、`model`、`api_key`（密码框，回显仅 `sk-****abcd`）、「测试连接」；保存即写 `llm.json`；
- API（JSON，前缀 `/api`）：`status`、`scan`、`read`、`reports`、`reports/<file>`、`gh/status`、`gh/login`、`gh/logout`、`llm`（GET 掩码 / PUT 保存）、`llm/test`、`jobs/<id>`；
- 任务模型：同一时刻只允许一个 scan、一个 read；任务状态写 `data/jobs/<id>.json`（`queued/running/succeeded/failed/cancelled`、起止时间、日志路径、退出码、统计）；失败原因必须显示在页面上，不能只写日志；
- 本地安全：
  - 启动生成随机令牌写 `data/service-token`（仅当前用户可读）并注入首页；所有写操作必须带 `X-Joy-Token`，缺失返回 403；
  - 校验 `Host` 仅允许 `127.0.0.1:<port>` / `localhost:<port>`，防 DNS rebinding；
  - 页面与日志只出现掩码，不返回 `api_key` 与 GitHub token 原文；
  - 保存 `llm.json` 后立即用 `icacls` 收紧为仅当前用户可读写（移除继承）；收紧失败时页面提示但不阻断保存；
- 不做：远程访问、HTTPS、开机自启、系统托盘、日志持久化到云端。

**验收**：双击 `joy.bat` 后 10 秒内浏览器打开并显示概览；关闭窗口后端口释放；扫描完成后页面 2 秒内反映新增数与累计数；不带 `X-Joy-Token` 的 `POST /api/scan` 返回 403；页面源码与日志中搜不到 token / api_key 原文；`joy.bat --stop` 后地址不可访问。

### FR-14 GitHub CLI 集成（登录 / 退出）

> 2026-11-19 新增。已核实本机 `gh 2.103.3`，`--web`、`--scopes`、`--git-protocol`、`auth token`、`auth logout`、`auth status --json` 均可用。

- 检测：`gh --version`；状态用 `gh auth status --hostname github.com --json hosts`（未登录时退出码 1，按「未登录」处理，不当作错误弹窗）；
- 未安装 `gh`：页面提示安装方式，并保留 `gh.json.token`（PAT）作为兜底入口；
- 登录：`gh auth login --hostname github.com --git-protocol https --web --scopes "user"`：
  - `--scopes` 是**追加**语义（gh 默认 `repo, read:org, gist`）；Lists 写入需要 `user`，发布需要 `repo`，两者都必须有；
  - 解析子进程 stdout 中的一次性代码（形如 `XXXX-XXXX`）显示在页面，同时给出 `https://github.com/login/device`；可加 `--clipboard` 让 gh 同时把代码复制到剪贴板，作为解析失败时的兜底；
  - stdin 保持可写：若 gh 停在「按回车打开浏览器」之类提示，服务写入换行；总超时 5 分钟，超时终止子进程并恢复按钮；
  - 登录成功后 3 秒内刷新状态与用户名，无需重启服务；
- 退出：`gh auth logout --hostname github.com`；多账号场景本期不支持，命令前先取 `gh auth status` 的 active user，必要时带 `--user`；
- 取令牌：调用 GitHub 前执行 `gh auth token --hostname github.com`，令牌**只在内存**中用于本轮请求，不写 `gh.json`、不写日志、不回传页面；失败时回落 `gh.json.token`；
- 失败兜底：页面给出「在终端手动执行 `gh auth login`」的命令与说明，并提供 PAT 输入入口；
- **代理（2026-11-19 新增）**：`config.network.proxy` 可显式指定（`http://` / `socks5://`）；留空且 `autoDetect=true` 时读取 Windows 系统代理；代理值通过 `HTTPS_PROXY` / `HTTP_PROXY` / `ALL_PROXY` 注入 gh 子进程，Lists 探针通过 `-Proxy` 传给 `Invoke-WebRequest`。登录失败且日志含 `wsarecv` / `connection attempt failed` 时，页面直接提示检查代理；
- 不做：多账号切换、GitHub Enterprise host、SSH key 管理、`--with-token` 管道注入（避免密钥经管道落盘）、token 自动续期管理。

**验收**：未登录时页面显示「使用 GitHub 登录」与 PAT 入口；登录完成后 5 秒内显示用户名且主页链接可点；退出后状态立即变为未登录；`data/`、日志、页面源码中均无 token 原文；手动取消登录后按钮在 10 秒内恢复可点。

---

## 6. 业务规则速查

| 规则 | 默认值 | 说明 |
|---|---|---|
| 抓取榜单 | today / week / month | 可配置只跑部分周期 |
| 每周期条数 | 100 | 单页上限；配额只取前 5/8/12 |
| 扫描触发 | 双击 `joy.bat` → 页面「立即扫描」 | 等价 `scan.bat`；无自动调度（已确认 2026-11-19） |
| 控制台地址 | `http://127.0.0.1:8787/` | 端口占用时试 8788–8790；仅本机 |
| 阈值（today/week/month） | >100 / >2000 / >5000 | 严格大于；见 `config.search.minStars` |
| 入选配额 | 5 / 8 / 12（合计 25） | 不足按 star 降序补齐；每轮 ≤25 |
| 已 star 过滤 | 开 | `viewerHasStarred`，批量 25 个/次 |
| 单轮 star 上限 | 25 个 | 超出跳过并记录（见第 11 节） |
| Q&A 组数 | 3–6 组 | 按项目复杂度自适应 |
| 页面刷新 | 1 秒 | 轮询 `status` 与 `jobs/<id>` |
| 周期优先级 | today > week > month | 用于配额归属；同周期按 star 降序 |
| 入选规则 | 排除已 star → 配额 5/8/12 → 不足补齐 | 总数 ≤25 时全取；每轮 ≤25 |
| 每日 star 额度 | 100 | 每轮新增数不超过剩余额度 |
| 队列策略 | FIFO 追加（已确认） | 先上榜先读，扫描不改动已有顺序 |
| 每次阅读数 n | 交互输入，默认 5，上限 20 | 超限需显式确认 |
| README 上限 | 20,000 字符 | 截断必须注明 |
| 目录树上限 | 200 项 | 跳过资源目录 |
| 关键文件数 | 3–5 个 | 仅 deep 模式 |
| 阅读深度 | deep（默认，含 3–5 个关键文件） | `-Lite` / `config.deep_mode=false` 降级为 README + 目录树 |
| 是否 star | 是（默认 star） | 加入 unread 即 star；`-NoStar` / `config.star_on_add=false` 关闭 |
| List 名称 | `unread` / `read` | 可配置，缺失自动创建 |
| 输出 | HTML only | 本地 `reports/`，发布即提交该目录（配置 `gh.json.publish.dir`，本机为 `reports/`，见 FR-8） |
| 迁移时机 | 发布成功之后 | 只跑 read（不跑 publish/migrate）不迁移；未发布条目重跑对应脚本补做 |
| 保留策略 | `.work/` 90 天，`reports/` 永久 | 已确认（2026-11-19） |
| 重试次数 | HTTP ≤6（指数退避）；LLM ≤3 | 401/403/404 不重试 |

---

## 7. 非功能需求

| 维度 | 要求 |
|---|---|
| 成本 | 单条 ≈ 1–2 次模型调用；默认 deep，输入更长（README + 目录树 + 3–5 文件）；`n=10` 运行前打印预估 |
| 时延 | 扫描 < 2 分钟；单条阅读 45–120 秒；`n=10` 约 15–25 分钟；支持中断续跑，不因长任务阻塞当天 |
| 可靠性 | 所有远端写入幂等；关键写入前留快照；单条失败不污染整轮；页面原子写入 |
| 安全 | 密钥只存 `gh.json` / `llm.json`（本期无 Actions）；日志与页面脱敏；PAT 采用最小权限（Lists 与发布仓库写权限） |
| 隐私 | README 与代码片段会发送给所配置的模型服务商；可切换私有端点；`-NoSummarize` 可只抓不总结 |
| 可移植 | 路径、仓库、List 名、模型、阈值全部配置化；`.ps1` 保持纯 ASCII，中文放 `.md`/`.json` 并以 UTF-8 读取 |
| 可维护 | 配置与提示词外置；脚本职责单一（scan / read / render / publish 可单独跑）；REQUIREMENTS / DESIGN / RUNBOOK 与代码同步更新 |
| 兼容性 | Windows 11 + PowerShell 5.1 + Node ≥18（本机 v24.20.0）；`gh` ≥2.40（本机 2.103.3，未装可用 PAT）；不引入 Python |
| 易用性 | 双击后 10 秒内出页面；扫描一键触发；失败原因直接显示在页面上，不必翻日志 |
| 本地服务 | 仅绑 `127.0.0.1`；`X-Joy-Token` + `Host` 校验防 CSRF / DNS rebinding；端口占用有明确提示；关闭窗口即释放 |

---

## 8. 验收标准

| 编号 | 场景 | 通过条件 |
|---|---|---|
| AC-1 | 首次接入 | 提供 `gh.json` 后运行扫描，自动创建 `unread` / `read` 两个 List，且新条目进入 `unread` |
| AC-2 | 幂等 | 同日扫描两次、扫描后立即再扫描，队列与 List 条目数不变 |
| AC-3 | 覆盖度 | 三个榜单的并集全部处理，日志满足 `scanned = added + 各跳过原因之和` |
| AC-4 | 输入校验 | `0` / `abc` / `21` 被拒绝，无任何远端写入 |
| AC-5 | 阅读顺序 | `run-joy.bat 3` 处理 unread List 前 3 个（List 顺序），与页面「待读」一致 |
| AC-6 | 总结质量 | 每条含全部固定字段；提到的文件均存在于 `sources`；无 README 时注明推断依据 |
| AC-7 | 页面可用 | 断网可打开、深色/打印/移动端正常、无乱码、无残留 Markdown 标记、注入文本被转义 |
| AC-8 | 状态迁移 | 发布成功后 unread 减少数 = read 增加数 = 本次发布成功数；只跑 `read.ps1`（不执行 render/publish/migrate）时收藏夹不变 |
| AC-9 | 发布 | Pages 地址可访问且与本地一致；`publish.ps1 -DryRun` / `-NoPush` 无远端变更 |
| AC-10 | 故障恢复 | 中断后重跑不重复计费；404/403/429 的错误信息包含具体原因与修复建议 |
| AC-11 | 控制台可用 | 双击 `joy.bat` 10 秒内打开；扫描后 2 秒内更新「上次扫描时间 / 新增 / 累计」；报告列表可点开；关闭窗口后端口释放 |
| AC-12 | 账号与密钥 | 未登录 → 设备码登录 → 显示用户名 → 退出恢复；API Key 保存后仅显示掩码；页面与日志无原文 |
| AC-13 | 报告结构 | 每张卡片第一段是单段话 `overview`，其后是 3–6 组问答；顺序为「功能 → 实现逻辑 → 元信息」 |
| AC-14 | 合规 | 单轮 star ≤25、请求串行且退避；不抓页面、不多账号、不绕限流（见第 11 节） |

---

## 9. 约束与假设

- 运行环境：Windows 11 + PowerShell 5.1 + Node ≥18（本机 `v24.20.0`）；服务只用 Node 标准库，**不执行 `npm install`**；
- `gh` 已安装（本机 2.103.3）但当前未登录，首次需走设备码授权；设备码必须由用户在浏览器完成，服务无法代劳；
- 端口 8787–8790 可用；浏览器为系统默认程序；
- **网络可能阻断 `github.com:443` 直连**（`api.github.com` 未必受影响），而 `gh` 不读取 Windows 系统代理，只认 `HTTPS_PROXY` / `ALL_PROXY` 环境变量；因此代理支持是必需能力（FR-14）；
- 账号：单人 GitHub 账号，Lists 为该账号私有数据；控制台不做多账号；
- **Lists 的 API 约束（需在 DESIGN 阶段核实）**：
  - `updateUserListsForItem` / `createUserList` 属用户级 GraphQL mutation，classic PAT 通常需要 `user` 作用域；fine-grained PAT 是否支持 Lists mutation 需实测；
  - Star Lists 的**条目顺序由 GitHub 维护**，API 未提供自定义排序，因此「当前顺序」以本地队列为准（见第 2 节术语）；
- Trending 是页面抓取，GitHub 改版会导致解析失败（设计上要求失败可见、快速修复）；
- GitHub API 有速率限制：扫描与阅读都应缓存元数据，避免重复请求；
- 模型需支持 OpenAI Chat Completions 兼容接口并能稳定输出 JSON；不支持 JSON mode 时用提示词 + 解析兜底；
- Pages：免费账号需公开仓库；本项目发布到本仓库 `docs/`，仓库公开意味着所有 `.md` 与历史提交一并公开（见 FR-8 的公开风险提示）；
- 不假设用户已安装 `gh` CLI；`gh` 仅作为人工排障工具；
- 不引入 Playwright（已确认 2026-11-19）：所有 GitHub 操作用 GraphQL / REST / git 完成；若将来出现必须浏览器才能做的事，再单独立项评估；

---

## 10. 决策记录（对应 `MEMORY.md` 第 7 节）

| # | 问题 | 本文建议默认 | 若选另一项的影响 |
|---|---|---|---|
| Q1 | unread / read 用 GraphQL Lists 吗 | ✅ **已定（2026-11-19）：用 GraphQL Lists** | 已排除本地队列 / Issues+标签 / Projects |
| Q2 | 是否同时 star 项目 | ✅ **已定（2026-11-19）：默认 star**，`-NoStar` 可关 | star 与 List 同时维护；本期不实现自动 unstar，取消 star 需手工 |
| Q3 | Trending 取数 | ✅ **已定（2026-11-19）：只用 Search API** | 不抓页面 → 无选择器维护，但排名口径与官方 Trending 不同，会漏掉「老仓库突然爆火」 |
| Q4 | 发布仓库 | ✅ **已定（2026-11-19）：本仓库 `docs/`，仓库需 public** | 仓库公开 → 全部文档与历史提交公开；需 `.nojekyll`；只 `git add` 页面文件 |
| Q5 | 每日扫描调度 | ✅ **已定（2026-11-19）：本期不做调度**，手动双击 `joy.bat` 或 `scan.bat` | 不引入 Actions / 任务计划，PAT 只留本机；需每天记得手动跑 |
| Q6 | n 上限 / HTML 保留 | ✅ **已定（2026-11-19）：上限 20、默认 5、`reports/` 永久保留** | 已写入 FR-4 / FR-6 |
| Q7 | 实现逻辑深度 | ✅ **已定（2026-11-19）：默认 deep**，`-Lite` 降级 | 成本与时长上升；`lite` 仅作降级选项 |
| Q8 | 是否用 Playwright 兜底 | ✅ **已定（2026-11-19）：不引入** | 全部走 GraphQL / REST / git；出现必须浏览器的需求再单独立项 |
| Q9 | 队列顺序 | ✅ **已定（2026-11-19）：FIFO 追加** | 新项目永远排尾；扫描不改动已有顺序 |
| Q10 | 迁移与发布的关系 | ✅ **已定（2026-11-19）：发布成功后才迁移** | Pages 失败时留在 unread；下次补发 + 补迁移，不重复调用模型 |
| Q11 | 页面是否提供「阅读 n 个」 | ✅ **已定（2026-11-19）：提供**，与 `run-joy.bat` 等价 | 已写入 FR-13 |
| Q12 | 登录方式优先级 | ✅ **已定（2026-11-19）：`gh` 登录优先，PAT 兜底** | 已写入 FR-14；未装 gh 时页面给 PAT 入口 |
| Q13 | `llm.json` 存储方式 | ✅ **已定（2026-11-19）：明文 + 仅当前用户 ACL** | 保存后 `icacls` 收紧；不引入 DPAPI，保持可移植 |
| Q14 | 报告 Q&A 组数 | ✅ **已定（2026-11-19）：3–6 组自适应** | 简单项目不注水，复杂项目可展开 |

> Q1–Q14 已全部确认（2026-11-19）。若 `DESIGN.md` 阶段发现某项不可行，回到本文件修改并升版本，不静默改实现。

> 10 个决策点已全部确认（2026-11-19）。若 `DESIGN.md` 阶段发现某项不可行，回到本文件修改并升版本，不静默改实现。

---

## 11. 账号风险与合规评估（2026-11-19）

**结论：按当前设计、单人正常使用，封号风险低。** 风险来自行为模式，不来自「用了 API」；红线集中在 star 频率、请求并发、是否抓页面、是否多账号。

| 行为 | 交互对象 | 风险 | 依据 / 缓解 |
|---|---|---|---|
| Search / REST / GraphQL 读取 | 官方 API | 低 | 认证后 Search 30 次/分钟、REST 5000 次/小时、GraphQL 5000 点/小时；每轮远低于配额，且串行 + 退避 |
| 写 Star | `PUT /user/starred/{owner}/{repo}` | 低–中 | 真人一天 star 几十个属正常；本设计单轮 ≤25、间隔 ≥1s、每日上限 100；只 star 榜单里实际要读的项目 |
| 写 Lists | GraphQL `updateUserListsForItem` | 低 | 官方 mutation；单批 ≤50、串行、失败退避 |
| 读 README / 目录树 / 文件 | REST + `raw` | 低 | 每轮仅 n 个仓库、每仓库十余个请求；有缓存计划 |
| 抓 Trending 页面 | — | 已消除 | Q3 改为只用 Search API：不解析 HTML、不模拟浏览器 |
| `gh auth login` 设备码 | 官方 OAuth | 无 | 官方流程，等同「在一台新设备登录」 |
| token 泄露 | 本地文件 | 中（间接） | 只存本机、不入日志、gh 令牌不落盘；泄露后立即在 GitHub 撤销 |
| 多账号 / 代理绕限流 / 刷 star | — | **禁止** | 明确不做；这些才是封号高发区 |

**明确不做（红线）**

1. 不为他人批量 star、不参与互 star、不使用任何「刷 star」脚本或服务；
2. 不注册 / 轮换多账号规避限额；
3. 不使用代理池或伪造 UA 绕过限流；
4. 不抓取需登录的页面、不模拟浏览器操作网页；
5. 不把 PAT 提交到仓库、写进文档或日志。

**仍需注意**

- 「不真实 star」是 GitHub 反作弊重点。本工具只 star 自己榜单里确实要读的项目，属个人收藏；若多人同时跑同一批仓库，行为特征会接近刷 star，风险显著上升——本期定位**单人自用**。
- GitHub 可能返回 **secondary rate limit**（403 并提示稍后再试），这不是封号：按 `Retry-After` 退避并在页面提示，不要立即重试轰炸。
- 若账号已因其他原因被标记，自动化会放大风险；出现异常先停用工具，改用网页手工核对。

---

## 附录 A：原始诉求 → 需求映射

| `MEMORY.md` 原始表述 | 对应需求 |
|---|---|
| 登录我的 GitHub，每天扫描 Trending（today/week/month），把没收藏的加入 unread | FR-1、FR-2、FR-3、FR-9 |
| 给我一个 bat，输入 n，从 unread 按顺序取前 n 个，逐个阅读，总结功能与实现逻辑，给链接，生成 HTML | FR-4、FR-5、FR-6 |
| 阅读后把项目移到 read 收藏夹 | FR-7 |
| HTML 挂到 GitHub 项目下，可通过 GitHub Pages 访问 | FR-8 |
| 双击 bat 启动服务、打开 localhost 页面，页面上扫描、看统计与报告列表 | FR-13 |
| 页面支持 GitHub CLI 登录/退出、模型 API Key 配置 | FR-13、FR-14 |
| 报告先一段话讲主要功能，再以问答讲实现逻辑 | FR-5、FR-6 |
| 会不会导致 GitHub 账号被封 | 第 11 节（设计约束与红线） |

## 附录 B：不在本期范围、但值得记录的想法

- 每日自动读（无需人工输入 n）：会放大成本与误读风险，暂不做；
- 按语言/主题过滤榜单（如只看 Rust）：`config.denylist` 已能部分实现，白名单后续再加；
- 生成周报/月报汇总（对一周简报做二次归纳）；
- 对同一项目做「star 增长曲线」跟踪；
- 阅读结果回写为 GitHub Issue 或 Gist。

## 附录 C：文档维护

- 本文件 v1.2：Q1–Q14 已确认；后续需求变更走版本递增（0.1 增量 → 1.x），并同步 `DESIGN.md` / `RUNBOOK.md`；
- 需求变更时同步更新：本文件、`DESIGN.md`、`RUNBOOK.md`、`README.md` 的状态段；
- 变更记录：

| 日期 | 版本 | 内容 |
|---|---|---|
| 2026-11-19 | 0.1 | 首版草稿：整理 FR-1～FR-12、业务规则、验收标准、待决问题 |
| 2026-11-19 | 1.0 | 确认 Q1–Q10：GraphQL Lists、默认 star、仅 Search API、本仓库 `docs/`、本期不调度、n 上限 20/默认 5/永久保留、默认 deep、不引入 Playwright、FIFO、发布成功才迁移；同步改写 FR-1 / FR-7 / FR-8 / FR-9 |
| 2026-11-19 | 1.1 | 需求变更：新增本地控制台 FR-13（Node 标准库服务、127.0.0.1、令牌与 Host 校验）、GitHub CLI 集成 FR-14；改写 FR-5（overview + Q&A）与 FR-6（卡片顺序）；新增第 11 节账号风险与合规评估；补充 Q11–Q14 |
| 2026-11-19 | 1.2 | 代理支持：FR-14 增加代理配置与自动探测；第 9 节记录「gh 不读系统代理」约束；实测 `github.com:443` 直连超时、代理 200 |
| 2026-11-20 | 1.3 | 按实际实现同步文档：干跑开关统一为实际存在的 `-DryRun` / `-NoWrite` / `-NoLlm` / `-NoPush` / `-NoStar`（`-NoPublish` / `-NoMark` / `-Repair` 未实现，文中移除）；明确队列不跨轮持久化、GitHub Lists 为唯一状态源；`run-joy.bat` 只做阅读（发布/迁移由控制台流水线或手动脚本完成）；概览统计改由 summaries / reports-index 派生；报告底部移除从未实现的「失败项与原因」区块（DESIGN D17） |
| 2026-11-21 | 1.4 | 明确 `unread` / `read` 条目不加入其它 Star List；迁移目标直接设为 `[read]`，不遍历所有 List；扫描只在候选 star 状态未知时遍历成员关系；新 star 后加入 unread 失败时补偿 unstar；未知状态无法核实时安全中止 |
| 2026-11-21 | 1.5 | FR-9 并发控制扩展为跨进程全局工作流锁：覆盖控制台与独立 bat/PowerShell 入口，read→render→publish→migrate 持锁贯穿；失效 owner 可恢复，冲突返回 workflow_busy / 退出码 6 |
