# GitHub Joy · 操作手册（RUNBOOK）

| 项目 | 内容 |
|---|---|
| 文档版本 | 1.3（对应 REQUIREMENTS v1.3 / DESIGN v1.3） |
| 更新日期 | 2026-11-20 |
| 状态 | M1–M4c 已实现并上线（`https://gingkorich.github.io/GithubJoy/`）；本文命令均已实测（个别 ⏳ 为历史标注，可忽略）；M5 的 self-test / `-Repair` 未实现（一致性修复见 7.3） |
| 读者 | 使用者本人、维护者、接手的 AI 代理 |

> 本手册只讲「怎么做、怎么查、怎么退」。设计原因看 `DESIGN.md`，需求边界看 `REQUIREMENTS.md`。
> 三件事先记住：**只绑 127.0.0.1**、**发布只提交 `reports/` 下生成的页面（根 `.nojekyll`）**、**任何 token 都不进仓库**。

---

## 0. 三条使用路径

| 你现在要做什么 | 看哪一节 |
|---|---|
| 第一次装、第一次跑 | 第 1、2 节（约 15 分钟） |
| 每天扫描 / 阅读 | 第 3 节（两次双击） |
| 出错了 | 第 6 节（按现象查表） |
| 误删了收藏夹 / 想撤销 | 第 7.4、8 节 |

---

## 1. 前置条件

### 1.1 环境清单

| 项 | 要求 | 本机现状 | 验证命令 |
|---|---|---|---|
| 系统 | Windows 10/11 | Windows 11 | `winver` |
| PowerShell | 5.1（脚本按 ASCII 编写） | 5.1 | `$PSVersionTable.PSVersion` |
| Node | ≥ 18，仅用标准库 | v24.20.0（`D:\SoftWare\nodejs`） | `node -v` |
| GitHub CLI | ≥ 2.40（登录/退出用） | 2.103.3（`C:\Program Files\GitHub CLI\gh.exe`） | `gh --version` |
| git | 任意近期版本，已配置身份 | 已装 | `git --version`、`git config --global user.name` |
| 网络 | 能访问 github.com 与模型 API；直连被阻断时需可用代理 | 系统代理 `127.0.0.1:10808` | `curl.exe --proxy http://127.0.0.1:10808 -sS -o NUL -w "%{http_code}" https://github.com` |
| 磁盘 | ≥ 2 GB 空闲（`.work` 与缓存） | — | `Get-PSDrive D` |

### 1.2 目录要求

- 项目放在**本地磁盘**，不要放 OneDrive / 坚果云等同步目录（同步会锁文件、改时间戳，`git` 与文件锁都会出错）；
- 路径避免中文与空格（本机 `D:\AIproject\GithubJoy` 符合）；
- 目录需要当前用户可读写（发布要写 `reports/` 与根 `.nojekyll`、`git` 要写 `.git/`）。

### 1.3 一次性检查

```powershell
cd D:\AIproject\GithubJoy
node -v                      # >= v18
gh --version                 # >= 2.40
git --version
Test-Path .\docs             # 发布目录是否存在
```

已实现并上线（2026-11-19）：`joy.bat` 启动即完成检查，结果写入页面与 `logs/`。

---

## 2. 首次部署（一次性）

### 2.1 仓库与 Pages

1. 仓库必须 **public**（免费账号的 Pages 前提）；私有仓库需付费方案。
2. Settings → Pages → Source 选 **Deploy from a branch** → Branch 选你的分支（本项目为 **master**）/ Folder **/(root)** → Save。
3. 确认仓库根有 `reports/` 与根 `.nojekyll`（首次发布时脚本会创建）；`docs/` 只放 `.md`，不放 HTML。
4. 记下 Pages 地址：`https://<你的登录名>.github.io/GithubJoy/`，填进 `gh.json.publish.baseUrl`；具体报告地址是 `.../reports/<文件>.html`。

> 仓库公开 = `MEMORY.md`、`AGENTS.md`、`docs/*.md` 与历史提交全部公开。发布前确认没有个人信息与密钥（见第 11 节清单）。

### 2.2 首次启动控制台

```powershell
cd D:\AIproject\GithubJoy
.\joy.bat
```

预期：控制台窗口出现访问地址 → 浏览器自动打开 `http://127.0.0.1:8787/` → 页面显示「未连接」与上次扫描为空。

- 端口被占用时会依次尝试 8788–8790，并在窗口打印实际端口；
- 不打开浏览器：`.\joy.bat -NoOpen`；指定端口：`.\joy.bat -Port 9000`。

### 2.3 登录 GitHub（gh 设备码）

页面「账号区」→ **使用 GitHub 登录**：

1. 页面显示一次性代码（形如 `AB12-CD34`）与 `https://github.com/login/device`；
2. 打开该地址，粘贴代码，授权；
3. 页面 5 秒内显示用户名，顶部出现主页链接。

若卡住不进下一步：见 6.3（R1 已实测，通常 2 秒内出码）。

登录完成后核对 scope（页面会显示）：

```
repo, read:org, gist, user
```

- `user` 供 Lists 读写，`repo` 供发布，缺一不可（R2）。

### 2.4 配置模型

页面「模型」区填 `接口`（如 `https://api.deepseek.com/v1`）、`模型`（如 `deepseek-chat`）、`API Key`、`超时` → **测试连接** → **保存**。

- 保存写入 `llm.json`，并立即 `icacls` 收紧为仅当前用户完全控制；
- 页面只回显掩码（`sk-****abcd`），**不会**再显示明文；Key 输入框留空表示保留原值；
- 测试连接只发一次 `max_tokens=1` 的请求：**先直连，连不通（网络层失败）时自动改走系统代理**，成功提示会标注「直连 / 经代理」；失败会显示 HTTP 状态与模型返回的错误；
- 也可以手工创建 `llm.json`（字段见 `DESIGN.md` 附录 A 与 FR-10），然后执行：

```powershell
icacls .\llm.json /inheritance:r /grant:r "$env:USERNAME:(F)"
```

### 2.5 确认业务配置

