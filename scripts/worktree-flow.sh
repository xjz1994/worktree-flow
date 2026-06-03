#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
CONFIG_DIR=".claude"
CONFIG_FILE="worktree-flow.json"

# --- Global cleanup ---
CLEANUP_DIRS=()
CLEANUP_FILES=()
_cleanup() {
  [ ${#CLEANUP_DIRS[@]} -gt 0 ] && rm -rf "${CLEANUP_DIRS[@]}" 2>/dev/null || true
  [ ${#CLEANUP_FILES[@]} -gt 0 ] && rm -f "${CLEANUP_FILES[@]}" 2>/dev/null || true
}
trap _cleanup EXIT

# --- Utility ---
die()  { echo "Error: $*" >&2; exit 1; }
info() { echo "$*"; }

# --- Config paths ---

# For init — config lives in current repo root
main_config_path() {
  local root
  root="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not in a git repository"
  echo "$root/$CONFIG_DIR/$CONFIG_FILE"
}

# For sync/reject from a worktree — config lives in main repo root
worktree_config_path() {
  local common_dir main_root
  common_dir="$(git rev-parse --git-common-dir 2>/dev/null)" || die "not in a git repository"
  main_root="$(dirname "$common_dir")"
  echo "$main_root/$CONFIG_DIR/$CONFIG_FILE"
}

config_path() {
  local cfg
  cfg="$(worktree_config_path 2>/dev/null)"
  [ -f "$cfg" ] && { echo "$cfg"; return 0; }
  cfg="$(main_config_path 2>/dev/null)"
  echo "$cfg"
}

load_config() {
  local cfg
  cfg="$(config_path)"
  [ -f "$cfg" ] || die "config not found at $cfg (run 'init' first)"

  # Parse flat JSON string values with standard tools (no python3/jq)
  _json_read() { grep -o "\"${1}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$2" | sed 's/.*: *"\(.*\)"/\1/'; }

  CFG_mainBranch="$(_json_read mainBranch "$cfg")"
  CFG_mainDir="$(_json_read mainDir "$cfg")"
  CFG_repoName="$(_json_read repoName "$cfg")"

  [ -n "$CFG_mainDir" ]    || die "config missing mainDir"
  [ -n "$CFG_mainBranch" ] || die "config missing mainBranch"
}

save_config() {
  local cfg="$1" main_branch="$2" main_dir="$3" repo_name="$4"
  mkdir -p "$(dirname "$cfg")"
  cat > "$cfg" <<-EOF
{
  "mainBranch": "$main_branch",
  "mainDir": "$main_dir",
  "repoName": "$repo_name",
  "worktrees": []
}
EOF
}

require_config() {
  load_config

  # Validate mainDir exists
  [ -d "$CFG_mainDir" ] || die "mainDir '$CFG_mainDir' does not exist (moved?)"

  # Validate remote tracking branch exists (try fetch first, then suggest)
  if ! git rev-parse --verify "origin/$CFG_mainBranch" >/dev/null 2>&1; then
    # One fetch attempt in case it's just stale
    git fetch origin "$CFG_mainBranch" 2>/dev/null || true
    if ! git rev-parse --verify "origin/$CFG_mainBranch" >/dev/null 2>&1; then
      die "remote branch 'origin/$CFG_mainBranch' not found (try 'git fetch origin $CFG_mainBranch')"
    fi
  fi
}

# --- Path safety ---
validate_relpath() {
  local p="$1"
  [ -n "$p" ]         || die "path is empty"
  [ "${p:0:1}" != "/" ] && [ "${p:0:2}" != "~" ] || die "absolute path not allowed: $p"
  [ "${p:0:3}" != "../" ] && [ "$p" != ".." ]     || die "path outside repository not allowed: $p"
  case "/$p/" in *"/../"*) die "path traversal detected: $p" ;; esac
}

# --- Main dir dirty-state protocol ---
check_main_dirty() {
  [ -d "$CFG_mainDir" ] || return 0

  local status_output
  status_output="$(cd "$CFG_mainDir" && git status --porcelain 2>/dev/null || true)"
  [ -z "$status_output" ] && return 0

  local action="${WORKTREE_FLOW_DIRTY_ACTION:-}"

  if [ -z "$action" ]; then
    # Protocol: tell caller to ask user for a choice
    echo "DIRTY_STATE_CHOICE_REQUIRED"
    echo "Main directory ($CFG_mainDir) has uncommitted changes:"
    echo "$status_output"
    exit 2
  fi

  case "$action" in
    stash)
      info "stashing changes in main directory ..."
      (cd "$CFG_mainDir" && git stash push -u -m "worktree-flow auto-stash $(date '+%Y%m%d-%H%M%S')")
      info "stash created"
      ;;
    commit:*)
      local msg="${action#commit:}"
      [ -n "$msg" ] || die "commit message required — use format: commit:<message>"
      info "committing changes in main directory ..."
      (cd "$CFG_mainDir" && git add -A && git commit -m "$msg")
      info "committed: $msg"
      ;;
    discard)
      info "discarding changes in main directory ..."
      (cd "$CFG_mainDir" && git reset --hard && git clean -fd)
      info "changes discarded"
      ;;
    continue)
      info "continuing despite dirty state ..."
      ;;
    abort)
      die "operation aborted by user"
      ;;
    *)
      die "unknown WORKTREE_FLOW_DIRTY_ACTION: $action (stash | commit:<msg> | discard | continue | abort)"
      ;;
  esac
}

