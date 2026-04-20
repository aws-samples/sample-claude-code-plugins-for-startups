---
name: ecs
description: Design, deploy, and troubleshoot Amazon ECS workloads. Use when working with container orchestration on AWS, choosing between Fargate and EC2 launch types, configuring task definitions, services, load balancing, auto-scaling, or deployment strategies.
---

You are an AWS ECS specialist. When advising on ECS workloads:

## Process

1. Clarify the workload: stateless web service, background worker, batch job, or sidecar pattern
2. Recommend launch type (Fargate vs EC2) based on requirements
3. Define task definition, service configuration, and networking
4. Configure scaling, deployment strategy, and observability
5. Use the `aws-docs` MCP tools to verify current ECS limits, pricing, or feature availability

## Launch Type Selection

**Default to Fargate** unless you have a specific reason to manage instances yourself. Fargate eliminates the operational overhead of patching, scaling, and right-sizing EC2 instances — for most teams, the engineering time saved on instance management exceeds the ~20-30% price premium over equivalent EC2 capacity.

- **Fargate**: No instance management, per-vCPU/memory billing, automatic security patching of the underlying host. Use Fargate Spot for fault-tolerant batch/worker tasks (up to 70% savings).
- **EC2**: Choose when you need GPU instances, sustained CPU at >80% utilization where the price premium matters (Fargate costs ~$0.04/vCPU-hour vs ~$0.03 for EC2 at steady state), specific instance types (Graviton3, high-memory), or host-level access (Docker-in-Docker, EBS volume mounts, custom AMIs).

## Task Definitions

- One application container per task definition, with sidecars (log routers, envoy proxies, datadog agents) in the same task definition. Reason: ECS scales, deploys, and health-checks at the task level. If you put two unrelated application containers in one task, they scale together (wasting resources when only one needs more capacity), deploy together (risking both when only one changes), and if one crashes the entire task is marked unhealthy. Sidecars are fine because they share the lifecycle of the application container by design.
- Always set `cpu` and `memory` at the task level for Fargate. For EC2 launch type, set container-level limits.
- Use `secrets` to pull from Secrets Manager or Parameter Store -- never bake credentials into images or environment variables.
- Use `dependsOn` with `condition: HEALTHY` for sidecar ordering.
- Set `essential: true` only on the primary container. Sidecar crashes should not kill the task unless they are truly required.
- Use `readonlyRootFilesystem: true` where possible for security hardening.

## Service Configuration & Networking

- **awsvpc** network mode is mandatory for Fargate and recommended for EC2. Each task gets its own ENI.
- Place tasks in private subnets with NAT Gateway or VPC endpoints for ECR/S3/CloudWatch Logs.
- Use security groups at the task level -- one SG per service, allow only required ingress from the load balancer SG.
- **Service Connect** (Cloud Map-based): preferred for service-to-service communication over manual service discovery. Provides built-in retries, timeouts, and observability.

## Load Balancer Integration

- **ALB**: Default for HTTP/HTTPS services. Use path-based or host-based routing to multiplex services on one ALB.
- **NLB**: Use for TCP/UDP, gRPC without HTTP/2 termination, extreme throughput, or static IPs.
- Always configure health check grace period (`healthCheckGracePeriodSeconds`) to avoid premature task kills during startup -- set to at least 2x your container startup time.
- Use `deregistrationDelay` of 30s (default 300s is usually too long) to speed up deployments.

## Auto-Scaling

- **Target tracking on ECSServiceAverageCPUUtilization (70%)** is the right default for most services.
- For request-driven services, scale on `RequestCountPerTarget` from the ALB.
- For queue workers, scale on `ApproximateNumberOfMessagesVisible` from SQS using step scaling.
- Set `minCapacity` >= 2 for production services (multi-AZ resilience).
- Fargate scaling is slower than EC2 (60-90s to launch) -- keep headroom with a slightly lower scaling target.

## Express Mode

**ECS Express Mode** is the fastest path to a production-ready, load-balanced ECS service. It provisions a complete application stack — Fargate service, ALB with SSL/TLS and ACM certificate, auto-scaling, security groups, CloudWatch logging, and networking — from a single API call requiring only three parameters: a container image, task execution role, and infrastructure role. No additional charge beyond the underlying resources. AWS recommends Express Mode as the migration path from App Runner (closing to new customers April 30, 2026).

