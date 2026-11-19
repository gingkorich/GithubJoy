# GitHub Joy · 实现设计（DESIGN）

| 项目 | 内容 |
|---|---|
| 文档版本 | 1.2（与 `REQUIREMENTS.md` v1.2 对应） |
| 更新日期 | 2026-11-19 |
| 对应实现 | `D:\AIproject\GithubJoy`（M1 已实现：`joy.bat`、`service/`、`scripts/probe-lists.ps1`；M2–M5 未实现） |
| 上游文档 | [`REQUIREMENTS.md`](REQUIREMENTS.md)（FR-1～FR-14、AC-1～AC-14） |
| 下游文档 | `RUNBOOK.md`（操作手册，待写） |

> 本文回答「怎么做」：模块边界、数据模型、接口契约、算法、失败处理。
> 凡是需求未覆盖而这里新增的决定，都在第 15 节「与需求的偏差」登记，并注明理由。

---

## 1. 总体架构

```
┌────────────┐   双击     ┌──────────────────────────────┐
│  joy.bat   │ ─────────▶ │ Node 本地服务 (127.0.0.1:8787)│
└────────────┘            │  · 静态页面 service/public    │
                          │  · JSON API /api/*            │
                          │  · 任务调度（单飞 + 文件锁）   │
                          └───────┬──────────────┬────────┘
                                  │ spawn        │ spawn
                                  ▼              ▼
                    ┌──────────────────┐   ┌──────────────┐
                    │ PowerShell 脚本层 │   │ gh CLI        │
                    │ scan / read /     │   │ auth login    │
                    │ render / publish  │   │ auth logout   │
                    │ migrate / status  │   │ auth token    │
                    └────────┬─────────┘   └──────┬───────┘
                             │                    │
                             ▼                    ▼
                  GitHub REST / GraphQL / raw   官方 OAuth 设备码
                             │
                             ▼
                      LLM（OpenAI 兼容）
```

**为什么分成 Node + PowerShell 两层**

| 层 | 职责 | 理由 |
|---|---|---|
| Node（`service/`） | HTTP 服务、页面、任务状态机、进程管理、日志尾部 | 标准库即可，无需 npm；长驻服务用 PowerShell 事件循环很难写 |
| PowerShell（`scripts/`） | GitHub 调用、LLM 调用、文件处理、git 推送 | 复用 `FreshRSS\data\briefings` 已验证的重试/编码/断点经验；`.ps1` 保持纯 ASCII |
| `gh` | 登录 / 退出 / 取令牌 | 不自己实现 OAuth 设备码；退出与多账号由官方工具兜住 |

**关键边界**：Node **不直接调用 GitHub API**。所有 GitHub 认证与请求集中在 `scripts/lib/github.ps1`，避免 Node 与 PowerShell 各写一套 token 逻辑。

---

## 2. 目录结构

```
D:\AIproject\GithubJoy\
├─ joy.bat                     # 主入口：起服务 / --stop / -Port / -NoOpen
├─ scan.bat                    # 无界面扫描（排障、批处理）
├─ run-joy.bat                 # 无界面阅读（-OnlyId / -IdsFile / -NoPublish / -Lite …）
├─ config.sample.json          # 入库的配置样例
├─ config.json                 # 本地配置（非密钥，可入库）
├─ gh.json                     # PAT + List 名 + 发布信息（gitignore）
├─ llm.json                    # 模型配置（gitignore，保存后 icacls 收紧）
├─ service/
│  ├─ server.js                # HTTP 服务、路由、安全校验（仅标准库）
│  ├─ jobs.js                  # 任务状态机、单飞锁、子进程管理
│  ├─ state.js                 # state.json / queue.json 读写
│  └─ public/
│     ├─ index.html
│     ├─ app.js
│     └─ style.css
├─ scripts/
│  ├─ scan.ps1                 # FR-1 / FR-2 / FR-3 / FR-9
│  ├─ read.ps1                 # FR-4 / FR-5
│  ├─ render.ps1               # FR-6（summaries → HTML）
│  ├─ publish.ps1              # FR-8
│  ├─ migrate.ps1              # FR-7（快照 / 迁移 / 回滚 / 补偿）
│  ├─ status.ps1               # 供服务查询：gh 状态、unread 总数（M2 起）
│  ├─ probe-lists.ps1          # M1：Lists 只读探针（验证 R2）
│  ├─ self-test.ps1            # 离线测试：fixtures → 去重 / 渲染 / 转义
│  ├─ lib/
│  │  ├─ config.ps1            # 配置读取（UTF-8 无 BOM，容忍 BOM）
│  │  ├─ http.ps1              # 超时 / 重试 / 退避 / 错误详情
│  │  ├─ github.ps1            # 认证解析、REST、GraphQL、raw
│  │  ├─ llm.ps1               # 提示词、调用、JSON 修复、审核降级
│  │  ├─ html.ps1              # 转义、模板渲染、卡片/索引
│  │  └─ log.ps1               # 日志与脱敏
│  └─ prompts/
│     ├─ summarize.system.txt
│     └─ summarize.user.tpl
├─ templates/
│  ├─ report.html.tpl
│  └─ index.html.tpl
├─ data/                       # gitignore
│  ├─ queue.json
│  ├─ state.json
│  ├─ trending-YYYY-MM-DD.json
│  ├─ summaries/<owner>__<repo>.json
│  ├─ jobs/<jobId>.json
│  ├─ state/lists-<RunId>.json
│  ├─ locks/scan.lock
│  ├─ service.json             # pid / port / startedAt
│  └─ service-token            # 每次启动重新生成
├─ reports/                    # 本地产物（gitignore）
├─ docs/                       # 本仓库发布目录（Pages 源）
│  ├─ REQUIREMENTS.md / DESIGN.md / RUNBOOK.md
│  ├─ .nojekyll                # 必须提交
│  └─ *.html                   # 由 reports/ 复制，入库
├─ logs/
└─ .work/run-<RunId>/          # 每轮原始材料（gitignore）
```

> `docs/` 既是文档目录又是 Pages 根目录：生成器只写 `docs/*.html`，不碰 `.md`；发布时 `git add` 显式列文件。

---

## 3. 数据模型

所有 JSON：UTF-8 **无 BOM** 写入，读取时容忍 BOM；每个文件带 `version` 便于将来迁移。

### 3.1 `data/queue.json`

```json
{
  "version": 1,
  "updatedAt": "2026-11-19T12:00:00Z",
  "seq": 137,
  "items": [
    {
      "id": "owner/name",
      "fullName": "Owner/Name",
      "seq": 135,
      "status": "pending",
      "addedAt": "2026-11-19T08:02:11Z",
      "scannedFrom": [
        { "period": "today", "rank": 3, "query": "created:>=2026-11-18 stars:>=30" }
      ],
      "repo": {
        "nodeId": "R_kgDOxxxx",
        "description": "…",
        "language": "Go",
        "stars": 1234,
        "forks": 88,
        "topics": ["cli"],
        "archived": false,
        "pushedAt": "2026-11-18T09:00:00Z"
      },
      "list": { "inUnread": true, "inRead": false, "otherListIds": [] },
      "starred": true,
      "starSkipped": null,
      "attempts": 0,
      "lastError": null,
      "summaryPath": null,
      "published": false,
      "publishedUrl": null,
      "movedAt": null
    }
  ]
}
```

