# worktree-flow

> `claude -w` 多 Agent 并行开发。每个 Agent 在独立 worktree 编码，改动自动同步到主目录集中调试。告别重复依赖安装、端口冲突与中间件浪费。

## 痛点

用 Claude Code 做多 Agent 并行开发时，每个 Agent 默认在独立工作目录，带来三个麻烦：

**1. 重复安装依赖**

前端：每个 worktree 跑一遍 `npm install` / `pnpm install`，node_modules 动辄几百 MB。

后端：每个 worktree 跑 `pip install` / `go mod download` / `cargo build` / `mvn install`，依赖和编译缓存同样白白重复。

磁盘浪费 + 安装等待，每开一个 Agent 拖几分钟。

**2. 重复启动服务**

每个 worktree 需要独立启动开发服务器。前端要改端口配置（3000 → 3001 → 3002…），后端则要改 FastAPI/Spring Boot 端口（8001 → 8002…），更麻烦的是数据库、Redis、消息队列等中间件也得各起一套或反复切换配置。配置文件改来改去容易漏。

**3. 微前端 / 微服务端口爆炸**

微前端项目（Module Federation 等）每个子应用独立 dev server。微服务项目同理——每个服务自带端口。碰上 worktree 分支开发，端口数量再翻倍。占用多、配置乱、心智负担重。

## 方案

**所有 worktree 的代码改动自动同步到主目录，你在主目录统一调试。中间件也只需在主目录启动一次。**

```
┌─────────────────────────────────────────────────────┐
│                 主目录 (main)                          │
│  node_modules ✅   dev server ✅  端口 ✅              │
│  DB / Redis / MQ ✅  (全局只用一套)                     │
│                                                       │
│  ┌──────────────┐  ┌──────────────┐                  │
│  │  feature/a    │  │  bugfix/b    │  ← 同步代码      │
│  └──────┬───────┘  └──────┬───────┘                  │
│         │                 │                           │
│         ▼                 ▼                           │
│    worktree/a        worktree/b                       │
│    (git branch)      (git branch)                     │
└─────────────────────────────────────────────────────┘
```

只需 3 个命令 + `claude -w`：

| 命令 | 作用 |
|------|------|
| `claude -w` | 启动新 Agent，自动创建独立的 git worktree |
| `/worktree init` | 初始化：记录主分支路径，后续同步以此为基准 |
| `/worktree sync` | 同步：把当前 worktree 的改动合并到主目录 |
| `/worktree reject` | 回滚：放弃主目录本地改动，恢复到远端主分支状态 |

**一个 dev server / 一套中间件，N 个 Agent，所有代码汇聚调试。**

## 安装

```bash
# 克隆本仓库
git clone <repo-url>

# 一步安装到 Claude Code 命令目录
bash install.sh

# 主目录初始化
claude                    # 启动 Claude Code
# 在 Claude Code 中执行
/worktree init

# 新终端启动 worktree Agent（多 Agent 并行）
claude -w                 # 自动创建 worktree + 启动 Agent
```

安装脚本会自动处理 WSL 路径兼容。

> **后端同样适用**：Go、Python、Java、Rust、Node.js 后端项目痛点完全一致——依赖重装慢、端口配置乱、中间件多开成本高。worktree-flow 让所有 Agent 共享主目录的编译缓存、开发服务和数据库/Redis/MQ 等基础设施，sync 代码后统一验证，省时省心。

## 核心命令

### init — 初始化

```bash
/worktree init
```

在任何分支上执行均可。脚本会：

- 从 `origin/HEAD` 解析远端默认分支（如 `main` / `master`）
- 若 `origin/HEAD` 不存在，自动 fallback 到 `main`
- 保存仓库路径、分支名到 `.claude/worktree-flow.json`
- 后续 sync/reject 以此配置为准

**执行时机**：只在主目录执行一次，新增 worktree 后无需重复 init。

### sync — 同步

```bash
/worktree sync          # 自动模式：生成 patch，3-way merge 合并到主目录
/worktree sync --force  # 强制模式：直接文件复制覆盖到主目录
```

在 worktree 分支上执行，把当前 worktree 的改动合并到主目录。

**自动模式**（推荐）：

- 生成 worktree 与远端主分支的 binary patch
- 在主目录用 `git apply --3way` 合并，自动处理冲突

**强制模式**：

- 跳过 dirty 检查和 merge，直接全量复制文件
- 适合信任 worktree 状态、不想处理冲突合并的场景

**脏状态处理**：如果主目录有未提交改动，脚本会退出并列出脏文件，让你选择：

| 选项 | 行为 |
|------|------|
| stash | 暂存主目录改动 |
| commit | 提交主目录改动（需输入 commit message） |
| discard | 丢弃主目录改动 |
| continue | 忽略脏状态继续 |
| abort | 取消操作 |

### reject — 回滚

```bash
/worktree reject           # 回滚主目录到 origin/mainBranch（需确认）
/worktree reject --force   # 强制回滚，丢弃本地提交（需确认）
```

当主目录状态乱了、或者想放弃当前方向的改动时使用。

- 回滚前会检查并列出本地尚未推送到远端的 commit
- 需要显式确认（`WORKTREE_FLOW_ASSUME_YES=1`）才能执行，防止误操作