`config.json`（唯一业务配置，直接编辑即可；`config.sample.json` 已删除）：

| 字段 | 默认 | 说明 |
|---|---|---|
| `search.minStars` | 100 / 2000 / 5000 | today / week / month 的 star 阈值（严格大于） |
| `search.quota` | 5 / 8 / 12 | 周期配额，合计 25；不足按 star 降序补齐 |
| `search.starFilter` | true | 排除已 star 的项目（批量 `viewerHasStarred`） |
| `star.maxPerScan` | 25 | 单轮最多 star 数（合规上限，别调大） |
| `star.maxPerDay` | 100 | 每日上限 |
| `read.maxN` / `defaultN` | 20 / 5 | 页面与 bat 的 n 上限/默认值 |
| `read.deepMode` | true | 默认读源码；`-Lite` 可临时降级 |

### 2.6 首次扫描（先干跑）

```powershell
.\scan.bat -DryRun
```

预期：打印三个周期各自的 query、`totalCount`、候选数、将要入队的清单，**不写远端**。

确认无误后，在页面点「立即扫描」或：

```powershell
.\scan.bat
```

预期统计满足：

```
scanned = added + already_unread + already_read + already_done + denied
```

### 2.7 首次阅读（先不发布）

```powershell
.\run-joy.bat 1 -DryRun     # 先干跑：只打印将阅读的条目
.\run-joy.bat 1 -NoWrite    # 再实跑一次：抓材料 + 调模型，但不落盘 summary
.\run-joy.bat 1             # 确认质量后真实阅读：生成 summary（仍不发布）
```

预期：抓 1 个项目的 README/目录树/关键文件 → 生成 summary；收藏夹**不变**（`run-joy.bat` 只做阅读，渲染/发布/迁移由页面「阅读」按钮或手动脚本完成）。

需要本地看页面效果时手动渲染：`powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\render.ps1 -N 1`，产物在 `reports\`。

确认质量后再走完整链路（页面点「阅读」或分步跑 render/publish/migrate）：发布成功后条目才会从 `unread` 移到 `read`。

---

## 3. 日常操作

### 3.1 早上：扫描

1. 双击 `joy.bat`（窗口不要关，它就是服务本身）；
2. 页面点 **立即扫描**；
3. 约 20–60 秒后，概览卡片更新：上次扫描时间、本次新增 unread、累计 unread；
4. 看「报告列表」或直接关窗口（关窗=停服务，不影响已完成的扫描）。

### 3.2 晚上：阅读

在页面输入 `5` → **阅读 5 个**。注意：完整流水线（阅读→渲染→发布→迁移）只有页面按钮会自动串完；`run-joy.bat 5` 等价于其中的「阅读」一步。

- 阅读源是 **GitHub `unread` List**（按 List 顺序），选中后写入本地临时队列；**阅读结束（成功或失败）队列清空**；
- 点一次「阅读」后自动完成「渲染 → 发布 → 迁移」，不需要再点其他按钮；任一阶段失败会停在当前阶段并显示原因；
- 扫描不写本地队列；页面「待读」显示 unread List 总数；
- 已有 summary 的条目会自动跳过（`-Force` 重做）。

进度会显示：阶段 → 已处理条数 → 日志尾部。中途可关闭页面（服务仍在跑）；重开页面会自动接上进度。

### 3.3 无界面方式

```powershell
.\scan.bat                      # 扫描（与控制台互斥，同一时间只能一个）
.\run-joy.bat 5                 # 读 5 个并生成 summary（发布/迁移另见下两行）
.\run-joy.bat 3 -DryRun         # 干跑：只打印将阅读的条目
.\run-joy.bat -OnlyId owner/name          # 单条重试
.\run-joy.bat -IdsFile ids.txt           # 批量补读
.\run-joy.bat 2 -Lite           # 只读 README + 目录树（省钱）
.\run-joy.bat -OnlyId owner/name -Lite -NoLlm -NoWrite   # 只抓材料：不调模型、不写盘

