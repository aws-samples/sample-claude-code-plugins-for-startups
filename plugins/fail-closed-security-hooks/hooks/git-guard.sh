#!/bin/bash
# =============================================================================
# Git Guard — Enterprise Git Security Hook for Claude Code
# =============================================================================
# Hook version: 1.0.0
# Last updated: 2026-05-28
# Compatible with: claude-code 2.1.150+
# Dependencies: bash 4+, jq (preferred), git, sed, grep
# Maintainer: <your security team email>
# Change log:
#   1.0.0 (2026-05-28) — initial release: allowlist, branch protection,
#                         force-push, destructive op prevention
# =============================================================================
# Comprehensive git protection that allows enterprise workflows while blocking
# data exfiltration, destructive operations, and policy violations.
#
# Hook event: PreToolUse (matcher: Bash)
# Inspects git commands and enforces:
#   1. Remote URL allowlist (only push to enterprise domains)
#   2. Force-push prevention (--force / --force-with-lease)
#   3. Branch protection (no direct push to main/master/release/*)
#   4. Remote modification control (add/set-url only to allowed domains)
#   5. Destructive operation prevention (reset --hard, clean -fd, checkout --force)
#
# Note: Credential leak detection in file content is handled by pii-guard.sh
# (which scans Write/Edit tool inputs before files are written to disk).
#
# Configuration via environment variables (set in settings.json env block):
#   GIT_GUARD_ALLOWED_DOMAINS    — comma-separated allowed push domains
#                                  (default: "github.com,gitlab.com,bitbucket.org")
#   GIT_GUARD_PROTECTED_BRANCHES — comma-separated branches requiring PR
#                                  (default: "main,master,release/*,production")
#   GIT_GUARD_ALLOW_FORCE_PUSH   — "true" to allow force push (default: "false")
#   GIT_GUARD_MAX_FILE_SIZE_KB   — max file size in KB (default: "10240" = 10MB)
#   GIT_GUARD_CI_MODE            — "true" to relax branch protection for CI/CD
#   GIT_GUARD_DISABLED           — "true" to bypass all checks (emergency)
#
# Exit codes:
#   0 = allow
#   2 = block (stderr shown to Claude)
# =============================================================================

set -u
input=$(cat)

# --- Parse input ---
if command -v jq >/dev/null 2>&1; then
  tool_name=$(printf '%s' "$input" | jq -r '.tool_name // empty')
  command_str=$(printf '%s' "$input" | jq -r '.tool_input.command // empty')
else
  tool_name=$(printf '%s' "$input" | grep -oE '"tool_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed -E 's/.*"([^"]+)"$/\1/')
  command_str=$(printf '%s' "$input" | grep -oE '"command"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed -E 's/.*"([^"]+)"$/\1/')
fi

# Only inspect Bash tool
[[ "$tool_name" != "Bash" ]] && exit 0

# Normalize whitespace
norm=$(printf '%s' "$command_str" | sed -E 's/[[:space:]]+/ /g' | sed -E 's/^ //')

# Check if this is a git command at all
if ! echo "$norm" | grep -qE '(^|[;&|]|&&|\|\|)[[:space:]]*git[[:space:]]'; then
  exit 0
fi

# --- Configuration ---
ALLOWED_DOMAINS="${GIT_GUARD_ALLOWED_DOMAINS:-github.com,gitlab.com,bitbucket.org}"
PROTECTED_BRANCHES="${GIT_GUARD_PROTECTED_BRANCHES:-main,master,release/*,production}"
ALLOW_FORCE="${GIT_GUARD_ALLOW_FORCE_PUSH:-false}"
MAX_FILE_KB="${GIT_GUARD_MAX_FILE_SIZE_KB:-10240}"
CI_MODE="${GIT_GUARD_CI_MODE:-false}"
DISABLED="${GIT_GUARD_DISABLED:-false}"

[[ "$DISABLED" == "true" ]] && exit 0