## 工作流

### 基础流程（4 步）

```
  终端 1 (主目录)                终端 2 (worktree Agent)
  ┌──────────────┐              ┌──────────────────────┐
  │ claude        │              │ claude -w             │
  │ /worktree init│              │ (自动创建 worktree)    │
  │               │              │ coding on feature/a   │
  │               │◄──sync──────│ /worktree sync         │
  │ npm run dev   │              │                       │
  │ 集中调试验收   │              │ 终端 3 (worktree Agent)
  │               │              │ ├── claude -w          │
  │ /worktree     │              │ └── /worktree sync     │
  │   reject      │              └──────────────────────┘
  │ (不符合预期)   │
  └──────────────┘
```

**Step 1 — 主目录初始化**

在项目根目录启动 Claude Code：

```bash
cd my-project
claude
```

执行 `/worktree init`，记录主分支路径。**只需一次。**

---

**Step 2 — 启动 worktree Agent**

```bash
claude -w
```

`claude -w` 自动：

- 基于主分支创建 git worktree（隔离工作目录）
- 在新目录启动 Claude Code 会话
- 多个 `claude -w` 可同时运行，互不干扰

Agent 中自由编码，不影响主目录。

---

**Step 3 — 同步回主目录调试**

在 worktree Agent 中执行：

```
/worktree sync
```

改动通过 patch 合并到主目录。之后在主目录统一验证：

```bash
# 前端
npm run dev         # 统一 dev server，直接看效果
npm run test        # 统一跑测试

# 后端
uvicorn main:app    # FastAPI 统一启动
./mvnw spring-boot:run  # Spring Boot
docker compose up   # 中间件（DB / Redis / MQ）只需一套
```

---

**Step 4 — 验收 & 回滚**

| 结果 | 操作 |
|------|------|
| ✅ 符合预期 | 在 worktree 中正常 commit & push，worktree 可删除 |
| ❌ 不符合预期 | 在主目录执行 `/worktree reject`，恢复到 `origin/mainBranch` |

`reject` 会放弃主目录所有本地改动——包括 worktree sync 过来的代码。放心试错。

---

### 多 Agent 并行开发

```
终端 1 (主目录)
├── claude
│   /worktree init
│   npm run dev          ← 统一 dev server，接收所有 Agent 代码
│
终端 2 (Agent A: feature/login)
├── claude -w
│   coding...
│   /worktree sync       ← 同步到主目录
│
终端 3 (Agent B: feature/payment)
├── claude -w
│   coding...
│   /worktree sync       ← 同步到主目录
│
终端 4 (Agent C: bugfix/header)
├── claude -w
│   coding...
│   /worktree sync       ← 同步到主目录
```

每个 `claude -w` 启动一个独立 Agent，各自在隔离的 worktree 中工作。完成一部分就 `/worktree sync` 把代码送回主目录，主目录的 dev server 立刻包含所有改动，集中验证。

互不阻塞，互不干扰。

### 放弃改动

```bash
/worktree reject          # 主目录回退到远端分支状态
# worktree 退出时可选删除
# 已完成的 worktree 放心删除，不影响主目录
# 继续新任务？再开一个 claude -w
```

## 配置

配置文件 `repo-root/.claude/worktree-flow.json`：

```json
{
  "mainBranch": "main",
  "mainDir": "/path/to/repo-root",
  "repoName": "my-project",
  "worktrees": []
}
```

环境变量：

| 变量 | 说明 |
|------|------|
| `WORKTREE_FLOW_DIRTY_ACTION` | 脏状态处理策略：`stash` / `commit:<msg>` / `discard` / `continue` / `abort` |
| `WORKTREE_FLOW_ASSUME_YES` | reject 确认开关：设为 `1` 跳过确认 |

## 设计原则

- `set -euo pipefail` 严格模式
- 零外部依赖——用 `grep` + `sed` 解析 JSON，不依赖 `jq` / `python3`
- 非 TTY 环境兼容（Claude Code 后台调用场景）
- WSL 路径自动兼容

## 文件结构

```
.
├── README.md                    # 本文件
├── CLAUDE.md                    # Claude Code 项目指令
├── worktree.md                  # /worktree 命令入口
├── install.sh                   # 安装脚本
└── scripts/
    └── worktree-flow.sh         # 核心 git 逻辑（300+ 行 bash）
```

## 对比：有 / 无 worktree-flow

| | 传统 worktree 开发 | + worktree-flow |
|---|---|---|
| 依赖安装 | 每个 worktree 单独装 | 主目录装一次即可 |
| 编译缓存 | 各 worktree 各自编译，缓存不共享 | 主目录编译缓存全局共享 |
| Dev Server | 每个 worktree 各自启动，需改造端口逻辑 | 主目录统一启动 |
| 中间件（DB/Redis/MQ） | 各 worktree 各起一套或反复改配置 | 主目录一套，所有 Agent 共享 |
| 微前端 / 微服务端口 | main + worktree 双倍端口占用 | 只需主目录一套端口 |
| 多 Agent | 各自目录各自跑，没法集中验证 | N 个 `claude -w` 同步到主目录统一验证 |
| 学习成本 | 记住 git worktree 全套命令 | 记住 `claude -w` + 3 个命令就够了 |

## License

MIT
