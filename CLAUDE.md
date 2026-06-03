# worktree-flow

Git worktree 多 Agent 并行开发辅助工具。

## 命令

```
/worktree init                   初始化主分支配置
/worktree sync [--force]         同步当前 worktree 改动到主目录
/worktree reject [--force]       回滚主目录到 origin/mainBranch
```

## 文件结构

- `worktree.md` — Claude Code 命令入口（薄层，调用 shell 脚本）
- `scripts/worktree-flow.sh` — 核心 git 逻辑
- `install.sh` — 安装到 `~/.claude/commands/`

## 安装

```bash
bash install.sh
```

## 设计原则

- `set -euo pipefail`
- 不依赖 jq/python3，用 grep+sed 处理 JSON
- 配置文件 `.claude/worktree-flow.json` 放在主仓库根目录
- 非 TTY 环境兼容（Claude Code 调用场景）