# --- Helper: check if URL domain is in allowlist ---
url_allowed() {
  local url="$1"
  local domain=""

  # Extract domain from various URL formats
  if echo "$url" | grep -qE '^https?://'; then
    domain=$(echo "$url" | sed -E 's|https?://([^/:@]+).*|\1|')
  elif echo "$url" | grep -qE '^git@'; then
    domain=$(echo "$url" | sed -E 's|git@([^:]+):.*|\1|')
  elif echo "$url" | grep -qE '^ssh://'; then
    domain=$(echo "$url" | sed -E 's|ssh://([^@]+@)?([^/:]+).*|\2|')
  else
    # Unknown format — block by default
    return 1
  fi

  # Check against allowlist
  IFS=',' read -ra domains <<< "$ALLOWED_DOMAINS"
  for allowed in "${domains[@]}"; do
    allowed=$(echo "$allowed" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    # Support wildcard: *.example.com matches sub.example.com
    if [[ "$allowed" == \** ]]; then
      local suffix="${allowed#\*}"
      if [[ "$domain" == *"$suffix" ]]; then
        return 0
      fi
    elif [[ "$domain" == "$allowed" ]]; then
      return 0
    fi
  done
  return 1
}

# --- Helper: check if branch matches protected pattern ---
branch_protected() {
  local branch="$1"
  IFS=',' read -ra branches <<< "$PROTECTED_BRANCHES"
  for pattern in "${branches[@]}"; do
    pattern=$(echo "$pattern" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    # Support glob: release/* matches release/v1.0
    if [[ "$branch" == $pattern ]]; then
      return 0
    fi
  done
  return 1
}

# --- Helper: get remote URL from name ---
get_remote_url() {
  local remote_name="$1"
  local cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
  if [[ -n "$cwd" ]] && [[ -d "$cwd/.git" || -f "$cwd/.git" ]]; then
    git -C "$cwd" remote get-url "$remote_name" 2>/dev/null
  else
    git remote get-url "$remote_name" 2>/dev/null
  fi
}

# --- Deny helper ---
deny() {
  printf 'GIT GUARD: %s\nCommand: %s\n' "$1" "$command_str" >&2
  exit 2
}

# =============================================================================
# CHECK 1: git remote add / set-url — URL must be in allowlist
# =============================================================================
if echo "$norm" | grep -qE '(^|[;&|])[[:space:]]*git[[:space:]]([^;&|]*[[:space:]])?remote[[:space:]]+(add|set-url)[[:space:]]'; then
  # Extract URL (last argument that looks like a URL)
  url=$(echo "$norm" | grep -oE '(https?://[^ ]+|git@[^ ]+|ssh://[^ ]+)' | tail -1)
  if [[ -n "$url" ]]; then
    if ! url_allowed "$url"; then
      deny "Remote URL not in enterprise allowlist. Allowed domains: $ALLOWED_DOMAINS. Blocked URL: $url"
    fi
  fi
  # If no URL found in command, allow (might be a rename or other subcommand)
fi

# =============================================================================
# CHECK 2: git remote rename / rm — block (prevents circumventing allowlist)
# =============================================================================
if echo "$norm" | grep -qE '(^|[;&|])[[:space:]]*git[[:space:]]([^;&|]*[[:space:]])?remote[[:space:]]+(rename|rm|remove)[[:space:]]'; then
  deny "Modifying or removing git remotes is restricted. Contact your team lead to change remote configuration."
fi

# =============================================================================
# CHECK 3: git push — multiple checks
# =============================================================================
if echo "$norm" | grep -qE '(^|[;&|])[[:space:]]*git[[:space:]]([^;&|]*[[:space:]])?push[[:space:]]'; then

  # 3a. Force push check
  if [[ "$ALLOW_FORCE" != "true" ]]; then
    if echo "$norm" | grep -qE '\-\-force|\-f[[:space:]]|\-\-force-with-lease'; then
      deny "Force push is forbidden by enterprise policy. Use a regular push or create a new branch."
    fi
  fi

  # 3b. Extract remote name and branch from push command
  # Pattern: git push [options] <remote> [<branch>]
  push_args=$(echo "$norm" | sed -E 's/.*git[[:space:]]([^;&|]*[[:space:]])?push[[:space:]]*//' | sed -E 's/[;&|].*//')
  # Remove flags
  push_args=$(echo "$push_args" | sed -E 's/--[a-z-]+[[:space:]]*//g; s/-[a-z][[:space:]]*//g' | sed 's/^[[:space:]]*//')

  remote_name=$(echo "$push_args" | awk '{print $1}')
  branch_name=$(echo "$push_args" | awk '{print $2}')

  # 3c. Check remote URL is in allowlist
  if [[ -n "$remote_name" ]]; then
    remote_url=$(get_remote_url "$remote_name")
    if [[ -n "$remote_url" ]]; then
      if ! url_allowed "$remote_url"; then
        deny "Push target '$remote_name' ($remote_url) is not in the enterprise allowlist. Allowed domains: $ALLOWED_DOMAINS"
      fi
    fi
    # If we can't resolve the URL (no git repo context), allow — the push will fail anyway
  fi

  # 3d. Branch protection (skip in CI mode)
  if [[ "$CI_MODE" != "true" ]] && [[ -n "$branch_name" ]]; then
    # Handle refspec format (local:remote)
    target_branch="${branch_name#*:}"
    [[ -z "$target_branch" ]] && target_branch="$branch_name"

    if branch_protected "$target_branch"; then
      deny "Direct push to protected branch '$target_branch' is forbidden. Use a pull request instead. Protected branches: $PROTECTED_BRANCHES"
    fi
  fi
fi

# =============================================================================
# CHECK 4: git reset --hard — destructive
# =============================================================================
if echo "$norm" | grep -qE '(^|[;&|])[[:space:]]*git[[:space:]]([^;&|]*[[:space:]])?reset[[:space:]]+--hard'; then
  deny "git reset --hard is forbidden. Use 'git reset --soft' or 'git revert' for non-destructive alternatives."
fi

# =============================================================================
# CHECK 5: git clean -f/-fd — destructive (removes untracked files)
# =============================================================================
if echo "$norm" | grep -qE '(^|[;&|])[[:space:]]*git[[:space:]]([^;&|]*[[:space:]])?clean[[:space:]]+-[a-z]*f'; then
  deny "git clean -f is forbidden. It permanently removes untracked files. Use 'git clean -n' to preview first."
fi

# =============================================================================
# CHECK 6: git checkout/switch to detached HEAD with force — can lose work
# =============================================================================
if echo "$norm" | grep -qE '(^|[;&|])[[:space:]]*git[[:space:]]([^;&|]*[[:space:]])?(checkout|switch)[[:space:]].*--force'; then
  deny "Forced checkout/switch can discard uncommitted changes. Remove --force or commit your changes first."
fi

# =============================================================================
# All checks passed
# =============================================================================
exit 0