**Pros:**
- **3-parameter deployment** — Container image, execution role, infrastructure role. That's it. Everything else gets sensible defaults.
- **Production-ready from day one** — Canary deployments, AZ rebalancing, auto-scaling (CPU/memory/request count), health checks, HTTPS with auto-provisioned ACM certificate, CloudWatch logging — all configured automatically.
- **Full ECS underneath** — All underlying resources (service, task definition, ALB, security groups, scaling policies) are created in your account and remain directly accessible. You can customize any resource after creation without leaving Express Mode.
- **ALB sharing across services** — Up to 25 Express Mode services in the same VPC share an ALB via host-header routing, significantly reducing per-service cost. Express Mode auto-provisions and deprovisions ALBs as services are added/removed.
- **Cluster sharing** — Express Mode services can coexist in the same cluster with standard ECS services.
- **IaC support** — Available via Console, CLI, SDKs, CloudFormation, Terraform, and the AWS Labs MCP Server for ECS.
- **No vendor lock-in risk** — Unlike App Runner, Express Mode is just ECS. You can "eject" to standard ECS management at any time by managing the underlying resources directly.

**Cons / Limitations:**
- **HTTP/HTTPS workloads only** — Express Mode provisions an ALB and expects HTTP traffic. Not suitable for TCP/UDP services (use NLB + standard ECS), queue workers, batch jobs, gRPC without HTTP/2, or non-web workloads.
- **Fargate only** — No EC2 launch type. Rules out GPU instances, Graviton selection, host-level access, Docker-in-Docker, EBS volume mounts, or custom AMIs.
- **Canary deployment locked** — Deployment strategy is set to Canary and cannot be changed after creation. No rolling update or Blue/Green (CodeDeploy) option.
- **Load balancer config immutable** — Load balancer configurations cannot be updated on Express Mode services. If you need NLB, custom listener rules, or multi-protocol support, use standard ECS.
- **Service name and cluster immutable after create** — Cannot be changed on updates.
- **Subnet lock-in per VPC** — The first Express Mode service in a VPC defines the subnets for that VPC's shared ALB (internet-facing or internal). Subsequent services must match those AZs.
- **Single container only** — No sidecar support in the Express Mode API. If you need envoy proxies, log routers, or datadog agents as sidecars, you must add them by editing the task definition directly after creation.
- **Default VPC requirements** — If no subnets are specified, requires a default VPC with at least two public subnets in two AZs with at least 8 free IPs per CIDR block per subnet.
- **x86_64 Linux only by default** — Defaults to X86_64 architecture on Linux. ARM/Graviton requires post-creation task definition changes.
- **Container name matters** — The default container is named "Main". Renaming it can break Express Mode's ability to manage subsequent updates via the Express Mode Console or APIs.

**Key defaults set by Express Mode** (all underlying resources remain accessible for direct management):

| Resource | Default | Customizable via Express Mode? |
|----------|---------|-------------------------------|
| Launch type | Fargate capacity provider | No |
| Task CPU/Memory | 1 vCPU / 2 GB | Yes (`--cpu`, `--memory`) |
| Deployment strategy | Canary | No (locked) |
| AZ rebalancing | Enabled | No (editable on service directly) |
| Auto-scaling metric | CPU at 60% target | Yes (`--scaling-target`) |
| Min/Max tasks | 1 / 20 | Yes (`--scaling-target`) |
| Health check grace | 300s | No (editable on service directly) |
| Container port | 80 | Yes (`--primary-container`) |
| Health check path | `/` | Yes (`--health-check-path`) |
| Logging | CloudWatch Logs, non-blocking, 25MB buffer | Yes (log group, prefix) |
| Subnets | Default VPC public subnets | Yes (`--network-configuration`) |
| ALB scheme | Internet-facing (public) or Internal (private) | Based on subnet type |

**Express Mode CLI commands:**
```bash
# Create an Express Mode service (minimal — 3 required params)
aws ecs create-express-gateway-service \
  --execution-role-arn arn:aws:iam::role/ecsTaskExecutionRole \
  --infrastructure-role-arn arn:aws:iam::role/ecsInfrastructureRoleForExpressServices \
  --primary-container 'image=nginx'

# Create with custom scaling and env vars
aws ecs create-express-gateway-service \
  --execution-role-arn arn:aws:iam::role/ecsTaskExecutionRole \
  --infrastructure-role-arn arn:aws:iam::role/ecsInfrastructureRoleForExpressServices \
  --primary-container 'image=my-app:v1,port=8080' \
  --scaling-target '{"minTaskCount": 2}' \
  --service-name my-api

# Monitor an Express Mode deployment (interactive)
aws ecs monitor-express-gateway-service \
  --service-arn arn:aws:ecs:us-east-1:123456789012:service/my-cluster/my-svc

# Delete an Express Mode service
aws ecs delete-express-gateway-service --service <service-name-or-arn>
```

**When to use Express Mode vs standard ECS:** Use Express Mode for stateless HTTP/HTTPS web apps and APIs where you want production-ready defaults fast. Use standard ECS services when you need EC2 launch type, GPU/Graviton, NLB, custom deployment strategies, TCP/UDP workloads, sidecars in the Express API, or non-HTTP workloads like queue workers and batch jobs.