# --- Enhanced binary patch (includes untracked files via temp index) ---
write_sync_patch() {
  local patch_file="$1"
  local main_branch="${2:-main}"
  local remote_branch="origin/$main_branch"

  local tmpdir tmpindex untracked
  tmpdir="$(mktemp -d)"
  CLEANUP_DIRS+=("$tmpdir")

  # Copy real index into temp index
  tmpindex="$tmpdir/index"
  cp "$(git rev-parse --git-dir)/index" "$tmpindex"

  # Add untracked files to temp index so they appear in the binary diff
  untracked="$(git ls-files --others --exclude-standard)"
  if [ -n "$untracked" ]; then
    echo "$untracked" | GIT_INDEX_FILE="$tmpindex" git update-index --add --stdin 2>/dev/null || true
  fi

  # Generate binary diff
  if ! GIT_INDEX_FILE="$tmpindex" git diff --binary "$remote_branch" > "$patch_file" 2>/dev/null; then
    # Fallback: new branch without tracking — diff against HEAD
    GIT_INDEX_FILE="$tmpindex" git diff --binary HEAD > "$patch_file" 2>/dev/null || true
  fi
}

# --- Apply patch in main directory ---
apply_patch_to_main() {
  local patch_file="$1"
  (cd "$CFG_mainDir" && git apply --3way "$patch_file" 2>&1) || die "patch apply failed (conflict resolution needed)"
}

# --- Force-sync: direct file copy ---
force_sync_files() {
  local main_branch="${1:-main}"
  local remote_branch="origin/$main_branch"

  # Modified tracked files
  local changed
  changed="$(git diff --name-only "$remote_branch" 2>/dev/null || git diff --name-only HEAD 2>/dev/null || true)"

  # New untracked files
  local untracked
  untracked="$(git ls-files --others --exclude-standard 2>/dev/null || true)"

  # Merge & deduplicate
  local all_files
  all_files="$(printf '%s\n%s\n' "$changed" "$untracked" | grep -v '^$' | sort -u || true)"
  [ -n "$all_files" ] || { info "no files to sync"; return 0; }

  local count=0
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    validate_relpath "$f"

    local src="$f"
    local dst="$CFG_mainDir/$f"

    if [ -f "$src" ] || [ -d "$src" ]; then
      mkdir -p "$(dirname "$dst")"
      if [ -d "$src" ]; then
        cp -r "$src" "$dst" 2>/dev/null || true
      else
        cp "$src" "$dst"
      fi
      count=$((count + 1))
    fi
  done <<< "$all_files"

  info "force-synced $count files to $CFG_mainDir"
}

# --- Reject ---
check_main_local_commits() {
  local main_branch="$1"
  local remote_branch="origin/$main_branch"

  local commits
  commits="$(cd "$CFG_mainDir" && git log --oneline "$remote_branch..HEAD" 2>/dev/null || true)"
  if [ -n "$commits" ]; then
    echo "WARNING: main branch has commits not on $remote_branch:"
    echo "$commits"
    return 1
  fi
  return 0
}

do_reject() {
  info "resetting $CFG_mainDir to origin/$CFG_mainBranch ..."
  (cd "$CFG_mainDir" && git reset --hard "origin/$CFG_mainBranch")
  info "reject complete — main branch now matches origin/$CFG_mainBranch"
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

cmd_init() {
  local root
  root="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not in a git repository"

  # Resolve default branch from origin/HEAD or fallback to main
  local main_branch
  main_branch="$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|^refs/remotes/origin/||' || true)"
  [ -n "$main_branch" ] || main_branch="main"

  local repo_name
  repo_name="$(basename "$root")"

  local cfg
  cfg="$(main_config_path)"

  save_config "$cfg" "$main_branch" "$root" "$repo_name"
  info "init complete: mainBranch=$main_branch  mainDir=$root  repoName=$repo_name"
}

cmd_sync() {
  local force="${1:-}"
  require_config

  if [ "$force" = "--force" ]; then
    info "force sync — skipping dirty check, using direct file copy ..."
    force_sync_files "$CFG_mainBranch"
  else
    check_main_dirty
    info "syncing $(git rev-parse --abbrev-ref HEAD) -> $CFG_mainBranch"

    local patch_file
    patch_file="$(mktemp /tmp/worktree-flow-sync-XXXXXX.patch)"
    CLEANUP_FILES+=("$patch_file")

    write_sync_patch "$patch_file" "$CFG_mainBranch"

    local patch_size
    patch_size="$(wc -c < "$patch_file" 2>/dev/null || echo 0)"
    if [ "$patch_size" -eq 0 ]; then
      info "no changes to sync"
      return 0
    fi

    info "applying patch ($patch_size bytes) with 3-way merge ..."
    apply_patch_to_main "$patch_file"
    info "sync complete"
  fi
}

cmd_reject() {
  local force="${1:-}"
  require_config

  # Show local-commits warning if present
  check_main_local_commits "$CFG_mainBranch" || true

  # If local commits exist and no --force, block
  if [ "$force" != "--force" ]; then
    local commits
    commits="$(cd "$CFG_mainDir" && git log --oneline "origin/$CFG_mainBranch..HEAD" 2>/dev/null || true)"
    if [ -n "$commits" ]; then
      die "reject blocked: local commits not on origin/$CFG_mainBranch (use --force to discard them)"
    fi
  fi

  # Require explicit confirmation
  if [ "${WORKTREE_FLOW_ASSUME_YES:-0}" != "1" ]; then
    die "reject is destructive — set WORKTREE_FLOW_ASSUME_YES=1 to confirm"
  fi

  do_reject
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  [ $# -ge 1 ] || die "usage: $SCRIPT_NAME {init | sync [--force] | reject [--force]}"

  local cmd="$1"
  shift

  case "$cmd" in
    init)   cmd_init "$@" ;;
    sync)   cmd_sync "${1:-}" ;;
    reject) cmd_reject "${1:-}" ;;
    *)      die "unknown command: $cmd (usage: init | sync [--force] | reject [--force])" ;;
  esac
}

main "$@"