- `seq` 单调递增，是「当前顺序」的唯一依据（FIFO，已确认）。
- `status` 取值与流转见 3.6。
- `otherListIds` 用于迁移时保留用户手工加的其它 List（见 5.4）。

### 3.2 `data/trending-YYYY-MM-DD.json`

```json
{
  "version": 1,
  "date": "2026-11-19",
  "source": "search",
  "periods": [
    { "period": "today", "query": "created:>=2026-11-18 stars:>=30 archived:false fork:false",
      "sort": "stars", "perPage": 25, "totalCount": 1043, "fetchedAt": "…" }
  ],
  "items": [
    { "fullName": "Owner/Name", "period": "today", "rank": 1, "stars": 999, "language": "Rust",
      "description": "…", "createdAt": "…", "pushedAt": "…", "archived": false }
  ]
}
```

### 3.3 `data/summaries/<owner>__<repo>.json`

```json
{
  "version": 1,
  "id": "owner/name",
  "mode": "deep",
  "overview": "一段话，80–150 字……",
  "qa": [
    { "q": "入口与整体调用链是怎样的？",
      "a": "……",
      "refs": ["cmd/main.go", "internal/app/run.go"] }
  ],
  "stack": { "language": "Go", "frameworks": ["cobra"], "build": "go build ./cmd/main" },
  "useCases": ["……"],
  "risks": ["……"],
  "sources": [
    { "path": "README.md", "chars": 12345, "truncated": false },
    { "path": "cmd/main.go", "chars": 8123, "truncated": false }
  ],
  "model": "deepseek-chat",
  "generatedAt": "2026-11-19T20:31:00Z",
  "warnings": []
}
```

### 3.4 `data/state.json`

```json
{
  "version": 1,
  "lastScan": {
    "runId": "scan-20261119-080211", "at": "2026-11-19T08:02:11Z", "durationMs": 41230,
    "scanned": 75, "added": 8,
    "skipped": { "already_unread": 30, "already_read": 12, "already_done": 0, "denied": 25 },
    "totalUnreadAfter": 23
  },
  "lastRead": { "runId": "read-20261119-203001", "n": 5, "succeeded": 4, "failed": 1, "at": "…" },
  "unreadTotal": { "count": 23, "refreshedAt": "2026-11-19T20:46:12Z" }
}
```

### 3.5 `data/jobs/<jobId>.json`

```json
{
  "version": 1,
  "id": "scan-20261119-080211",
  "kind": "scan",
  "state": "running",
  "startedAt": "…", "endedAt": null,
  "pid": 12345,
  "args": { "n": null, "noPublish": false },
  "progress": { "phase": "search", "done": 1, "total": 3 },
  "logFile": "logs/scan-2026-11-19.log",
  "exitCode": null,
  "result": null,
  "error": null
}
```

任务结束后 `state` 为 `succeeded` / `failed` / `cancelled`，`result` 写扫描或阅读的统计对象。

### 3.6 队列状态机

```
            ┌──────────┐  取前 n   ┌────────────┐  写 summary  ┌──────┐
 入队 ────▶ │ pending  │ ────────▶ │ summarizing│ ───────────▶ │ done │
            └──────────┘           └────────────┘              └──┬───┘
                 ▲                        │ 失败（可重试）          │ 发布成功 + 迁移成功
                 │                        ▼                        ▼
                 └────────────────────  failed ◀── 429/超时    moved
                                          │
                                          └─ 404 仓库消失 ─▶ gone
```

- `done` 且 `published=false`：摘要已生成、尚未发布 → 下次运行先补发（FR-7）。
- `moved`：终态，不再参与任何选择。
- `failed`：`seq` 不变，下次正常运行会再次被选中；超过 `maxAttempts`（默认 3）后停用，需 `-OnlyId` 手动重试。

---

## 4. 扫描流程（FR-1 / FR-2 / FR-3）

### 4.1 步骤

```
1. 读配置 → 校验（gh 只用于登录态，不强制安装）
2. 取令牌：gh auth token → 失败则 gh.json.token → 都无 → 退出码 2
3. 三个周期各发一次 Search（串行，间隔 300ms）
4. 校验：任一周期 totalCount=0 或 items=0 → 本轮失败，不写快照、不覆盖旧文件
5. 写 data/trending-<date>.json
6. 合并去重 → 过滤 → 候选（4.2 / 4.3）
7. 查询 Lists（unread / read 全量翻页）建立 fullName → listIds 索引
8. 新条目：star（受 4.4 限制）→ 写 queue(pending) → 加入 unread（替换语义，4.5）
9. 写 state.lastScan 与 jobs/<id>.json，打印统计
```

### 4.2 查询构造

```
today : created:>=<UTC 今天-1 天>  stars:>100   archived:false fork:false
week  : created:>=<UTC 今天-7 天>  stars:>2000  archived:false fork:false
month : created:>=<UTC 今天-30 天> stars:>5000  archived:false fork:false
公共参数：sort=stars&order=desc&per_page=25
```

- 日期按 **UTC 自然日**（`yyyy-MM-dd`），避免本地时区把「今天」算成两天。
- 阈值与条数来自 `config.search.minStars` / `perPage`。
- 只取第一页：25 条/周期足够，也避免翻页吃配额。

### 4.3 去重与排序

```
候选 = 三周期并集
key  = fullName.ToLowerInvariant()
每 key 保留 scannedFrom[]（周期 + 名次）与首次出现的周期（today > week > month）
同 key 多条：只入队一次，名次全部记录
排序：按 seq 追加（FIFO），不因今天名次高而插队
过滤（按此顺序，逐项计数）：
  1) 已在 read                → already_read
  2) 已在 unread              → already_unread
  3) queue 中 done / moved    → already_done
  4) 命中 denylist            → denied
  5) 已 star（viewerHasStarred，批量 25/次）→ starred
  6) 否则进入选择池
```

**选择（2026-11-19 修订）**：

```
按 star 降序排列选择池
按周期配额取：today 5 / week 8 / month 12（归属取 firstPeriod）
不足 25 → 剩余候选按 star 降序补齐
每轮上限 25；且不超过「每日剩余 star 额度」= 100 − 当日已 star
队列按选择顺序追加（today → week → month → 补齐）
```

`denylist` 支持：`owners[]`、`repos[]`、`languages[]`、`keywords[]`（对名称+描述做小写包含匹配）。

### 4.4 star 限流（`REQUIREMENTS.md` 第 11 节）

```
newItems 按 seq 升序：
  if starredThisScan >= config.star.maxPerScan (25) → starSkipped = "cap_per_scan"
  if starredToday   >= config.star.maxPerDay  (100) → starSkipped = "cap_per_day"
  否则 PUT /user/starred/{owner}/{repo}
       204 → starred=true；304/已 star → 视为成功
       403/429 → 记录错误，退避后最多重试 2 次
  每次请求后 sleep config.star.intervalMs (1000)
```