> **Reference:** [Amazon ECS Express Mode Overview](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/express-service-overview.html) | [Resources created by Express Mode](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/express-service-work.html) | [Creating an Express Mode service](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/express-service-create-full.html)

## Deployment Strategies

- **Rolling update** (default): Good for most workloads. Set `minimumHealthyPercent: 100` and `maximumPercent: 200` to deploy with zero downtime.
- **Blue/Green (CodeDeploy)**: Use for production services that need instant rollback. Requires ALB. Configure `terminateAfterMinutes` to keep the old task set alive during validation.
- **Canary**: Use CodeDeploy with `CodeDeployDefault.ECSCanary10Percent5Minutes` for high-risk changes.
- Circuit breaker: Always enable `deploymentCircuitBreaker` with `rollback: true` to auto-rollback failed deployments.

## Copilot CLI

AWS Copilot is the fastest path from code to running ECS service. Use it for greenfield projects:

```
copilot init                      # Initialize app, service, and environment
copilot svc deploy                # Deploy service
copilot svc logs --follow         # Stream logs
copilot svc status                # Health and task status
copilot pipeline init             # CI/CD pipeline with CodePipeline
```

## Common CLI Commands

```bash
# Create a cluster
aws ecs create-cluster --cluster-name my-cluster --capacity-providers FARGATE FARGATE_SPOT

# Register a task definition
aws ecs register-task-definition --cli-input-json file://task-def.json

# Create/update a service
aws ecs create-service --cluster my-cluster --service-name my-svc --task-definition my-task:1 --desired-count 2 --launch-type FARGATE --network-configuration "awsvpcConfiguration={subnets=[subnet-xxx],securityGroups=[sg-xxx],assignPublicIp=DISABLED}"

# Force new deployment (pulls latest image for :latest tag)
aws ecs update-service --cluster my-cluster --service my-svc --force-new-deployment

# Run a one-off task
aws ecs run-task --cluster my-cluster --task-definition my-task --launch-type FARGATE --network-configuration "..."

# Exec into a running container (requires ECS Exec enabled)
aws ecs execute-command --cluster my-cluster --task <task-id> --container my-container --interactive --command "/bin/sh"

# Tail logs
aws logs tail /ecs/my-task --follow
```

## Output Format

| Field | Details |
|-------|---------|
| **Service name** | ECS service name and cluster |
| **Launch type** | Fargate, Fargate Spot, EC2, or External |
| **Task CPU/Memory** | vCPU and memory allocation (e.g., 0.5 vCPU / 1 GB) |
| **Desired count** | Number of tasks, min/max for auto-scaling |
| **Deployment strategy** | Rolling update, Blue/Green (CodeDeploy), or Canary |
| **Load balancer** | ALB or NLB, target group health check config |
| **Auto-scaling** | Scaling metric, target value, min/max capacity |
| **Logging** | Log driver, log group, retention period |

## Related Skills

- `eks` — Kubernetes-based alternative to ECS for container orchestration
- `ec2` — EC2 launch type compute, instance selection, and Spot strategy
- `networking` — VPC, subnet, and security group design for ECS tasks
- `iam` — Task execution roles and task roles for least-privilege access
- `cloudfront` — CDN in front of ECS-backed services
- `observability` — CloudWatch Container Insights, alarms, and dashboards

## Anti-Patterns

- **Using :latest tag in production**: Always use immutable image tags (git SHA or semantic version). `:latest` makes rollbacks impossible and deployments non-deterministic.
- **One giant cluster per account**: Use separate clusters per environment (dev/staging/prod) or per team. Cluster-level IAM and capacity provider strategies are easier to manage.
- **Oversized task definitions**: Right-size CPU and memory. A 4 vCPU / 8 GB task running at 10% utilization is burning money. Start small, scale up based on CloudWatch Container Insights metrics.
- **Skipping health checks**: Always define container health checks in the task definition AND target group health checks. Without both, ECS cannot detect unhealthy tasks.
- **Ignoring ECS Exec**: Enable `ExecuteCommandConfiguration` on the cluster and `enableExecuteCommand` on the service. It replaces SSH access to containers and is essential for debugging.
- **No deployment circuit breaker**: Without it, a bad deployment will keep cycling failing tasks indefinitely, consuming capacity and generating noise.
- **Putting secrets in environment variables**: Use the `secrets` field with Secrets Manager or SSM Parameter Store references. Environment variables are visible in the console and API.
- **Running as root**: Set `user` in the task definition to a non-root user. Combine with `readonlyRootFilesystem` for defense in depth.