# 需要无界面地走完发布与迁移（等价于页面「阅读」的后三步）：
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\render.ps1 -N 3
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\publish.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\migrate.ps1
```

### 3.4 停止与状态

```powershell
.\joy.bat --stop        # 结束服务（按 data\service.json 的 PID）
```

- 直接关控制台窗口也可以停服务；
- 服务未运行时，页面打不开是正常现象，先双击 `joy.bat`。

---

## 4. 怎么判断「这一轮是正常的」

| 检查点 | 正常表现 | 异常去哪看 |
|---|---|---|
| 扫描统计 | `scanned` = 各分项之和；新增数合理（个位数到几十） | 6.4 |
| 上次扫描时间 | 就是刚才 | 6.1 / 6.2 |
| 累计 unread | 与 github.com 上 unread 列表数量一致 | 7.3 |
| star 数 | 本轮新增 ≤25，日志有 `starSkipped` 记录 | 6.6 |
| 报告卡片 | 第一段一段话 + 3–6 组问答 | 6.7 |
| 发布 | 页面显示「已推送」，`git show --stat` 只有 `reports/*.html` 与根 `.nojekyll` | 6.8 |
| 迁移 | unread 减少数 = read 增加数 = 本次成功数 | 6.5 / 7.4 |

---

## 5. 账号与凭据管理

### 5.1 查看当前登录

```powershell
gh auth status --hostname github.com
```

页面「账号区」显示的就是同一条信息（`/api/gh/status`）。注意：**未登录时该命令退出码为 1**，这是正常状态，不是故障。

### 5.2 退出 / 换账号

```powershell
gh auth logout --hostname github.com
```

- 退出后服务会在 3 秒内把页面切回「未连接」；
- 换账号：先退出，再在页面点「使用 GitHub 登录」；
- 本期只支持单账号，不要用 `gh auth switch` 在多账号间来回切（列表与队列会串）。

### 5.3 改用 PAT（不装 gh 或 gh 出问题时）

1. GitHub → Settings → Developer settings → Tokens (classic) → Generate new token；
2. 勾选 **`user`** 与 **`repo`**（Lists 要 `user`，发布要 `repo`）；有效期建议 90 天；
3. 写入 `gh.json`（**不要**写进 `config.json`、不要提交）：

```json
{
  "token": "ghp_xxx",
  "login": "your-login",
  "unread_list": "unread",
  "read_list": "read",
  "publish": {
    "repo": "your-login/GithubJoy",
    "branch": "main",
    "dir": "docs",
    "baseUrl": "https://your-login.github.io/GithubJoy/"
  }
}
```

4. 收紧权限：

```powershell
icacls .\gh.json /inheritance:r /grant:r "$env:USERNAME:(F)"
```

5. 重启服务，页面应显示用户名。

### 5.4 撤销凭据（怀疑泄露时）

| 凭据 | 撤销位置 |
|---|---|
| gh 的 OAuth 授权 | GitHub → Settings → Applications → **GitHub CLI** → Revoke |
| PAT | GitHub → Settings → Developer settings → Tokens → Delete |
| 模型 Key | 模型服务商后台 → 删除/禁用该 Key |
| 本机文件 | 删除 `gh.json` / `llm.json`，重新登录与填写 |

撤销后本机旧令牌立即失效；扫描会返回 401，按 6.4 处理。

### 5.5 轮换模型 Key

页面「模型区」直接填新 Key → 测试连接 → 保存。旧 Key 到服务商后台禁用。保存会重写 `llm.json` 并重新收紧 ACL。

### 5.6 三条硬规则

1. 不把 `gh.json` / `llm.json` 提交到仓库（`.gitignore` 已覆盖，仍需提交前确认）；
2. 不在截图、日志、Issue 里贴 token；
3. 不把仓库改成 public 之后才检查历史提交——先查再公开。

---

## 6. 故障排查

> 先看**页面**：所有任务失败都会在页面对应区域显示原因；日志只作为补充。
> 日志位置：`logs\scan-<日期>.log`、`logs\read-<时间戳>.log`；任务详情在 `data\jobs\<id>.json`。

### 6.0 快速对照表

| 现象 | 最可能原因 | 先去 |
|---|---|---|
| 双击 joy.bat 后窗口一闪而过 | Node 未安装 / 版本过低 / 端口全占用 | 6.1 |
| 页面打不开、连接被拒绝 | 服务已停 / 端口变了 | 6.1 |
| 页面空白、所有按钮 403 | 直接双击了 html 文件，没走服务；或令牌不匹配 | 6.2 |
| 点登录没反应 / 一直转圈 | R1：gh 在无 TTY 下等待输入 | 6.3 |
| 登录报 `wsarecv` / `connection attempt failed` | GitHub 直连被阻断，gh 未走代理 | 6.11 |
| 扫描成功但 0 条新增 | 阈值过高 / 三周期都是老项目 | 6.4 |
| 扫描直接失败，日志有 403 | token 失效或 Search 限额 | 6.4 |
| 收藏夹没变化 | 发布失败（不改收藏夹）/ scope 不足 | 6.5 / 6.8 |
| star 数对不上 | 触达单轮/单日上限 | 6.6 |
| 阅读卡住或某条失败 | 模型超时 / 限流 / 内容审核 | 6.7 |
| 推送失败 | 分叉 / 无权限 / 分支保护 | 6.8 |
| Pages 打开 404 或旧内容 | Pages 未开启 / 缓存 / 缺 `.nojekyll` | 6.9 |
| 中文变问号 | 脚本或 JSON 编码 | 6.10 |

### 6.1 服务起不来

```powershell
node -v                                  # 必须 >= v18
Get-NetTCPConnection -LocalPort 8787 -ErrorAction SilentlyContinue |
  Select-Object LocalAddress,LocalPort,OwningProcess
```

- 端口被占：关掉占用进程，或 `.\joy.bat -Port 9000`；
- Node 版本低：升级 Node（只要求标准库，无需 npm）；
- 窗口闪退：在 PowerShell 里执行 `.\joy.bat` 看完整报错（双击看不到栈）；
- `data\service.json` 残留导致 `--stop` 失败：确认进程不存在后删除该文件。

### 6.2 页面 403 / 空白

- **不要**直接双击 `service\public\index.html`——页面里的请求没有 `X-Joy-Token`，也不满足 `Host` 校验；
- 只从 `http://127.0.0.1:<port>/` 打开；
- 换了端口后旧标签页会 403：关掉旧标签，用窗口里打印的新地址；
- 浏览器插件（广告拦截/隐私）可能拦 `127.0.0.1`：换无痕窗口试一次。

### 6.3 gh 登录（R1 已实测）

2026-11-19 实测（gh 2.103.3，服务内无 TTY 子进程）：点「使用 GitHub 登录」后 2 秒内出现两行：

```
! One-time code (XXXX-XXXX) copied to clipboard
Open this URL to continue in your web browser: https://github.com/login/device
```

- 代码会同时复制到剪贴板，页面也会显示同一个代码；
- gh **不会**等待回车，不需要手动按键；
- 授权完成后页面 3 秒内变为已登录；点「取消」只终止登录进程，不会产生授权。

仍然卡住时：

1. 看 `data\jobs\login-*.json` 的 `code` 与 `lines`；
2. 手动到终端执行（一定能成）：

```powershell
gh auth login --hostname github.com --git-protocol https --web --scopes "user"
```

3. 完成后回页面等 3 秒（或刷新）；
4. 若报 scope 相关错误，看 6.5；若日志含 `wsarecv` / `connection attempt failed`，看 6.11。

### 6.4 扫描失败 / 0 条新增

| 日志关键字 | 含义 | 处理 |
|---|---|---|
| `totalCount=0` / `items=0` | 该周期查询无结果 | 单周期为空只告警；三个周期都空才失败。检查 `config.search.minStars` 是否过大 |
| `401` | token 失效 | 重新登录（5.2）或换 PAT（5.3） |
| `403 secondary rate limit` | 二级限流 | 等 1–5 分钟再跑；不要连点「立即扫描」 |
| `403 rate limit exceeded` | 配额用尽 | 看响应里的 `X-RateLimit-Reset`，等到点再跑 |
| `422` | 查询串非法 | 说明代码/配置有 bug，保留日志与 query 反馈 |
| 网络超时 | 代理/VPN/DNS | 关代理或换网络；`Test-NetConnection api.github.com -Port 443` |

**0 条新增但扫描成功**：连续几天都 0，说明阈值太严格（today 默认 30 star 已经很低），可临时把 `minStars.today` 调到 10 验证，再改回。

### 6.5 收藏夹（Lists）没变化

先确认是不是「发布没成功」——按设计，**发布成功才迁移**（第 3 节、DESIGN 5.4）：

```powershell
git log --oneline -3          # 有没有 joy: 提交
git status --short            # reports/ 下是否有未提交页面
```

发布正常但仍无变化，再查：

| 检查 | 做法 |
|---|---|
| 登录是否有效 | 页面账号区 / `gh auth status` |
| scope 是否含 `user` | 页面显示的 scope；缺则重新登录（5.2） |
| List 名是否被改过 | 网页打开 Star Lists，确认仍叫 `unread` / `read`；改名后在 `gh.json` 里同步 |
| 是否重名 List | 设计取最早创建的那个；把多余的改名后重跑 |
| 单条失败原因 | `data\jobs\<id>.json` 的 `result.listAddFailed[]`，含 GraphQL `message` |

**手动补一条**（确认单个仓库该不该进 unread）：

```powershell
gh api graphql -f query='
  mutation {
    updateUserListsForItem(input: { itemId: "R_kgDOxxxx", listIds: ["L_kwDOyyyy"] }) {
      lists { name }
    }
  }'
```

> ⚠️ 两个 ID 都是 node ID：仓库 ID 来自 `/repos/{owner}/{repo}` 的 `node_id`，List ID 来自 `viewer.lists`。
> ⚠️ 这个 mutation 是**整体替换**。手工执行时 `listIds` 必须包含该条目原有的其它 List，否则会把它们从那些 List 里移除（设计 D1 / R3）。

### 6.6 star 没生效 / 数量对不上

> 重要：**Star List 只保留已 star 的仓库**。未 star 就加进 List，条目会在之后被 GitHub 清除（本机实测：5 个条目约 1 小时后从 unread 消失）。所以正常流程必须是「先 star、再写 List」；`-NoStar` 现在会跳过 List 写入并在日志里告警。

1. 看日志里的 `starSkipped`：
   - `cap_per_scan`：本轮已 star 25 个，剩余跳过（正常）；
   - `cap_per_day`：今天已到 100 个（正常）；
2. `403` / `429`：被限流，等几分钟；不要为了补齐而反复重跑；
3. 条目已在 unread 时不会再 star（幂等），要补：

```powershell
gh api -X PUT /user/starred/<owner>/<repo>
```

### 6.7 阅读失败（LLM 相关）

| 现象 | 原因 | 处理 |
|---|---|---|
| `401` / `invalid_api_key` | Key 错/过期 | 页面重填 Key → 测试连接 |
| `404` / `model not found` | `model` 名不对 | 对照服务商文档改 `model` |
| `400` 提示不支持 `temperature` | 部分模型（如路由模型 `auto`）不接受该参数 | 测试连接已不带该参数；`read.ps1` 会去掉后重试一次 |
| 400 `invalid_parameter_error`（其他） | 模型不支持某参数 | 看响应里的 `param`/`message`，按提示删对应字段 |
| 超时 | 输入过长 / 网络 | `-Lite` 降级重试该条；或调大 `timeout_sec` |
| `429` | 模型限流 | 等 1–2 分钟；用 `-OnlyId` 单条补 |
| `data_inspection_failed` | 内容审核 | 设计会缩短输入重试；仍失败则该条失败，换模型或跳过 |
| 反复「返回非 JSON」 | 模型能力不足 | 换支持 JSON 输出的模型；检查 `prompts/` 是否被改动 |

单条补跑：

```powershell
.\run-joy.bat -OnlyId owner/name
```

### 6.8 发布失败

```powershell
git status
git log --oneline origin/main..main     # 本地领先几个提交
git log --oneline main..origin/main     # 远端领先（需要先 pull）
```

| 现象 | 处理 |
|---|---|
| 提示「远端有更新/分叉」 | 手动 `git pull --rebase` 解决后重跑；脚本不会自动 rebase |
| `403` / `Permission denied` | token 缺 `repo` 或该仓库无写权限（5.3） |
| 分支保护 | 到 Settings → Branches 允许推送，或换分支 |
| 提示未配置身份 | `git config --local user.name "你的名字"`、`git config --local user.email "你的邮箱"` |
| 提交里混入别的文件 | **立即停**：`git reset --soft HEAD~1` 后按 6.8 末尾重新只 add 页面文件 |

**只提交页面文件的正确姿势**（脚本内部就是这样做的）：

```powershell
git add -- reports/2026-11-19-n5.html reports/latest.html reports/index.html .nojekyll
git status --short          # 确认只有 reports/ 下这些文件与根 .nojekyll
git commit -m "joy: 2026-11-19 n=5"
git push origin main
```

### 6.9 Pages 打开 404 / 还是旧内容

1. Settings → Pages 确认 Source = `master` / `/(root)`，且显示「Your site is live at …」；
2. 确认仓库是 public；
3. 确认根 `.nojekyll` 已提交：

```powershell
git ls-files .nojekyll
```

4. 构建有延迟（常见 10–60 秒），刷新时加 `?v=时间戳` 绕过缓存；
5. 仍 404：看 Actions 页是否有 `pages build and deployment` 失败。

### 6.10 中文乱码

- 现象：页面/JSON 里出现 `?`、`æ`、方块；
- 原因：PowerShell 5.1 默认编码与 UTF-8 不一致，或文件带了 BOM；
- 检查：

```powershell
$b = [IO.File]::ReadAllBytes('.\data\state.json')
"bom=$($b[0])-$($b[1])-$($b[2])"      # 期望 123-34-...（'{' 开头），不是 239-187-191
```

- 处理：删除 BOM 后重跑该步骤；`.ps1` 里必须显式 `-Encoding UTF8` 读写文本，且脚本本身保持纯 ASCII（中文只出现在 `.md` / `.json` / 模板里）。
- 读 JSON 时用 `Get-Content -Raw -Encoding UTF8` 或 `[IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)`；直接 `Get-Content -Raw` 会按 ANSI 解码，中文变乱码、`ConvertFrom-Json` 可能直接报错（本机已实测）。

### 6.11 GitHub 直连失败 / 代理（2026-11-19 实测）

**现象**：点「使用 GitHub 登录」后失败，日志含：

```
failed to authenticate via web browser: Post "https://github.com/login/device/code":
... wsarecv: A connection attempt failed because the connected party did not properly
respond after a period of time ...
```

**原因**：`gh` 是 Go 程序，只读 `HTTPS_PROXY` / `HTTP_PROXY` / `ALL_PROXY`，**不读 Windows 系统代理**（`Internet Settings`）。本机 `github.com:443` 直连会被阻断，而 `api.github.com` 可能正常，所以扫描类请求看似没事、只有登录挂。

**先判断是哪一种**：

```powershell
curl.exe -sS -o NUL -w "%{http_code}`n" --max-time 10 https://github.com
curl.exe -sS -o NUL -w "%{http_code}`n" --max-time 10 --proxy http://127.0.0.1:10808 https://github.com
```

- 第一条超时/`000`，第二条 `200` → 直连不通、代理可用（本机就是这种情况）；
- 两条都 `000` → 代理没开或端口不对，先修代理。

查看系统代理：

```powershell
netsh winhttp show proxy
reg query "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyEnable
reg query "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyServer
```

**修复（二选一，改完重启 `joy.bat`）**

1. 自动：系统代理已开启（本机 `127.0.0.1:10808`），保持 `config.json.network.autoDetect = true`；页面「网络代理」应显示 `http://127.0.0.1:10808（系统代理）`。
2. 手动：在 `config.json` 写死（优先于系统代理）：

```json
"network": {
  "proxy": "http://127.0.0.1:10808",
  "autoDetect": true,
  "noProxy": "localhost,127.0.0.1"
}
```

支持 `http://` 与 `socks5://`（例如 `socks5://127.0.0.1:10808`）。

**注意**

- 代理会注入 `gh` 与 Lists 探针；`git push` **不读**这套配置，需要时单独设置：`git config --local http.proxy http://127.0.0.1:10808`（撤销用 `--unset`）。
- `NO_PROXY` 必须包含 `localhost,127.0.0.1`，否则本地服务/探针会被绕进代理。
- 若代理需要账号密码，不要把带凭据的 URL 提交到仓库。

---

## 7. 数据维护与修复

### 7.1 备份什么

| 内容 | 说明 | 是否含密钥 |
|---|---|---|
| `config.json` | 业务参数 | 否 |
| `gh.json` / `llm.json` | 凭据与发布配置 | **是** |
| `data\` | 队列、状态、summary、job、List 快照 | 否 |
| `reports\` | 历史页面 | 否 |
| 仓库本身 | 代码与 `reports/*.html` | 否 |

```powershell
$stamp = Get-Date -Format 'yyyyMMdd-HHmm'
$dest  = "D:\Backup\githubjoy-$stamp.zip"
New-Item -ItemType Directory -Force -Path (Split-Path $dest) | Out-Null
Compress-Archive -Path .\config.json,.\gh.json,.\llm.json,.\data,.\reports -DestinationPath $dest
```

> zip 里含明文密钥。放本机加密盘或离线介质，**不要**放网盘/OneDrive/邮件。

### 7.2 恢复

```powershell
# 1) 先停服务
.\joy.bat --stop

# 2) 备份当前状态（以防恢复错版本）
Rename-Item .\data "data.before-restore-$(Get-Date -f yyyyMMdd-HHmm)"

# 3) 解压备份到项目根（覆盖同名文件）
Expand-Archive -LiteralPath 'D:\Backup\githubjoy-20261119-2100.zip' -DestinationPath . -Force

# 4) 收紧密钥权限
icacls .\gh.json  /inheritance:r /grant:r "$env:USERNAME:(F)"
icacls .\llm.json /inheritance:r /grant:r "$env:USERNAME:(F)"

# 5) 启动并核对
.\joy.bat
```

恢复后先跑 `.\\scan.bat -DryRun` 与页面概览核对「本地状态 vs 远端收藏夹」是否符合预期（注意：GitHub Lists 是唯一状态源，本地 data/ 丢失不影响收藏夹与已发布报告）。

### 7.3 一致性修复（推荐顺序）

```powershell
# 没有 -Repair 一键开关（未实现）；各环节幂等，按现象重跑对应脚本：
.\scan.bat                                   # List 漏写 / 漏 star：按 List 实时成员幂等补做
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\render.ps1 -N 5   # 漏渲染
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\publish.ps1        # 漏发布
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\migrate.ps1        # 漏迁移（只处理 published 且仍在 unread 的条目）
```

- **不调用模型**、不生成新页面、不删数据；
- 修完对照：unread / read 数（页面概览或 GitHub 网页）与 `data\reports-index.json` 的 published 数。

### 7.4 回滚收藏夹（迁移错了）

每次迁移前都有快照：

```powershell
Get-ChildItem .\data\state\lists-*.json | Sort-Object LastWriteTime -Descending |
  Select-Object -First 5 Name,LastWriteTime
```

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\migrate.ps1 -Rollback migrate-20261119-182132
```

- 只回滚该快照涉及的、且当前仍在 `read` List 的条目（按 `data\state\lists-<runId>.json`）；
- `published` 保持 true，不会把已发布的页面撤回；
- 回滚后条目回到 unread，可重新阅读或重新迁移。

### 7.5 queue.json 看起来坏了

> 2026-11-20 口径变更：`queue.json` 只是 read 运行期的**临时工作集**（运行结束清空、DryRun/NoWrite 不落盘），不承载任何持久状态。JSON 解析失败或内容异常时**直接删除即可**：

```powershell
Remove-Item .\data\queue.json
.\run-joy.bat 1 -DryRun     # 验证下一轮 read 能正常选中 unread 前若干条
```

- 不会丢待读顺序（在 unread List）、不会丢已读记录（在 read List 与 `data\summaries\`）、不会丢发布状态（在 `data\reports-index.json`）。

<details><summary>历史做法（队列持久化时代的旧流程，已废弃）</summary>

1. 从最近备份恢复 `data\queue.json`（7.2）；
2. 无备份：先复制一份 `queue.json.broken-<时间>` 留证，再检查是否只是 JSON 语法问题（缺逗号/截断）；
3. 实在无法解析：新建最小队列并从收藏夹补录——把 unread 里、`read` 里都没有的仓库按出现顺序人工写入：

```json
{ "version": 1, "updatedAt": "…", "seq": 1,
  "items": [ { "id": "owner/name", "fullName": "Owner/Name", "seq": 1,
               "status": "pending", "addedAt": "…", "scannedFrom": [],
               "repo": { "nodeId": "" }, "list": { "inUnread": true, "inRead": false, "otherListIds": [] },
               "starred": false, "attempts": 0, "lastError": null,
               "summaryPath": null, "published": false, "movedAt": null } ] }
```

4. 启动服务后跑一次扫描：`nodeId` 为空的条目会在下次读取时补全，已读条目因 `already_read` 不会被重复处理。

</details>

### 7.6 清理

运行产物清理已**自动化**（2026-11-20）：`scripts\cleanup.ps1` 在每次扫描成功与阅读流水线（迁移完成）后由服务自动触发；也可手动执行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\cleanup.ps1 -DryRun   # 先看会删什么
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\cleanup.ps1          # 真实清理
```

清理规则（`config.json` 的 `retention` 段可调）：

| 对象 | 规则 | 默认 |
|---|---|---|
| `data\jobs\*.json` / `ids-*.txt` | 超过最新 `keepJobs` 个或早于 `jobDays` 天 | 20 个 / 30 天 |
| `logs\*.log`（含 `.out`/`.err`） | 早于 `logDays` 天 | 90 天 |
| `data\trending-*.json` | 早于 `trendingDays` 天 | 90 天 |
| `.work\` 临时文件 | 早于 `jobDays` 天 | 30 天 |
| `data\dry*.json`、`scan-real*.json`、`queue.before-clear-*.json`、`last-llm-raw.txt` | 一次性调试产物，**总是删除** | — |

**永不删除**：`data\summaries\`、`reports-index.json`、`state.json`、`state\`（迁移快照）、`queue.json`、`service.json`、`service-token`、`reports\`。

- `reports\` 永久保留（Q6）；
- `docs\*.html` 属于仓库历史，**不要**为了「清理」删掉已发布的页面（会变成一次删除提交）。

---

## 8. 回滚与撤销

### 8.1 撤销一次发布

```powershell
git log --oneline -5                    # 找到 joy: 开头的提交
git revert <commit>                     # 生成一个反向提交
git push origin main
```

- 不要用 `git reset --hard` + force push（会改写公共历史）；
- 只回退某个页面：`git checkout <上一个提交> -- reports/2026-11-19-n5.html`，再单独提交。

### 8.2 撤销迁移

见 7.4。回滚只恢复收藏夹，不回滚「已读」这个事实——若你想让项目重新进入待读，回滚后把该条 `status` 改回 `pending` 或直接跑 `-OnlyId` 重读。

### 8.3 撤销 star

```powershell
# 单个
gh api -X DELETE /user/starred/<owner>/<repo>

# 按本轮扫描 job 的 result.starred[] 批量（先看清单再执行）
$job = Get-Content .\data\jobs\scan-20261119-080211.json -Raw -Encoding UTF8 | ConvertFrom-Json
$job.result.starred | ForEach-Object { gh api -X DELETE "/user/starred/$_" }
```

- 撤销 star 不违反任何规则，但也别用它做「批量清理」——按需即可；
- 撤销后本地 `starred` 字段需要 `-Repair` 同步。

### 8.4 紧急停用（怀疑账号异常或被滥用）

1. `.\joy.bat --stop`（停服务）；
2. GitHub → Settings → Applications → GitHub CLI → Revoke；PAT 直接删除；
3. 模型服务商后台禁用 Key；
4. 检查最近 24 小时 `logs\` 与本轮 star 清单，确认没有异常批量操作；
5. 观察 1–2 天后再重新登录；期间可在网页手工收藏，不影响已有数据。

---

## 9. 迁移到新机器

1. **备份 + 复制**（7.1）：仓库目录、`config.json`、`gh.json`、`llm.json`、`data\`、`reports\`；
2. 新机器安装 Node ≥18、GitHub CLI、git（版本要求见 1.1）；
3. 解压到本地磁盘（不要同步盘），路径尽量保持一致（`D:\AIproject\GithubJoy`）；
4. 收紧两个密钥文件权限（7.2 第 4 步）；
5. 验证环境：

```powershell
node -v; gh --version; git --version
gh auth status --hostname github.com     # 新机器通常需要重新登录
```

6. 重新登录（页面或 `gh auth login …`），或把 `gh.json` 里的 PAT 留着兜底；
7. 模型 Key 若换了服务商，页面重填并测试连接；
8. `.\scan.bat -DryRun` → 正常则 `.\scan.bat`；
9. `.\run-joy.bat 1 -DryRun` → `.\run-joy.bat 1` 验证阅读链路（只写本地 summary、不动收藏夹）。

> Pages 配置跟着仓库走，不需要在新机器重设；但本机 `git` 身份要重新配置（否则提交失败，见 6.8）。

---

## 10. 变更与升级

### 10.1 换模型 / 换服务商

页面改 `base_url` + `model` + 新 Key → 测试连接 → 保存。先用 `-OnlyId` 单条试，确认 JSON 结构与中文质量后再批量。

### 10.2 换发布仓库 / 换 Pages 地址

1. 改 `gh.json.publish`（repo / branch / dir / baseUrl）；
2. 新仓库设 public，Pages 指向同分支与 `/docs`；
3. 跑一次发布，确认根 `.nojekyll` 与 `reports/` 页面都在；
4. `data/reports-index.json` 里旧 `url` 会指向旧域名：可手工批量替换，或忽略（只影响索引页的历史链接）。

### 10.3 升级本项目代码

```powershell
.\joy.bat --stop
git pull --ff-only
# 若 data/*.json 的 version 有变化，按发布说明执行迁移脚本（届时提供）
.\joy.bat
```

升级前先备份（7.1）；升级后跑一次 `.\scan.bat -DryRun` 并核对页面概览与收藏夹是否一致。

### 10.4 换 GitHub 账号

**不建议**在同一套数据上换账号（List ID、队列、历史 summary 都会对不上）。正确做法：

1. 备份并另存 `D:\Backup\githubjoy-<账号>-<日期>.zip`；
2. 退出旧账号（5.2），登录新账号；
3. 新建/清空 `data\` 与 `reports\`，按首次部署的第 2.3、2.6 步重新初始化；
4. 旧账号的 Lists 与 star 不会自动迁移，需手工整理。

---

## 11. 检查清单

### 每次发布前

- [ ] `git status --short` 里没有与本轮无关的改动
- [ ] 页面只有 `overview + Q&A` 的卡片，没有空话
- [ ] 本轮 star 数 ≤25（看页面/日志）

### 每日

- [ ] 扫描成功、`scanned` 各项之和自洽
- [ ] 有新增时 unread 数量与网页一致
- [ ] 报告列表出现当天页面（若当天有阅读）

### 每周

- [ ] Pages 地址能打开最新页面
- [ ] `logs\` 无持续 401/403/429
- [ ] `git log --oneline -10` 里没有意外的非 `reports/` 页面提交

### 每月

- [ ] 做一次备份（7.1）并抽验解压
- [ ] 检查 PAT / gh 令牌有效期
- [ ] 跑一次 `.\scan.bat -DryRun`，确认无长期不一致
- [ ] 确认 `.gitignore` 仍覆盖 `gh.json` / `llm.json` / `data` / `reports` / `logs` / `.work`

---

## 12. 附录

### 12.1 命令速查

| 目的 | 命令 |
|---|---|
| 启动控制台 | `.\joy.bat` |
| 指定端口 / 不开浏览器 | `.\joy.bat -Port 9000 -NoOpen` |
| 停止服务 | `.\joy.bat --stop` |
| 扫描（干跑） | `.\scan.bat -DryRun` |
| 扫描（小批、不 star） | `.\scan.bat -MaxAdd 5 -NoStar` |
| 扫描 | `.\scan.bat` |
| 读 n 个（生成 summary） | `.\run-joy.bat 5` |
| 读后发布 + 迁移（无界面） | `scripts\render.ps1 -N 5` → `scripts\publish.ps1` → `scripts\migrate.ps1` |
| 阅读干跑 | `.\run-joy.bat 3 -DryRun` |
| 单条重试 | `.\run-joy.bat -OnlyId owner/name` |
| 只抓材料（不调模型、不写盘） | `.\run-joy.bat -OnlyId owner/name -Lite -NoLlm -NoWrite` |
| 调模型但不写盘 | `.\run-joy.bat -OnlyId owner/name -Lite -NoWrite` |
| 渲染最近 5 条 | `powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\render.ps1 -N 5` |
| 渲染指定项目 | `powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\render.ps1 -OnlyId owner/name` |
| 预览报告 | 打开 `reports\latest.html` |
| 发布干跑 | `powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\publish.ps1 -DryRun` |
| 发布（只本地提交、不推送） | `powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\publish.ps1 -NoPush` |
| 发布（真实推送） | `powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\publish.ps1` |
| 迁移干跑 | `powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\migrate.ps1 -DryRun` |
| 回滚迁移 | `powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\migrate.ps1 -Rollback <migrate-runId>` |
| 批量补读 | `.\run-joy.bat -IdsFile ids.txt` |
| 省钱模式 | `.\run-joy.bat 2 -Lite` |
| 一致性修复 | 无 `-Repair`（未实现）；按 7.3 分步重跑对应脚本 |
| 回滚收藏夹 | `powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\migrate.ps1 -Rollback <migrate-runId>` |
| 查看登录 | `gh auth status --hostname github.com` |
| 登录 / 退出 | `gh auth login …` / `gh auth logout --hostname github.com` |
| 查端口占用 | `Get-NetTCPConnection -LocalPort 8787` |
| 收紧密钥权限 | `icacls .\llm.json /inheritance:r /grant:r "$env:USERNAME:(F)"` |
| 测直连 GitHub | `curl.exe -sS -o NUL -w "%{http_code}" --max-time 10 https://github.com` |
| 测代理 | `curl.exe -sS -o NUL -w "%{http_code}" --max-time 10 --proxy http://127.0.0.1:10808 https://github.com` |

### 12.2 目录与文件

| 路径 | 用途 | 是否入库 |
|---|---|---|
| `joy.bat` / `scan.bat` / `run-joy.bat` | 入口 | 是 |
| `config.json` | 业务参数 | 是（不含密钥） |
| `gh.json` / `llm.json` | 凭据 | **否** |
| `service/` / `scripts/` / `templates/` | 代码 | 是 |
| `data/` | 运行期数据（queue/state/summaries/jobs；queue 为临时工作集） | 否 |
| `reports/` | 渲染产物：`<时间戳>.html` + latest.html + index.html | **是**（发布即提交） |
| 根 `index.html` | 站点首页：render 自动生成（同 reports/index.html 数据源，链接带 `reports/` 前缀） | 是 |
| `docs/*.md` | 文档三件套 | 是 |
| `logs/` / `.work/` | 日志与中间产物 | 否 |

### 12.3 退出码

| 码 | 含义 | 常见场景 |
|---|---|---|
| 0 | 成功（含无变化） | 正常结束 |
| 1 | 通用失败 | 脚本异常、磁盘错误 |
| 2 | 配置 / 认证失败 | 缺 `gh.json`、token 无效 |
| 3 | 发布失败 | 分叉、无权限、分支保护 |
| 4 | 服务启动失败 | 端口全占、Node 版本低 |
| 5 | 部分成功 | n 条里有失败（不含 404 消失）；read 有产出时任务显示 `partial` 并继续发布，退出码仍为 5 |

### 12.4 实现后需要回填本节的地方

| 项 | 何时回填 |
|---|---|
| R1：gh 无 TTY 登录的真实表现 | ✅ 已回填（2026-11-19，见 6.3） |
| R2：Lists 所需 scope | 🟡 读取已回填（2026-11-19）：scope 含 `user`、13 个 List 可读；`read` 不存在；写入待 M2 |
| 端口/页面截图路径 | M0 完成后 |
| `-Repair` / `-Rollback` 实际输出样例 | M5 完成后 |
| 本地服务安全（无令牌 403 / 非本机 Host 403 / 端口 8787→8788 回退 / `--stop`） | ✅ 已回填（2026-11-19） |
| 代理自动探测（系统代理 `127.0.0.1:10808`）与登录连通 | ✅ 已回填（2026-11-19，见 6.11） |
| `scan.ps1 -DryRun` | ✅ 已回填（2026-11-19）：75 条候选、将创建 `read`、计划 star 25；未写任何文件 |
| `scan.ps1 -MaxAdd 5 -NoStar`（真实） | ✅ 已回填（2026-11-19）：创建 `read`、unread 35→40、失败 0；复跑 `already_unread=5` |
| 新入选规则（阈值 80/1000/3000，配额 5/8/12，star 过滤） | ✅ DryRun 已回填（2026-11-19）：候选 43、选中 25、计划 star 25；today 5 条已在 unread 故配额顺延补齐 |
| 控制台扫描按钮（`/api/scan` + 干跑开关） | ✅ 已回填（2026-11-19）：任务进度、结果与页面统计联调通过（DryRun：added 20 / ensured 5 / star 25） |
| 阈值 100/2000/5000（DryRun） | ✅ 已回填（2026-11-19）：候选 37、已 unread 19、已 star 1、入选 17（month 12 + 补齐 5）、计划 star 17 |
| `read.ps1 -NoLlm -NoWrite` | ✅ 已回填（2026-11-19）：README 4339 字符、目录树 16 项、lite 不取关键文件 |
| `read.ps1 -OnlyId ... -Lite`（真实） | ✅ 已回填（2026-11-19）：overview 126 字、Q&A 6 组、warnings 0；summary 落盘、队列置 done、state.lastRead 更新 |
| 控制台「阅读」按钮（`/api/read`） | ✅ 已回填（2026-11-19）：DryRun n=2 通过；NoWrite n=1 真实调用成功（1 成功 / 0 失败 / 1 次 LLM）；n=0 返回 400 |
| `render.ps1`（本地渲染） | ✅ 已回填（2026-11-19）：chronytop 生成 7823 字节报告（1 卡片 / 6 问答），latest 与 index 同步；XSS 样例全部转义 |
| `publish.ps1 -DryRun/-NoPush` | ✅ 已回填（2026-11-19）：DryRun 列出 4 个文件；NoPush 提交 `5f8618b`，仅 docs/ 下 4 个文件，未推送 |
| `migrate.ps1 -DryRun` | ✅ 已回填（2026-11-19）：临时标记 published 后选中 1 条，目标为 read List；未真实迁移（等待真实发布） |
| `read.ps1 -DryRun`（以 unread List 为准） | ✅ 已回填（2026-11-19）：List 60 项、选中 5 个（cursor/plugins 等）、`created=5`；DryRun 未写队列 |
| `read.ps1 -N 1 -Lite -NoLlm` | ✅ 已回填（2026-11-19）：镜像 1 条到队列（seq/nodeId/stars 正确），只抓材料不调模型，状态保持 pending |
| `read.ps1` n=3 deep（故障与修复） | ✅ 已回填（2026-11-19）：3 条 summary 生成成功但队列标记抛 `readRunId` 属性不存在；修复后 3 条恢复 done，`render -N 3` 生成 3 卡片 / 15 问答 |
| 真实发布（仓库 + Pages） | ✅ 已回填（2026-11-19）：创建 public 仓库、`master` / `docs` Pages；publish 推送后标记 2 份报告 / 4 条 published；`https://gingkorich.github.io/GithubJoy/` 返回 200 |
| 真实迁移 | ✅ 已回填（2026-11-19）：迁移 4 条（chronytop + n3 三条），unread 60→56、read 0→4，快照 `lists-migrate-20261119-182132.json` |
| 控制台自动流水线 | ✅ 已回填（2026-11-19）：点一次「阅读」（n=1, Lite）后自动完成 阅读→渲染→发布→迁移；unread 55→54、read 5→6，Pages 新页面 200 |
| AC-1～AC-14 实测结果 | M2–M5 逐条 |
| 队列架构收尾（2026-11-20）：read/publish 死代码清理、概览 stats 化 | ✅ 已回填（2026-11-20，见 MEMORY「队列架构收尾清理」）：`read.ps1 -DryRun -N 2` 通过（unread 58 选中 2、queue 零写入）、`publish.ps1 -DryRun` 通过、server/app `node --check` 通过 |
| star 修复三连（2026-11-20）：304 不计配额、star filter 失败重试 | ✅ 已回填（2026-11-20）：`scan.ps1 -DryRun` exit 0，star filter 命中 1 条已 star 过滤；304 分支与重试路径经 Parser+DryRun 验证 |
| read 部分成功语义（2026-11-20）：`gone` 独立计数 + 自动 unstar 清理、任务状态 `partial` | ✅ 已回填（2026-11-20，见 MEMORY 同名条目）：`read.ps1` 404 不再计入 failed；真实运行时对 gone 条目执行 unstar（失败仅告警）；server 对「read 退出码 5 但 succeeded>0」显示 `partial`（琥珀色标签），页面进度文案含「消失 n」与部分成功提示；流水线行为不变（≥1 条 done 即继续） |