- star 失败不是致命错误：条目已入 unread，下次扫描因 `already_unread` 不会重复处理。
- 补 star 用 `-RepairStar`（可选，不在 MVP 验收内）。

### 4.5 Lists 写入（语义已按官方 schema 核实）

```graphql
mutation AddToUnread($itemId: ID!, $listIds: [ID!]!) {
  updateUserListsForItem(input: { itemId: $itemId, listIds: $listIds }) {
    item { ... on Repository { nameWithOwner } }
    lists { id name }
  }
}
```

**关键**：该 mutation 是「设置该条目所属的 List 集合」——**整体替换**。`itemId` 是仓库的 node ID（schema 中 `union UserListItems = Repository`）。

所以 `listIds` 必须 = `unread` + 该条目当前所属的其它 List；否则会清掉用户手工归类。

**实测约束（2026-11-19）**：Star Lists **只保留已 star 的仓库**。用 `-NoStar` 先写 List，5 个条目在约 1 小时后从 `unread` 消失（40 → 35），且这 5 个 `viewerHasStarred=false`；剩余 35 个全部为 true。因此流程固定为「**先 star，再写 List**」，`-NoStar` 时跳过 List 写入并告警；队列中 `inUnread=false` 的条目会在下次运行时由 `toEnsure` 重试（补 star + 补 List）。

读取成员关系的高效做法（每次扫描只做一次）：

```graphql
query ListIndex($cursor: String) {
  viewer {
    lists(first: 20, after: $cursor) {
      pageInfo { hasNextPage endCursor }
      nodes {
        id name
        items(first: 100) {
          pageInfo { hasNextPage endCursor }
          nodes { ... on Repository { nameWithOwner } }
        }
      }
    }
  }
}
```

- 外层遍历所有 List，内层翻页直到 `hasNextPage=false`；
- 建立 `nameWithOwner(lower) → [listId…]`；
- List 名冲突（重名）时取 `createdAt` 最早的一个并写 `warnings`；
- 未找到 `unread`/`read` 时各创建一次（`createUserList`），创建结果写日志，不删除任何已有 List。

### 4.6 统计（日志与 state 用同一份数字）

```
scanned = added + already_unread + already_read + already_done + denied
starred / starSkippedCap / starFailed
listsCreated / listAddFailed
```

---

## 5. 阅读、总结、发布、迁移

### 5.1 一轮 read 的顺序

```
1. 选条目：pending 前 n（或 -OnlyId / -IdsFile）→ 先落盘置 summarizing
2. 逐条：抓材料 → LLM → 校验 → 写 summaries/<id>.json（断点）→ 置 done
   失败：置 failed、记录 lastError，继续下一条
3. 全部处理完（含失败）→ render.ps1 生成本轮 HTML（含失败项说明）
4. publish.ps1：复制到 docs/ + .nojekyll → git add 指定文件 → commit → push
5. 发布成功 → migrate.ps1：快照 → 逐条迁移 → 置 moved
   发布失败 → 保留 done/published=false，退出码非 0，不迁移
```

**为什么先落 summary 再渲染**：LLM 是唯一按条计费且最慢的步骤；summary 文件是断点，渲染与发布可任意重跑。

### 5.2 材料抓取

| 材料 | 接口 | 上限 | 说明 |
|---|---|---|---|
| 仓库元数据 | `GET /repos/{o}/{r}` | — | 同时取 `node_id`（Lists 用）、`license`、`pushed_at`、`archived`、`default_branch` |
| README | `GET /repos/{o}/{r}/readme`（`Accept: application/vnd.github.raw`） | 20,000 字符 | 404 / 非文本 → `no_readme` |
| 目录树 | `GET /repos/{o}/{r}/git/trees/{branch}?recursive=1` | 200 项 | 过滤 `node_modules/`、`dist/`、`vendor/`、`build/`、图片/字体/二进制 |
| 关键文件 | `GET /repos/{o}/{r}/contents/{path}`（raw） | 3–5 个，每个 ≤8,000 字符 | 仅 deep 模式 |

**关键文件挑选（纯规则、可解释，不引入模型打分）**

```
score = 0
+3  路径匹配入口名：main.*、index.*、app.*、cli.*、server.*、cmd/*
+2  路径匹配配置：package.json、pyproject.toml、Cargo.toml、go.mod、Makefile、docker*
+2  路径在 README 中原样出现
+1  位于 src/ 或 lib/ 且深度 ≤3
-5  测试、示例、文档、资源目录
排除：>200KB、二进制扩展名、*.min.*
deep: 取 top 3–5；lite: 取 0
```

所有请求带：`Accept: application/vnd.github+json`、`X-GitHub-Api-Version: 2022-11-28`、`User-Agent: GithubJoy/1.1`；超时 20s；ETag 缓存到 `data/cache/`（可选，命中则 304 省配额）。

### 5.3 LLM 调用与校验

- 输入预算：README 20k + 目录树 6k + 关键文件 ≤40k ≈ 66k 字符（约 20k tokens）。超过 `config.llm.maxInputChars`（默认 70,000）按「关键文件 → 目录树 → README 尾部」截断，并在 `sources[].truncated` 标记。
- 输出契约（严格 JSON，不允许 Markdown 包裹）：

```json
{
  "overview": "…",
  "qa": [{ "q": "…", "a": "…", "refs": ["src/a.ts"] }],
  "stack": { "language": "…", "frameworks": ["…"], "build": "…" },
  "useCases": ["…"],
  "risks": ["…"]
}
```

- 校验（失败则带错误清单重问一次，`llm.ps1` 内实现）：

| 规则 | 处理 |
|---|---|
| JSON 可解析（去 ``` 围栏、取首 `{` 到末 `}`、容忍 BOM） | 失败 → 修复重试 1 次 |
| `overview` 为字符串、80–150 字、不含 `- ` / `1. ` 列表标记 | 违规 → 重问并指出违规点 |
| `qa` 3–6 组，`q`/`a` 非空，`a` 为 2–4 句 | 违规 → 重问 |
| `refs` 路径必须存在于 `sources` | 不存在的**直接删除**并写 `warnings`（不重问） |
| 正文出现 `sources` 外的文件名（正则 `[\w./-]+\.(go|py|ts|js|tsx|jsx|rs|java|rb|php|md|toml|json|yml)`） | 重问一次；仍出现则删除该句并写 `warnings` |
| 空话（「非常优秀」「值得一试」单独成句） | 重问 |

- 内容审核 / 安全拦截：输入 60% → 30% 逐级降级；每次降级写 `warnings` 与 `moderation.log`，仍失败则该条 `failed`（不写空 summary）。
- `temperature` 默认 0.2；服务端 400 报不支持该参数时去掉重试一次。
- 网络类失败（超时 / 5xx / 429）按 2s / 4s / 8s 退避，最多 3 次。

### 5.4 迁移（FR-7，依赖 4.5 的替换语义）

```graphql
mutation MoveToList($itemId: ID!, $target: [ID!]!) {
  updateUserListsForItem(input: { itemId: $itemId, listIds: $target }) {
    lists { id name }
  }
}
# $target = (该条目当前所属 List − unread) + read
```

- **一次调用**完成「移出 unread + 加入 read」，比「先删后加」少一个中间态；但因为是替换语义，`$target` 必须包含其它 List。
- 迁移前写 `data/state/lists-<RunId>.json`：

```json
{ "runId": "read-20261119-203001", "capturedAt": "…",
  "unread": ["owner/a", "owner/b"], "read": ["owner/c"], "lists": [{"id":"L_1","name":"unread"}] }
