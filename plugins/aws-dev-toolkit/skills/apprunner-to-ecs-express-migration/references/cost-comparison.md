# Cost Comparison: App Runner vs ECS Express Mode

App Runner bills per-request plus provisioned-memory; ECS Express Mode bills Fargate vCPU + memory per second whenever tasks are running, plus ALB hours and LCU charges.

**Note:** Cost estimates produced by this skill are approximations. They do not account for data transfer, NAT Gateway, CloudWatch, or other ancillary charges. Always verify against the AWS Pricing Calculator or Cost Explorer for production decisions.

---

## Rule of Thumb

- **Low-traffic services** (burst or <1 req/sec sustained): Fargate's always-on pricing usually costs **more** than App Runner. Review before committing.
- **Steady or high-traffic services**: Express Mode is typically cheaper at equivalent CPU/memory.
- **ALB sharing**: use `awspricing` to look up current ALB hourly and LCU rates. The fixed cost amortizes across up to 25 services. One tiny service on a dedicated ALB is expensive.

## Before Migrating

Advise the user to:

1. **Pull App Runner monthly cost** from Cost Explorer for the last 30 days.
2. **Look up current rates** via `awspricing` MCP tools — Fargate vCPU/memory rates and ALB hourly/LCU charges for the target region.
3. **Estimate Fargate cost**: `(vCPU × rate + GB × rate) × 730 hours × task count` plus ALB baseline divided by services sharing it.
4. **Compare** — if ECS Express would cost 2x+ more, consider keeping App Runner until forced migration (existing services continue to run).

## Key Pricing Differences

| Factor | App Runner | ECS Express Mode |
|---|---|---|
| Compute billing | Per-request + provisioned memory | Per-second (vCPU + memory) while tasks run |
| Load balancer | Included (internal, not accessible) | ALB hourly + LCU charges (visible, shared) |
| Scale-to-zero | Yes — no charge when idle | No — minimum 1 task always running |
| Auto scaling | Included | Included (Application Auto Scaling) |
| HTTPS/TLS | Included | Included (ACM certificate auto-provisioned) |

## When Migration May Cost More

- Services that idle most of the day (Fargate bills per-second even when idle)
- Single low-traffic service on a dedicated ALB (ALB fixed cost not amortized)
- Services with minimal CPU/memory needs (App Runner's per-request model is cheaper at low utilization)

In these cases, advise the user to consider keeping the service on App Runner until forced migration, or consolidating multiple services onto a shared ALB to amortize the fixed cost.
