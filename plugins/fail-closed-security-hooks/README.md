# fail-closed-security-hooks

Guardrails on **what the agent does**, not just what it can build. Five hooks wired through a fail-closed telemetry shim — the layer a startup needs the moment it touches regulated data (fintech, health).

```bash
/plugin install fail-closed-security-hooks@aws-samples
```

Or load locally during development:

```bash
claude --plugin-dir ./plugins/fail-closed-security-hooks
```

## What it does

| Hook | Events | What it enforces |
|---|---|---|
| **pii-guard** | UserPromptSubmit, PreToolUse | Scans prompts and tool inputs for secrets (AWS keys, private keys, JWTs, DB connection strings, credit cards) and **national identifiers across the US, UK, Japan, South Korea, Singapore, EU (IBAN), and Australia**, then **blocks before the content reaches the model**. Every pattern is individually disable-able. |
| **git-guard** | PreToolUse (Bash) | Remote-URL allowlist, force-push prevention, protected-branch enforcement, and destructive-op blocking (`reset --hard`, `clean -f`, forced checkout). |
| **audit-logger** | UserPromptSubmit, PostToolUse | **Tamper-evident HMAC-SHA256 hash-chained** JSONL audit log. Any post-hoc edit, deletion, reorder, or insertion breaks the chain forward and is caught by `scripts/chain-verify.sh`. Optional dual-write to CloudWatch + SIEM. |
| **token-budget-guard** | PreToolUse, PostToolUse | Per-session circuit breaker. Blocks further tool calls once a token or call budget is exceeded — a backstop against runaway agent loops. |
| **hook-wrapper** | wraps all of the above | Telemetry shim. Emits per-hook timing/exit JSON and **converts silent hook crashes/timeouts into explicit `exit 2` denials** (fail-closed), so a broken control fails *safe* instead of failing *open*. |

## Quick start

```bash
# 1. Provide an HMAC key for the tamper-evident audit chain
export AUDIT_HMAC_KEY="$(openssl rand -hex 32)"

# 2. (optional) git-guard policy
export GIT_GUARD_ALLOWED_DOMAINS="github.com,gitlab.com"
export GIT_GUARD_PROTECTED_BRANCHES="main,master,release/*"

# 3. Verify the audit chain any time
bash scripts/chain-verify.sh ~/.claude/claude-code-security/audit.jsonl   # exit 0 = intact, 1 = tampered
```

Default state/log paths are user-writable (`~/.claude/claude-code-security/`) for evaluation. For **un-removable, fleet-wide enforcement**, deploy the same hooks via `managed-settings.json` with root-owned paths — the hook logic is identical; only the trust boundary and defaults change. See the upstream repo for Terraform IaC, managed-settings, a CloudWatch dashboard, and a STRIDE threat model.

## Configuration

| Env var | Hook | Default |
|---|---|---|
| `AUDIT_HMAC_KEY` | audit-logger | dev key auto-generated under state dir |
| `CLAUDE_AUDIT_CLOUDWATCH_GROUP` | audit-logger | (off) |
| `CLAUDE_AUDIT_SIEM_REQUIRED` | audit-logger | (off) |
| `GIT_GUARD_ALLOWED_DOMAINS` | git-guard | `github.com,gitlab.com,bitbucket.org` |
| `GIT_GUARD_PROTECTED_BRANCHES` | git-guard | `main,master,release/*,production` |
| `CLAUDE_TOKEN_BUDGET` / `CLAUDE_CALL_BUDGET` | token-budget-guard | `1000000` / `500` |
| `CLAUDE_HOOK_TIMEOUT_MS` | hook-wrapper | `5000` |

## Testing

Upstream ships a 76-assertion test suite (`claude plugin validate --strict` clean): https://github.com/timwukp/claude-code-on-aws-bedrock-best-practices

## License

MIT-0 (contributed copy). Upstream source is Apache-2.0.