```

- `-Rollback <RunId>`：按快照把 `moved` 条目的 `listIds` 恢复为「unread + 其它」，状态改回 `done`；`published` 保持 true，避免重复发布。
- 单条失败：`lastError` 记录，状态保持 `done`，下次 `-Repair` 或正常运行时补迁移；**不重复调用 LLM**。
- 迁移顺序：按 `seq` 升序逐条，间隔 300ms；整批失败率 >50% 时中止并提示（可能是 scope 或限额问题）。

### 5.5 发布（FR-8）

```
publish.ps1 -RunId <id> [-NoPublish]
  1. 校验 gh.json.publish（repo / branch / dir / baseUrl）
  2. 复制 reports/<run>.html、latest.html、index.html → docs/
  3. 确保 docs/.nojekyll 存在（不存在则创建并加入提交）
  4. git fetch origin
     本地落后或分叉 → 中止，打印「先手动 pull / 处理冲突」；不自动 rebase
  5. git add -- docs/<file>.html docs/latest.html docs/index.html docs/.nojekyll
  6. git diff --cached --quiet → 无变化则跳过 commit（但仍视为发布成功）
  7. git commit -m "joy: <yyyy-MM-dd> n=<n>"
  8. git push origin main
  9. 失败：本地产物保留，输出可执行建议，退出码 3
