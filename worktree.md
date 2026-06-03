# /worktree

Git worktree 多 Agent 并行开发辅助命令。

## 用法

```
/worktree init                   初始化主分支配置
/worktree sync [--force]         同步当前 worktree 改动到主目录
/worktree reject [--force]       回滚主目录到 origin/mainBranch
```

## Claude 执行流程

用户输入 `/worktree <subcommand> [args]` 时，执行以下步骤：

### 1. 定位脚本

按顺序查找 `worktree-flow.sh`：

```bash
SCRIPT=""
# 优先：Claude 命令目录下的脚本
if [ -f "$HOME/.claude/commands/scripts/worktree-flow.sh" ]; then
  SCRIPT="$HOME/.claude/commands/scripts/worktree-flow.sh"
# 备选：项目仓库根目录下的脚本
else
  ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
  if [ -n "$ROOT" ] && [ -f "$ROOT/scripts/worktree-flow.sh" ]; then
    SCRIPT="$ROOT/scripts/worktree-flow.sh"
  fi
fi
if [ -z "$SCRIPT" ]; then
  # 输出错误信息并终止
  echo "Error: worktree-flow.sh not found (checked ~/.claude/commands/scripts/ and repo scripts/)"
  exit 1
fi
```

找到脚本后，用 `bash "$SCRIPT" <subcommand> [args]` 执行对应子命令。

### 2. 执行子命令

**init** — 直接执行，无特殊交互：

```bash
bash "$SCRIPT" init
```

**sync** — 普通模式执行，处理脏状态协议：

```bash
bash "$SCRIPT" sync
```

若 exit code = 2 且 stdout 首行含 `DIRTY_STATE_CHOICE_REQUIRED`，进入脏状态处理（见下文）。

**sync --force** — 无交互，直接执行：

```bash
WORKTREE_FLOW_DIRTY_ACTION=continue bash "$SCRIPT" sync --force
```

**reject** — 先获取信息，再确认后执行：

```bash
WORKTREE_FLOW_ASSUME_YES=0 bash "$SCRIPT" reject
```

若 exit code != 0 且 stdout 含本地提交信息，展示给用户确认后重新执行：

```bash
WORKTREE_FLOW_ASSUME_YES=1 bash "$SCRIPT" reject
```

**reject --force** — 跳过本地提交检查，但仍需确认：

```bash
# 第一步：通知用户即将丢失的改动（脚本会打印 WARNING）
WORKTREE_FLOW_ASSUME_YES=0 bash "$SCRIPT" reject --force
# 第二步：确认后执行
WORKTREE_FLOW_ASSUME_YES=1 bash "$SCRIPT" reject --force
```

## 脏状态处理协议（exit code 2）

当 `sync` 或 `init` 检测到主目录有未提交改动时，脚本 exit code 2，
stdout 首行输出 `DIRTY_STATE_CHOICE_REQUIRED`，后续行为脏文件列表。

Claude 必须：

1. 将脏文件列表展示给用户
2. 用 AskUserQuestion（单选）弹选项：

| 选项 | 环境变量值 | 说明 |
|------|-----------|------|
| stash | `WORKTREE_FLOW_DIRTY_ACTION=stash` | git stash push -u |
| commit | `WORKTREE_FLOW_DIRTY_ACTION=commit:<msg>` | git add -A && git commit（需用户提供 msg） |
| discard | `WORKTREE_FLOW_DIRTY_ACTION=discard` | git reset --hard && git clean -fd |
| continue | `WORKTREE_FLOW_DIRTY_ACTION=continue` | 忽略脏状态继续 |
| abort | `WORKTREE_FLOW_DIRTY_ACTION=abort` | 终止操作 |

3. 若用户选择 commit，再弹输入框获取提交信息
4. 设好环境变量后重新执行：`WORKTREE_FLOW_DIRTY_ACTION=<choice> bash "$SCRIPT" sync`

**不要替用户做决定。** 脏文件列表必须展示。

## reject 确认协议

reject 是破坏性操作（reset --hard 丢失本地提交）。

Claude 必须：

1. 先用 `WORKTREE_FLOW_ASSUME_YES=0 bash "$SCRIPT" reject` 执行
2. 脚本会打印本地提交信息（如果有）并报错退出
3. 将提交信息展示给用户，用 AskUserQuestion 确认
4. 用户确认后，用 `WORKTREE_FLOW_ASSUME_YES=1 bash "$SCRIPT" reject` 执行
5. 用户拒绝则终止