```

- **禁止** `git add -A`；`git status --porcelain` 中与本轮无关的改动只提示、不提交。
- 推送后不等待 Pages 构建（通常 10–60 秒）；state 记录 `pushedAt`，页面文案只写「已推送」不写「已上线」。
- `-NoPublish`：只到第 2 步之前的本地产物，不复制、不提交、不推送，且不触发迁移。

---

## 6. 本地服务（FR-13 / FR-14）

### 6.1 进程与生命周期

```js
// 伪代码
const server = http.createServer(router);
server.listen(port, '127.0.0.1', () => {
  writeJson('data/service.json', { pid: process.pid, port, startedAt });
  if (!noOpen) exec(`start "" "http://127.0.0.1:${port}/"`);   // 仅 Windows
});
```

- 端口：默认 8787 → 8788 → 8789 → 8790；全被占用则 `console.error` + `exit(4)`。
- 退出：`SIGINT` / 窗口关闭 → 结束子进程（杀 job 的 pid）→ 删除 `data/service.json` 与 `data/locks/*.lock`。
- `joy.bat --stop`：读 `service.json` → `taskkill /PID <pid> /T /F` → 失败则清理文件并提示「服务未在运行」。
- 只绑 `127.0.0.1`（`server.listen(port, '127.0.0.1')`），不提供局域网访问。

### 6.2 路由与接口契约

| 方法 | 路径 | 请求 | 响应 |
|---|---|---|---|
| GET | `/` | — | `public/index.html`（注入 `__JOY_TOKEN__` 与 `__PORT__`） |
| GET | `/app.js`、`/style.css` | — | 静态资源（白名单扩展名） |
| GET | `/api/status` | — | 见下方示例 |
| POST | `/api/scan` | `{}` | `202 { "jobId": "scan-…" }`；已有任务 → `409 {error:"busy"}` |
| POST | `/api/read` | `{"n":5,"noPublish":false}` | `202 {jobId}`；`n` 越界 → `400` |
| GET | `/api/jobs/<id>` | `?tail=200` | `{ job, lines:[…] }` |
| POST | `/api/jobs/<id>/cancel` | — | `200 {state:"cancelled"}` |
| GET | `/api/reports` | — | `[{file,size,mtime,entries,published,url}]` |
| GET | `/api/reports/<file>` | — | HTML（仅 `reports/` 下 `*.html`） |
| GET | `/api/gh/status` | — | `{installed,version,auth,login,scopes,source}` |
| POST | `/api/gh/login` | — | `202 {jobId}`（设备码从 job lines 读取） |
| POST | `/api/gh/logout` | — | `200 {ok:true}` / `500 {error}` |
| GET | `/api/llm` | — | `{baseUrl,model,timeoutSec,keyMask,configured}` |
| PUT | `/api/llm` | `{baseUrl,model,apiKey?,timeoutSec?}` | `200 {ok,keyMask}`；校验失败 `400` |
| POST | `/api/llm/test` | — | `{ok,latencyMs,status,error?}` |

> 模型配置的读写由 Node 完成：`PUT` 校验后原子写入 `llm.json`，并用 `icacls` 只授当前用户 `(F)`（Windows 下替换文件需要删除权限，只给 `(R,W)` 会导致 rename 报 EPERM）；`/api/llm/test` 由 Node 直接 `fetch` 模型的 `/chat/completions`（不走 GitHub API），**不发送 `temperature`**（部分路由模型如 `auto` 会直接 400 拒绝该参数），只返回状态与截断后的错误，不落盘。

`GET /api/status` 示例：

```json
{
  "service": { "version": "1.1", "port": 8787, "startedAt": "…", "workDir": "D:\\AIproject\\GithubJoy" },
  "gh": { "installed": true, "version": "2.103.3", "auth": true, "login": "gingko", "scopes": "repo,read:org,gist,user" },
  "scan": { "lastAt": "2026-11-19T08:02:11Z", "durationMs": 41230, "added": 8, "scanned": 75, "error": null },
  "unread": { "count": 23, "refreshedAt": "2026-11-19T20:46:12Z" },
  "queue": { "pending": 18, "done": 4, "failed": 1, "gone": 0, "moved": 52 },
  "llm": { "configured": true, "baseUrl": "https://api.deepseek.com/v1", "model": "deepseek-chat", "keyMask": "sk-****9f2c" },
  "job": { "id": "scan-…", "kind": "scan", "state": "running", "progress": { "phase": "lists", "done": 20, "total": 75 } }
}
```

### 6.3 任务运行器

- 单飞：`data/locks/<kind>.lock`（内容 `{pid, jobId, startedAt}`）。启动任务前：
  - 锁存在且 pid 存活 → `409 busy`；
  - 锁存在但 pid 已死 → 视为残留，删除后继续（写日志）。
- 启动：

```
spawn('powershell.exe', ['-NoProfile','-ExecutionPolicy','Bypass','-File','scripts\\scan.ps1',
      '-JsonOut','data\\jobs\\<id>.result.json','-LogFile','logs\\scan-<date>.log'])
```

- 输出：stdout / stderr 同时追加到 `logFile`，并进入内存环形缓冲（最近 500 行）供 `/api/jobs/<id>?tail=200` 返回。
- 进度：脚本在 stdout 输出单行 JSON 事件 `{"evt":"progress","phase":"lists","done":20,"total":75}`，服务解析后更新 `jobs/<id>.json`；非 JSON 行原样进日志。
- 结束：退出码 0 → `succeeded`；非 0 → `failed`，错误取 `.result.json.error` 或 stderr 末尾 20 行；`.result.json` 缺失也算失败（防脚本中途崩溃被误判成功）。
- 取消：`child.kill()`（Windows 用 `taskkill /T`）；写出 `cancelled`，**不删除** `.work/` 与已生成的 summary（可续跑）。

### 6.4 本地安全（与 FR-13 一致，这里是实现细节）

| 项 | 实现 |
|---|---|
| 绑定 | `server.listen(port, '127.0.0.1')`；启动日志打印实际地址 |
| 令牌 | `crypto.randomBytes(24).toString('hex')` → `data/service-token`；首页以 `<meta name="joy-token">` 注入；写操作校验 `X-Joy-Token`（`timingSafeEqual`） |
| Host | 允许 `127.0.0.1:<port>`、`localhost:<port>`；其他 → 403 |
| Origin | 若存在 `Origin`，必须等于 `http://127.0.0.1:<port>` 或 `http://localhost:<port>`；缺失（curl）则只看 Token |
| 方法 | 只允许 GET/POST/PUT；其他 → 405 |
| 请求体 | ≤64KB，`Content-Type: application/json`，解析失败 → 400 |
| 路径 | `/api/reports/<file>`：只接受 `[A-Za-z0-9._-]+\.html`，`path.resolve` 后必须仍在 `reports/`；拒绝 `..`、绝对路径、符号链接 |
| 静态 | 只服务 `service/public` 白名单扩展名（`.html/.js/.css/.svg/.ico`） |
| 响应头 | `X-Content-Type-Options: nosniff`、`X-Frame-Options: DENY`、`Referrer-Policy: no-referrer`、`Content-Security-Policy: default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; form-action 'none'; base-uri 'none'` |
| 密钥 | 任何响应都不含 `api_key` / token 原文；`llm` GET 返回 `keyMask` |

### 6.5 GitHub CLI 集成（FR-14）

| 动作 | 命令 | 解析 |
|---|---|---|
| 检测 | `gh --version` | 取版本号；未安装 → `installed=false` |
| 状态 | `gh auth status --hostname github.com --json hosts` | 退出码 1 且 stderr 含 "not logged"→ 未登录（不报错）；成功则取 `hosts["github.com"][0]` 的 `login`、`scopes`、`state` |
| 登录 | `gh auth login --hostname github.com --git-protocol https --web --scopes "user"` | 逐行扫描 `/\b[A-Z0-9]{4}-[A-Z0-9]{4}\b/` 提取设备码，推入 job lines；页面显示「代码 + 打开 device 页」 |
| 退出 | `gh auth logout --hostname github.com` | 退出码 0 → 清 `login`；非 0 原样返回 stderr |
| 取令牌 | `gh auth token --hostname github.com` | 只放内存 / 传给脚本的临时环境变量，**不落盘** |

- 登录子进程：`stdio: ['pipe','pipe','pipe']`，监听 stdout/stderr；5 分钟超时 → `taskkill` 并置 `failed`，页面按钮恢复。
- 若 gh 输出「Press Enter to open…」类提示且等待 stdin：向 stdin 写 `\r\n`（最多 3 次，间隔 2s）。
- 登录成功后服务主动刷新 `/api/gh/status` 并从 `viewer.login` 取一次用户名。
- gh 不可用：页面显示安装命令与「使用 PAT」入口（写入 `gh.json.token`，保存时 `icacls` 收紧）。
- **scope 说明**：`--scopes "user"` 是追加；最终 scope 预期为 `repo, read:org, gist, user`。若 Lists mutation 报 `INSUFFICIENT_SCOPES`，页面提示重新登录并显示所需 scope（见本文第 13 节 R2）。
- **代理**：`gh` 只读 `HTTPS_PROXY` / `HTTP_PROXY` / `ALL_PROXY`，不读 Windows 系统代理（`Internet Settings`）。服务启动时解析 `config.network.proxy`；为空且 `autoDetect=true` 时读注册表 `ProxyEnable` + `ProxyServer`，归一化为 `http://host:port`（支持 `socks5://`），并缓存 60 秒。所有 `gh` 子进程与 Lists 探针都通过 `childEnv()` 注入同一代理；`NO_PROXY=localhost,127.0.0.1` 保证本地回环不走代理。状态接口返回 `network: {proxy, source, autoDetect}`，页面显示「直连 / 系统代理 / 配置」。

### 6.6 页面（`service/public`）

单页三段式布局，原生 JS（无框架、无构建）：

```
┌─ header: 登录名 / GitHub 主页 ↗ | 服务版本 | 数据目录 ─────────┐
├─ 概览卡片（4 格）：上次扫描 | 本次新增 unread | 累计 unread | 待读 ─┤
├─ 操作区： [立即扫描]   [阅读 __ 个]   ← 运行中显示进度条 + 日志尾部 ─┤
├─ 报告列表：文件名 | 生成时间 | 大小 | 条目数 | 已发布 | 打开 ───────┤
├─ 账号区： [使用 GitHub 登录] / 用户名 + [退出登录] ────────────────┤
└─ 模型区： base_url | model | api_key(密码) | [保存] [测试连接] ─────┘
```

- 轮询：`/api/status` 每 3 秒；有运行中任务时 `/api/jobs/<id>?tail=100` 每 1 秒。
- 所有写操作先读 `<meta name="joy-token">` 放入 `X-Joy-Token`。
- 错误就地显示在对应区域（红色条），不弹 alert；令牌缺失（403）时提示「请在 joy.bat 启动的页面中操作」。
- 表单保存成功后只在输入框显示掩码，不回填明文。

---

## 7. 报告渲染（FR-5 / FR-6）

### 7.1 渲染管线

```
summaries/*.json + queue.json + 本轮 job
        │
        ▼  render.ps1（lib/html.ps1）
data/reports-index.json  ◀── 追加本轮条目
        │
        ▼  templates/report.html.tpl + index.html.tpl
reports/<date>-n<n>.html、reports/latest.html、reports/index.html
```

- 模板用 `{{TOKEN}}` 占位，代码侧拼好 HTML 片段再替换；**不使用** PowerShell 的 `-f` 格式串（花括号易冲突）。
- `data/reports-index.json` 是索引的唯一数据源（不反向解析 HTML）：

```json
[{ "file": "2026-11-19-n5.html", "date": "2026-11-19", "n": 5, "count": 4,
   "failed": 1, "createdAt": "…", "published": true,
   "url": "https://<login>.github.io/GithubJoy/2026-11-19-n5.html" }]
```

### 7.2 转义规则（硬要求）

```powershell
function ConvertTo-HtmlText([string]$s) {
  if ($null -eq $s) { return '' }
  $t = $s -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' `
          -replace '"', '&quot;' -replace "'", '&#39;'
  $t = $t -replace "`r`n", '<br>' -replace "`n", '<br>'
  return $t
}
```

- **先转义、再换行转 `<br>`**，因此 `<br>` 是唯一被放行的标签，不存在「先放行再转义」的绕过路径。
- README 里的 Markdown/HTML 一律按纯文本展示；不做 Markdown 渲染。
- 属性值（链接 `href`）额外校验：只允许 `https://github.com/`、`https://raw.githubusercontent.com/`、`https://<login>.github.io/` 前缀，其他丢弃。
- 单测用例（`self-test.ps1`）：`<script>alert(1)</script>`、`"><img src=x onerror=1>`、`&amp;`、`</style>`、含 U+2028、超长单行。

### 7.3 卡片结构（顺序固定）

```html
<article class="card">
  <h2><a href="{repoUrl}">owner/name</a> <span class="lang">Go</span> <span class="stars">★ 1.2k</span></h2>
  <p class="overview">{overview 一段话}</p>
  <section class="qa">
    <h3>实现逻辑</h3>
    <details open><summary>Q1 · {问题}</summary><p>{回答}</p></details>
    …
  </section>
  <dl class="meta">
    <dt>技术栈</dt><dd>…</dd>
    <dt>适用场景</dt><dd><ul><li>…</li></ul></dd>
    <dt>风险</dt><dd>…</dd>
    <dt>来源</dt><dd>today #3 · 已读源码 · 抓取 6 个文件</dd>
  </dl>
</article>
```

- 首条 `details` 默认展开，其余折叠；打印时用 `@media print { details > * { display: block } }` 强制全展开。
- 顶部统计条：日期、n、成功/失败、周期分布、模式、耗时、`source=search` 口径说明。
- 底部：失败项与原因、生成时间、RunId、Pages 链接（仅 `published=true` 时）。

### 7.4 样式与可访问性

- 单文件内联 `<style>`：CSS 变量定义浅/深两套色（`prefers-color-scheme`）；正文最大宽度 860px；移动端单列。
- 打印：隐藏导航与折叠控件、卡片 `break-inside: avoid`、链接附 URL。
- 无 JavaScript；`<html lang="zh-CN">`；标题层级 h1 → h2（卡片）→ h3（问答）。
- 所有图片不加载（README 图片不渲染），避免外部请求与隐私泄露。

---

## 8. 错误处理与重试（FR-11）

### 8.1 退出码约定

| 码 | 含义 | 典型场景 |
|---|---|---|
| 0 | 成功（含「无变化」） | 扫描完成、发布无 diff |
| 1 | 通用失败 | 脚本异常、磁盘错误 |
| 2 | 配置 / 认证失败 | 缺 `gh.json`、token 无效、无 scope |
| 3 | 发布失败 | 分叉、无写权限、分支保护 |
| 4 | 服务启动失败 | 端口全占用、Node 版本过低 |
| 5 | 部分成功 | n 条里部分失败（页面照常生成） |

### 8.2 HTTP 重试矩阵

| 状态 / 现象 | 判定 | 处理 |
|---|---|---|
| 401 | token 失效 | 不重试；提示重新登录或换 PAT |
| 403 + `INSUFFICIENT_SCOPES` | scope 不足 | 不重试；提示所需 scope |
| 403 + "secondary rate limit" / `Retry-After` | 二级限流 | 按 `Retry-After` 或 60s 退避，最多 3 次；页面提示「已限流，稍后重试」 |
| 403（其他） | 权限 | 不重试；打印响应体 `message` |
| 404 | 仓库消失/改名 | 该条 `gone`，移出选择范围；不重试 |
| 422 | 查询非法 | 不重试；打印 query 与响应体（设计缺陷，需修代码） |
| 429 | 主限流 | 退避 60s / 120s / 240s，最多 3 次 |
| 5xx / 超时 / DNS | 瞬时 | 2s / 4s / 8s 退避，最多 3 次 |

### 8.3 GraphQL 错误

- 响应含 `errors[]` 时**不吞异常**：遍历取 `type`（`NOT_FOUND`/`FORBIDDEN`/`INSUFFICIENT_SCOPES`/`RATE_LIMITED`）与 `message`；
- `NOT_FOUND`（List 被删 / 仓库没了）→ 重新拉一次 List 索引后重试一次，仍失败则该条失败；
- 其余按 8.2 的对应码处理；
- 所有 GraphQL 错误把 `message` 写进日志（脱敏后），不写 token。

### 8.4 其他

| 场景 | 处理 |
|---|---|
| LLM 返回非 JSON | 去围栏/取首尾大括号 → 失败则带错误清单重问 1 次 → 仍失败记 `failed` |
| LLM 内容审核 | 输入 60% → 30% 降级；仍失败记 `failed` + `warnings` |
| 磁盘写满 / 权限 | 中止本轮，保留已写文件；退出码 1，页面显示错误原文 |
| git 未配置 user.name/email | 提示具体命令（`git config --local user.name …`），不自动改全局配置 |
| 发布时本地分叉 | 中止（退出码 3），提示手工处理；**不** `reset`/`rebase` |
| 网络直连失败（`wsarecv` / `connection attempt failed` / 超时） | 登录任务置 `failed` 并给 `hint=network`；页面提示检查 `config.network.proxy` 或系统代理（RUNBOOK 6.11） |
| 页面轮询时任务已结束 | 返回终态 + `result`，前端停止轮询 |

---

## 9. 幂等、断点续跑与崩溃恢复

### 9.1 幂等点

| 动作 | 幂等方式 |
|---|---|
| 扫描 | 以 `fullName` 去重；已入队/已收藏不再添加；同日重复跑只更新 `trending-<date>.json` |
| star | 已 star 的仓库返回 204/304 视为成功，不重复计数 |
| 加 unread | 写入前比对 List 索引；已在 unread 则跳过 mutation |
| 写 summary | 文件存在且 `mode` 与本次一致 → 默认跳过（`-Force` 覆盖） |
| 渲染 | 同名文件已存在则加时间后缀，不覆盖历史 |
| 发布 | `git diff --cached --quiet` 为真 → 跳过 commit，仍按成功处理 |
| 迁移 | `read` 已含该条时只做替换（结果相同）；`moved` 状态不再重复处理 |
| 回滚 | 按快照重放，重复执行结果一致 |

### 9.2 崩溃恢复矩阵

| 崩溃发生在 | 磁盘状态 | 下次运行行为 |
|---|---|---|
| Search 请求中 | 无新 `trending-*.json` | 重新扫描；旧快照不被覆盖 |
| 写 `trending-*.json` 中途 | 临时文件残留 | 启动时清理 `*.tmp`；正式文件未变 |
| queue 写入中途 | `queue.json.tmp` 残留 | 原子替换：先写 tmp 再 `Move-Item -Force`；残留 tmp 直接删除 |
| 加 unread 中途 | 部分条目在 List、queue 已记 `inUnread=false` | 下次扫描重建 List 索引 → 已存在的补记 `inUnread=true`，不重复 mutation |
| LLM 调用中 | 该条 `summarizing` | 启动时把 `summarizing` 重置为 `pending`（`attempts+1`） |
| 写 summary 中途 | `.tmp` 残留 | 删除 tmp；该条按未完成处理 |
| 渲染中 | `reports/*.tmp` | 删除 tmp；重新渲染 |
| 发布中（已 commit 未 push） | 本地多一个 commit | 下次 `git fetch` 判断：本地 ahead 1 → 直接 push（提交信息已含 RunId） |
| 发布中（已 push 未迁移） | 条目 `done/published=false` | 下次运行补发布（无 diff 即成功）→ 再迁移 |
| 迁移中 | 部分 `moved`、部分 `done` | 只处理 `done && published=true`，天然续跑 |

### 9.3 `-Repair`（可选但建议实现）

```
-Repair            # 按顺序做：重算 List 索引 → 补 star → 补发布 → 补迁移
-Repair -DryRun    # 只打印将要做的动作
-Rollback <RunId>  # 按快照恢复 unread/read
```

`-Repair` 不调用 LLM，不生成新页面；只修状态与远端一致性。

---

## 10. 安全与合规实现（`REQUIREMENTS.md` 第 11 节的落地）

### 10.1 密钥流

```
gh auth login ──▶ Windows 凭据管理器（gh 自己管）
                      │
                      │ gh auth token（stdout，内存）
                      ▼
              scan.ps1 / read.ps1 的 $env:GH_TOKEN（仅子进程生命周期）
                      │
                      └─▶ GitHub API Header

llm.json（明文，ACL 仅当前用户）──▶ llm.ps1 读取 ──▶ Authorization: Bearer …
```

- `gh.json.token` 只在**未登录 gh** 时使用；两者都有时 gh 优先。
- 任何脚本**不得**把 token 写入 `data/`、`reports/`、`docs/`、日志。
- 日志脱敏：写入前用正则替换 `(gh[pousr]_[A-Za-z0-9]{20,})`、`(sk-[A-Za-z0-9]{10,})`、`(?i)(token|api[_-]?key)\s*[:=]\s*\S+` → `***`。

### 10.2 文件权限（Windows）

```powershell
# 保存 llm.json 后
icacls llm.json /inheritance:r /grant:r "$env:USERNAME:(F)"
```

- 同样处理 `gh.json`、`data/service-token`；
- 失败（非 NTFS / 无权限）不阻断，但页面顶部显示警告「密钥文件权限未收紧」。

### 10.3 合规约束（对应 `REQUIREMENTS.md` 第 11 节）

| 约束 | 实现位置 |
|---|---|
| 单轮 star ≤25、每日 ≤100、间隔 ≥1s | `scan.ps1` + `config.star`；计数写 `data/state.json.starCounters` |
| 请求串行 + 退避 | `lib/http.ps1` 统一入口，禁止并发请求 |
| 不抓页面 | 无 HTML 解析代码；只调用 Search/REST/GraphQL/raw |
| 不绕限流 | 无代理、无 UA 伪造、无多 token 轮换 |
| 单账号 | 只读 gh 的 active account；无账号切换 API |

---

## 11. 性能与成本预算

### 11.1 请求量（一次完整流程）

| 阶段 | 请求数 | 备注 |
|---|---|---|
| 扫描：Search | 3 | 认证 30 次/分钟，占 10% |
| 扫描：List 索引 | 1–10 | List 数 × 每 List 页数；1000 条以内通常 ≤3 |
| 扫描：加 unread | 新增条数（≤约 75） | 每条 1 次 mutation |
| 扫描：star | ≤25 | 每条 1 次 REST |
| 阅读：每条 | 4–8 | repo + readme + tree + 3–5 contents |
| 阅读：迁移 | 每条 1 次 mutation | — |
| 发布 | git 三步 | 不占 API 配额 |

`n=10` 时约：3 + (1–10) + ≤75 + 25 + 70 + 10 ≈ 190 次请求，远低于 REST 5000/小时与 GraphQL 5000 点/小时。

### 11.2 时间与费用

| 项 | 估计 |
|---|---|
| 扫描 | 20–60 秒（大多数时间在逐条 mutation 与 star 的 1s 间隔） |
| 单条阅读（deep） | 抓取 2–5 秒 + LLM 30–90 秒 |
| `n=10` 总计 | 15–25 分钟（串行；可后续加并行，本期不做） |
| 单条 token | 输入 ~15k–20k，输出 ~1.5k |
| 费用 | 按模型单价 × (输入×0.8 + 输出×0.2) 估算；`read.ps1` 启动时打印「预计输入字符数」 |

> 串行是刻意的：并发会显著提高触发二级限流的概率（`REQUIREMENTS.md` 第 11 节）。

---

## 12. 测试与验收映射

### 12.1 离线测试（`scripts/self-test.ps1`，不联网）

| 用例 | 断言 |
|---|---|
| 去重 | 三周期含同仓库 → 入队 1 条、`scannedFrom` 3 项 |
| 过滤 | 构造 unread/read/denylist 数据 → 各跳过原因计数正确且总数守恒 |
| 排序 | 新条目 seq 递增，已有条目 seq 不变 |
| 转义 | 注入样例 → 输出不含 `<script`、`onerror=`，只含 `<br>` |
| 模板 | 缺 `qa` 字段 → 渲染失败并给出明确错误（不产出半成品） |
| 索引 | 连续两轮 → 两条记录、日期倒序 |
| 队列状态机 | `summarizing` 残留 → 启动时重置为 `pending` |

### 12.2 验收标准映射

| 需求 | 验证方式 |
|---|---|
| AC-1 首次接入 | 真实账号：创建两个 List，新条目进 unread |
| AC-2 幂等 | 同日连跑两次扫描，比较 queue 与 List 数量 |
| AC-3 覆盖度 | 对比日志：`scanned = added + 各跳过` |
| AC-4 输入校验 | 页面输入 0/abc/21；`run-joy.bat 21` |
| AC-5 阅读顺序 | 打印选择清单与 queue 前 n 条比对 |
| AC-6 总结质量 | 抽 3 条人工核对 refs 与 sources |
| AC-7 页面安全 | 断网打开 + 注入样例 + 打印/移动端 |
| AC-8 状态迁移 | 统计 unread/read 数量差；`-NoPublish` 对照 |
| AC-9 发布 | Pages 地址 + `git show --stat` 只含 `docs/*.html` |
| AC-10 故障恢复 | 断网/中断/429 模拟，重跑不重复计费 |
| AC-11 控制台 | 双击、扫描、2 秒内刷新、关窗释放端口 |
| AC-12 账号与密钥 | 真实设备码登录 → 退出；掩码检查 |
| AC-13 报告结构 | 卡片首段为单段话；`qa` 3–6 组 |
| AC-14 合规 | 检查 star 上限计数与请求间隔日志 |

---

## 13. 风险与待实测项

| # | 风险 | 影响 | 现状 | 缓解 / 验证计划 |
|---|---|---|---|---|
| R1 | `gh auth login --web` 在无 TTY 的子进程中可能改变输出或等待 stdin | 点「登录」后卡住 | ✅ **已实测（2026-11-19，gh 2.103.3）**：非 TTY 下直接输出 `! One-time code (XXXX-XXXX) copied to clipboard` 与 device URL，不等待回车，代码可稳定解析；`taskkill /T` 取消有效 | 保留 stdin 换行兜底与 5 分钟超时；授权完成后的 scope 行为仍待 R2 |
| R2 | Lists 写入需要 `user` scope，`--scopes "user"` 为追加语义 | 登录成功但写入失败 | ✅ **读取与写入均已实测（2026-11-19）**：scope 为 `gist, read:org, repo, user`；13 个 List 可读；成功创建 `read` 并把 5 个条目加入 `unread`，失败 0 | 多 List 合并（R3）仍需一条「已属其它 List」的真实样本验证 |
| R3 | `updateUserListsForItem` 是**整体替换** | 可能清掉用户手工归类 | **已从 schema 确认** | 写入前合并 `otherListIds`；`self-test.ps1` 覆盖「条目已在其它 List」用例 |
| R4 | List 索引随使用增长（数百到上千条） | 扫描变慢、GraphQL 点数上升 | 未知 | 索引缓存到 `data/list-index.json`（TTL 10 分钟）；超过 2000 条时提示 |
| R5 | Search 口径不含「老仓库突然爆火」 | 漏项目 | 已知（Q3 取舍） | 页面与日志标注 `source=search`；后续可选增加 Trending 页兜底（需改需求） |
| R6 | PowerShell 5.1 编码问题 | 中文乱码、JSON 解析失败 | 已知坑 | `.ps1` 纯 ASCII；JSON UTF-8 无 BOM；`Invoke-RestMethod` 结果按字节还原 |
| R7 | 端口 8787–8790 全被占用 | 起不来 | 低概率 | 明确报错 + 提示 `-Port` |
| R8 | Node 版本过低（<18） | 语法/API 不支持 | 本机 24 可用 | 启动检查 `process.versions.node` 主版本，失败退出码 4 |
| R9 | git 未配身份 / 分支保护 / 远端分叉 | 发布失败 | 常见 | 预检 + 可执行建议；绝不 force push |
| R10 | Pages 构建延迟或缓存 | 「已推送」但页面未更新 | 低 | 文案用「已推送」；不轮询 Pages 状态 |
| R11 | `icacls` 在非 NTFS 或受限账户失败 | 密钥权限未收紧 | 低 | 只警告，不阻断 |
| R12 | 回滚只覆盖清单，不恢复「条目在其它 List 的成员关系」 | 回滚不完整 | 中 | 快照记录 `listIds`（不只 unread/read），回滚按快照重放 |

---

## 14. 实施顺序（每步先干跑）

| 里程碑 | 交付 | 完成判据 |
|---|---|---|
| M0 骨架 | `joy.bat`、`service/server.js`、静态页、`/api/status`（假数据） | 双击 10 秒内出页面；令牌/ Host 校验生效；关窗释放端口 |
| M1 认证 | `gh` 状态/登录/退出、Lists 只读探针 | 设备码登录/退出走通；R1 通过；R2 读取通过 |
| M3a 模型配置 | `/api/llm`（读写 + 测试）、页面「模型」区 | 保存后只显示掩码；测试连接返回状态与延迟 |
| M2 扫描 | `scan.ps1`（search → 去重 → queue → Lists → star），先 `-DryRun` | 干跑输出统计且不写远端；再真实写入，AC-1/2/3/14 通过 |
| M3 阅读 | `read.ps1` + prompts + `llm.ps1` 校验 | `-NoPublish` 跑 `n=3`，产出 3 份 summary；AC-6/13 通过 |
| M4 渲染发布 | `render.ps1`、`publish.ps1`、`migrate.ps1` | `-NoPublish` 本地页面正确；真实发布后 Pages 可访问；AC-7/8/9 通过 |
| M5 加固 | `self-test.ps1`、`-Repair`、`-Rollback`、README/RUNBOOK | 离线测试全绿；断网/中断演练可续跑；AC-4/5/10/11/12 通过 |

**M0–M4 的每个脚本都必须先支持 `-DryRun` 或 `-NoPublish`**，干跑输出「将要做的事」再真实执行。

---

## 15. 与需求的偏差（设计侧新增或细化）

| # | 设计做法 | 需求原文 | 理由 |
|---|---|---|---|
| D1 | 迁移用**单次** `updateUserListsForItem`（替换 `listIds`） | FR-7 写「从 unread 移除 → 加入 read」 | schema 语义为整体替换，一次调用等效，少一个失败窗口；需合并其它 List 防误删 |
| D2 | 发布「无 diff」视为成功 | FR-8「push 成功」 | 重跑不应因无可提交内容而失败 |
| D3 | unread 总数缓存 30 秒 | FR-13 要求展示，未定刷新频率 | 避免 3 秒轮询打爆 GraphQL |
| D4 | 索引数据源为 `data/reports-index.json` | FR-6 只要求索引页 | 不反向解析 HTML，生成更稳 |
| D5 | Node 不直接调 GitHub API | 需求未规定分层 | 认证与重试集中在一处，避免两套实现漂移 |
| D6 | 新增退出码 4（服务启动失败）、5（部分成功） | FR-11 未定义退出码 | 页面与 bat 需要区分「起不来」与「部分失败」 |
| D7 | 新增 `-Repair` / `-RepairStar` | 需求未列 | 崩溃恢复与 star 补做，均为幂等只读/补写操作 |
| D8 | `config.json` 入库（非密钥） | FR-10 表格 | 便于复现与 review；密钥仍在 `gh.json` / `llm.json` |
| D9 | 脚本向 stdout 输出单行 JSON 进度事件 | 需求未规定 | 服务需要展示阶段与进度 |
| D10 | M1 阶段的 gh 状态由 Node 直接调用 `gh auth status --json` 提供；`status.ps1` 顺延到 M2（需要 unread 总数时） | DESIGN 2 目录树 | 少一层进程转发；GitHub API 仍未进入 Node，认证逻辑依旧只在 gh / PowerShell 侧 |

---

## 附录 A：`config.sample.json`

```json
{
  "version": 1,
  "network": { "proxy": "", "autoDetect": true, "noProxy": "localhost,127.0.0.1" },
  "search": {
    "periods": ["today", "week", "month"],
    "perPage": 100,
    "minStars": { "today": 100, "week": 2000, "month": 5000 },
    "strict": true,
    "maxPerScan": 25,
    "starFilter": true,
    "quota": { "today": 5, "week": 8, "month": 12 },
    "fillRemaining": true,
    "intervalMs": 300
  },
  "queue": { "maxAttempts": 3, "denylist": { "owners": [], "repos": [], "languages": [], "keywords": [] } },
  "star": { "enabled": true, "maxPerScan": 25, "maxPerDay": 100, "intervalMs": 1000 },
  "read": {
    "maxN": 20,
    "defaultN": 5,
    "deepMode": true,
    "readmeMaxChars": 20000,
    "treeMaxEntries": 200,
    "keyFilesMin": 3,
    "keyFilesMax": 5,
    "keyFileMaxChars": 8000
  },
  "llm": { "maxInputChars": 70000, "temperature": 0.2, "maxRetries": 3 },
  "publish": { "noJekyll": true, "commitPrefix": "joy:" },
  "retention": { "workDays": 90, "reportsDays": 0 },
  "service": { "host": "127.0.0.1", "port": 8787, "portFallbacks": [8788, 8789, 8790] }
}
```

> `reportsDays: 0` 表示永久保留（Q6 已确认）。