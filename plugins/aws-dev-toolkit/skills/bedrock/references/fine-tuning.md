# Bedrock Model Customization (Fine-Tuning) Reference

Field-tested guidance for customizing foundation models on Amazon Bedrock — when it's worth it, which method to pick, and the operational gotchas the docs bury. Distilled from a real end-to-end Nova Micro distillation run.

## Table of Contents

- [Decide whether to fine-tune at all](#decide-whether-to-fine-tune-at-all)
- [Pick the customization method](#pick-the-customization-method)
- [What is a good fine-tuning target](#what-is-a-good-fine-tuning-target)
- [Distillation: the practical pattern](#distillation-the-practical-pattern)
- [Operational gotchas](#operational-gotchas)
- [Cost model](#cost-model)
- [Evaluation: fidelity vs accuracy](#evaluation-fidelity-vs-accuracy)
- [End-to-end flow (API, no SDK required)](#end-to-end-flow-api-no-sdk-required)
- [Anti-patterns](#anti-patterns)

## Decide whether to fine-tune at all

Fine-tuning is rarely the first move. Before customizing a model, rule out the cheaper, faster, more maintainable alternatives — they solve most problems FT is reached for:

1. **Better prompting** — few-shot examples, clearer instructions, structured output via tool use. Free, instant to iterate.
2. **RAG / Knowledge Bases** — inject *knowledge* the model lacks. Updatable without retraining; survives model upgrades. If the problem is "the model doesn't know X," this is almost always the answer, not FT.
3. **Prompt caching** — if cost is the driver, a cached stable system prompt cuts input cost ~90% with zero training.
4. **A smaller off-the-shelf model + good prompting** — often beats a fine-tune of a larger one.

Fine-tune when the task is **narrow, repeated at volume, has a stable target behavior, and prompting has plateaued** — e.g. a high-QPS classifier, fixed-format extraction, or matching a specific output style. The economics only work when the per-call savings of a smaller customized model amortize the one-time training + ongoing storage cost (see [Cost model](#cost-model)).

**Decisive rule of thumb:** FT changes *behavior/style*, not *knowledge*. If you're tempted to fine-tune to "teach the model facts," use RAG instead — facts go stale in weights and force a retrain at every update.

## Pick the customization method

Bedrock's `CreateModelCustomizationJob` takes a `customizationType`. Choose by what data you have, not by what sounds most powerful:

| Method | Use when you have… | Notes |
|---|---|---|
| **SFT** (Supervised Fine-Tuning) | Labeled input→output pairs with an exact-match target | The default for classification, extraction, fixed-format tasks. Simplest method that does the job. |
| **Distillation** (`DISTILLATION`) | A teacher model but no labels; you don't want to run/host the teacher | You supply prompts; Bedrock calls the teacher to generate completions, then trains the student. Hides the teacher-output step. |
| **DPO** (Direct Preference Optimization) | Preference pairs (chosen vs rejected) | For aligning toward subjective preferences (helpfulness, tone). Not for tasks with one right answer. Model-availability is limited — verify. |
| **RFT** (Reinforcement Fine-Tuning) | A reward signal (Lambda grader or model-as-judge), fuzzy "good" | For multi-step or quality-rubric tasks. Needs a reward function, not labels. Model support is narrow (verify which models). |
| **CPT** (Continued Pre-Training) | A raw unlabeled domain corpus | Injects broad domain knowledge via next-token prediction. Not for input→output tasks. |

**Key insight:** for a closed-label classifier where you can produce exact target labels (e.g. by running a strong "teacher" model over your inputs), **SFT on those labels IS knowledge distillation** — you don't need the managed `DISTILLATION` type. Doing the labeling yourself keeps the teacher's outputs inspectable (you can build a teacher-vs-ground-truth confusion matrix), which the managed path hides. Reach for managed `DISTILLATION` only when you'd rather not run the teacher or manage the label pipeline.

**Verify method × model support before committing** — not every method is available on every model tier, and it changes. Use the `awsknowledge` MCP tools against the current customization docs.

## What is a good fine-tuning target

In a multi-component system (e.g. a RAG agent with a classifier, a retriever, and a generator), fine-tune the **narrowest component with the most stable, verifiable output** — not the flashiest one.

**Good targets:** closed-label classifiers/routers, fixed-schema extractors, single-call structured-output steps. These have gold sets (or can cheaply generate them), objective correctness, and no prompt brittleness.

**Bad targets:** the multi-turn, tool-using, RAG-driven *generator* at the heart of an agent. Reasons this consistently fails as an FT target:
- Quality comes from **retrieval + validation**, not model weights — FT can't bake in your live database or current data.
- It **freezes prompt iteration**: if your generator prompt took many attempts to land and behaves non-monotonically (common), FT bakes one version into weights and every future prompt improvement becomes a retrain.
- It often relies on **routing to a stronger model** for hard inputs — a single fine-tune flattens that quality curve exactly where you need it most.
- "Good output" has **no cheap gold set** — labeling thousands of high-quality reference generations is weeks of work, producing data your retrieval pipeline already surfaces at inference time.

**Tested example:** pointing an agent's deck-builder at a cheaper base model (instead of fine-tuning) failed the most basic objective gate — it produced structurally invalid outputs (over-limit item counts, hallucinated entities a validator caught) where the stronger model was flawless. The lesson generalizes: test whether a cheaper *base* model clears your objective gate before spending anything on fine-tuning it. If the base can't follow the rules, an FT would have to teach the rules from scratch — the hardest, most data-hungry kind of customization.

## Distillation: the practical pattern

The reliable recipe for "make a cheap model do a narrow task as well as an expensive one":

1. **Generate a diverse input corpus.** Synthesize realistic inputs (a strong model at high temperature works well), balanced across the categories/shapes you care about. A few thousand rows is plenty for a narrow task; AWS's documented SFT minimum is ~100, realistic is 1k+.
2. **Label with the teacher.** Run the strong model over the corpus to produce target outputs. These labels — not your generation intent — are what the student learns. Distillation reproduces the *teacher*, so its labels are ground truth for training.
3. **Hold out a slice** (e.g. 10%) deterministically for evaluation.
4. **SFT the student** on the teacher's labels.
5. **Deploy on-demand** and measure fidelity + latency + cost against the teacher.

**Choose the teacher deliberately.** The student inherits the teacher's ceiling, including its mistakes. If a stronger model is meaningfully more accurate at the task than your chosen teacher, distilling from the weaker teacher caps the student below what's achievable. Benchmark candidate teachers against an independent gold standard first.

## Operational gotchas

These cost real debugging time and aren't surfaced prominently in the docs. Several are corroborated by internal support threads and the Bedrock customization FAQ — verify against current docs, since the customization surface moves fast.

- **Region availability is narrow and model-specific.** Native Bedrock fine-tuning runs in only a couple of regions (currently `us-east-1` / `us-west-2`); some families are even narrower. On-demand deployment of a *natively* customized model is likewise US-only at the time of writing (not available in EU). If your application runs elsewhere, you train + deploy in the supported region and either call cross-region (latency + egress cost) or stand the deployment up there. Always confirm the region matrix for your exact model × method before designing around it.
- **The console base-model list can show every model as "deprecated."** A recurring support pattern: in the Bedrock console *Custom models* flow, every selectable base model (e.g. Llama 3.2 3B in `us-west-2`) throws a "deprecated model" error, blocking native fine-tuning entirely. The field workaround is to fine-tune externally (SageMaker JumpStart) and bring the result in via **Custom Model Import (CMI)** — don't promise a customer the console path works without checking it for their exact model × region first.
- **CMI is a different product from native fine-tuning — different inputs, billing, and limits.** Custom Model Import takes weights in **Hugging Face format** from S3 (the model need not have been trained in SageMaker), bills per *model unit* in ~5-minute increments on **on-demand** inference (no Provisioned Throughput required), and supports a fixed set of architectures. Natively-fine-tuned Bedrock models are a separate path with their own deployment story. Confirm which one the customer is on before quoting cost or region behavior — the two are routinely conflated.
- **Don't default a new build to Provisioned Throughput.** For a customized model, **on-demand custom deployment** (pay-per-token, no pre-provisioned capacity) is the documented default for variable workloads — PT is the commit-to-capacity option, and not every model is offered on it (verify the [PT-supported models](https://docs.aws.amazon.com/bedrock/latest/userguide/prov-thru-supported.html) list for your target). Internal field guidance goes further — treat PT as a rare, justified exception rather than a default (block it at the org level and grant access by exception) — but the durable, documented point is: reach for on-demand custom deployment first, PT only when you have steady, high-volume traffic that justifies a capacity commitment, and SageMaker inference when you need GPU control or volumes Bedrock can't serve.
- **PT vs. Reserved Tier is a per-model availability question, not a preference ranking.** They are *not* interchangeable options for the same model. **PT = reserving capacity on the traditional Bedrock infrastructure; Reserved Tier = reserving capacity on the Mantle infrastructure.** A given model is on one, the other, both, or neither (no reservation possible) — so the decision is "what's available for *this* model?", not "which is better?" In practice you rarely advise PT-vs-RT in the abstract; you look at the target model's matrix. Reserved Tier generally has the better UX and capabilities where it exists. As an **unofficial directional** statement, the long-term plan is to move everything to Mantle (and thus to Reserved Tier) — but there is **no official deprecation messaging and no ETA** for PT, so don't tell a customer PT is "going away." (PT-v2 was once planned as a PT successor; those plans were scrapped in favor of Reserved Tier.)
- **For custom models, point to Bring Your Own Model on Mantle for the roadmap.** Customers interested in custom-model deployments benefit from a **service-team roadmap session on the new Bring Your Own Model (BYOM) capability launching on Mantle** — the successor to today's Custom Model Import on Bedrock. Roadmap details (timing, supported architectures) aren't shareable in the field; route the customer to the service team rather than quoting specifics.
- **PT / deployment creation can fail with an opaque "internal error."** A real case: PT creation for an SFT'd Nova model returned only *"Encountered an internal error… Please try again later"*; the true cause was a **missing training artifact** (an expected encoder checkpoint never got written by the SFT job). The remedy that worked was to **delete the custom model and recreate it**, then redeploy. If deployment fails inexplicably, suspect an incomplete training output before retrying blindly.
- **Intermittent 503s on a custom deployment without any throttling.** Production custom-model deployments (seen on a fine-tuned Claude Haiku on PT) can emit `503 ServiceUnavailable` *concurrently* with successful invocations, with no throttling metric firing. Build retries with backoff and don't assume a 503 means you hit a quota — it can be transient backend unavailability.
- **On-demand throughput per custom-model deployment is capped (~4M TPM) and not freely adjustable.** The limit exists per deployment and raising it requires backend capacity planning, not a self-serve quota bump. For high volume (the documented case needed 20M TPM) the options are multiple deployments, reserved capacity, or SageMaker inference — size this *before* committing to SFT so you don't train a model you can't serve at scale.
- **Loss metrics may return as `-1` from `GetModelCustomizationJob`.** For some model families the scalar `trainingLoss`/`validationLoss` API fields are not populated (they return `-1`). The real per-step loss curves are written to the **S3 output prefix** instead (e.g. `output/<job>/training_artifacts/step_wise_training_metrics.csv` and a `validation_artifacts/.../validation_metrics.csv`). Monitoring that keys on the API field will silently see `-1` — read the CSVs.
- **A trained custom model is NOT directly invocable.** Training yields a `custom-model` resource. To call it you must create a separate **custom model deployment** (`CreateCustomModelDeployment`) and pass the resulting *deployment* ARN as `modelId` to Converse/InvokeModel. Two-step: train → deploy.
- **Custom model storage bills; the deployment is the expensive part.** A *registered custom model* has minimal/zero standing cost — keep it around. A *live deployment* bills (storage + inference). To stop billing while keeping the ability to spin back up: **delete the deployment, keep the model.** Deleting the model itself forces a full retrain to recover it.
- **You never get the model artifacts.** Bedrock fine-tunes in a service-owned *escrow* account to protect the provider's IP — you cannot log into the training container, customize the training script, export the weights, or move the custom model to another account (cross-account sharing is "being worked on"). You *can* use it across regions and encrypt it with your own KMS key, but the model is reachable only via its Bedrock ARN. Set this expectation with customers who assume FT gives them a portable artifact.
- **Dataset format and record limits are strict, and bad records may vanish silently.** Per-sample token caps (e.g. ~8K tokens/sample) and record-count quotas (on the order of thousands of training / hundreds of validation records, model-dependent) are enforced. Invalid records can be **skipped with only a warning** rather than failing the job — so a "successful" run may have trained on less data than you handed it. Validate your JSONL against the model's documented schema and reconcile the accepted record count.
- **Fine-tuning is stochastic.** Identical corpus + hyperparameters across two runs can differ by a point or more on eval (random init, data shuffle). Don't over-read a single run — the meaningful number is the band across runs, not one point.
- **Watch for early overfitting on small corpora.** Validation loss that rises across epochs while training loss falls means you're past the sweet spot. For narrow tasks on a few thousand rows, 1–2 epochs often matches or beats the default — check the per-epoch validation CSV.

## Cost model

Three buckets, all of which the per-call savings must amortize:

1. **Training** — typically priced per token of training data × epochs. For a few-thousand-row narrow task this is small (tens of dollars, not hundreds).
2. **Storage** — a flat monthly charge per stored custom model (small, but ongoing — and it's why you delete deployments you're not using).
3. **Inference** — the payoff. A customized small model can be dramatically cheaper per call than the large model it replaces.

**Two traps when computing "is it cheaper":**
- **Prompt-cache asymmetry.** If your current (large-model) path benefits from prompt caching (~90% input discount on a stable system prompt), its *effective* cost is far below sticker. A customized small model may not get the same caching behavior on every platform — compare cache-adjusted effective cost, not headline per-token rates.
- **Volume threshold.** The per-call savings only beats the storage floor above some monthly call volume. Below that, the off-the-shelf model is cheaper all-in. Distillation pays off when the call is (a) high-QPS, (b) narrow/closed-output, and (c) latency-sensitive — not on cost alone.

## Evaluation: fidelity vs accuracy

Two different questions — measure the one you mean:

- **Fidelity** — does the student reproduce the *teacher's* outputs? Score against teacher labels. This tells you the distillation worked, but is capped by the teacher's own quality.
- **Accuracy** — does the model produce the *correct* answer? Score against an independent gold standard (e.g. human-curated or generation-intent labels). This tells you whether the task is actually being solved.

A high fidelity number is only as meaningful as the teacher is good. Always sanity-check the teacher's own accuracy against an independent reference — if the teacher is mediocre, faithfully copying it isn't worth much.

**Where the misses cluster is signal, not noise.** In a well-behaved distillation, the student diverges from the teacher precisely on the genuinely ambiguous inputs (categories that legitimately overlap). That means the ceiling isn't fixable with more data — it's the *task definition's* intrinsic ambiguity. To push past it, disambiguate the categories/instructions, not the training-set size.

## End-to-end flow (API, no SDK required)

A single managed SFT job is a plain control-plane API call — usable from any AWS SDK or the CLI. You do **not** need a vendor-specific fine-tuning SDK for a one-off managed job; reach for such SDKs only when you want their recipe-management/experiment-tracking conveniences or are targeting a non-Bedrock training backend (which may bill GPU-hours rather than per-token).

Infrastructure (provision via IaC — see the `iac-scaffold` skill):
- An S3 bucket in the customization region for training data + model output.
- A service role Bedrock assumes for the job (reads training data, writes output), trust-scoped to the bedrock service principal with a `SourceAccount` (and ideally `SourceArn`) condition.
- Operator permissions to create/inspect jobs, deploy + invoke the custom model, and `iam:PassRole` (scoped to the service role with an `iam:PassedToService` condition).

Diagnostic CLI:
```bash
# Submit (training/validation data already in S3, schema per the model's docs)
aws bedrock create-model-customization-job \
  --job-name my-ft-job --custom-model-name my-model \
  --role-arn <service-role-arn> \
  --base-model-identifier <base-model-id> \
  --customization-type FINE_TUNING \
  --training-data-config '{"s3Uri":"s3://bucket/training/train.jsonl"}' \
  --validation-data-config '{"validators":[{"s3Uri":"s3://bucket/training/holdout.jsonl"}]}' \
  --output-data-config '{"s3Uri":"s3://bucket/output/"}' \
  --hyper-parameters '{"epochCount":"2","learningRate":"0.00001"}' \
  --region <customization-region>

# Poll (note: loss may be -1 here; real metrics are in the S3 output)
aws bedrock get-model-customization-job --job-identifier my-ft-job --region <region>

# Deploy for on-demand inference (returns the deployment ARN to invoke)
aws bedrock create-custom-model-deployment \
  --model-deployment-name my-model --model-arn <custom-model-arn> --region <region>

# Stop billing but keep the model: delete the DEPLOYMENT, not the model
aws bedrock delete-custom-model-deployment \
  --custom-model-deployment-identifier <deployment-arn> --region <region>
```

## Anti-patterns

- **Fine-tuning to inject knowledge** — use RAG; knowledge in weights goes stale and forces retrains.
- **Fine-tuning the agent's multi-turn generator** — quality is in retrieval + validation, not weights; FT freezes prompt iteration and kills model routing.
- **Distilling from a teacher you never benchmarked** — the student inherits the teacher's ceiling; verify the teacher is actually good first.
- **Comparing sticker token prices** — account for the large model's prompt-cache discount and the volume threshold before declaring the fine-tune "cheaper."
- **Deleting the custom model to "clean up"** — delete the *deployment* to stop billing; the model has minimal standing cost and deleting it forces a full retrain.
- **Reading the API loss field and concluding training failed** — `-1` is expected for some models; the real loss curves are in S3.
- **Trusting one training run** — FT is stochastic; evaluate across runs.
- **Defaulting to a heavy fine-tuning SDK for a single managed job** — it's one control-plane API call; the SDK is optional convenience.
- **Conflating native fine-tuning with Custom Model Import** — different inputs (HF weights vs JSONL), regions, billing (model-unit vs token), and limits; quote behavior for the one the customer is actually on.
- **Designing a new build around Provisioned Throughput** — PT is capacity-constrained and absent on the newest models; prefer on-demand custom deployment, Reserved Tier (where the model is offered on Mantle), or SageMaker. Don't claim PT is deprecated — there's no official deprecation messaging or ETA, only an unofficial directional move to Mantle.
- **Framing PT and Reserved Tier as interchangeable, or calling one strictly "better"** — they reserve capacity on different infrastructures (PT = Bedrock, RT = Mantle) and usually aren't both available for the same model; decide by the target model's availability matrix, not a blanket preference.
- **Committing to SFT before checking serving limits** — the ~4M TPM per-deployment on-demand cap isn't self-serve adjustable; size throughput before you train.
- **Promising the console fine-tuning path without testing it** — base models can surface as "deprecated" and block the flow; verify model × region, fall back to SageMaker + CMI.
- **Assuming a "successful" job trained on all your data** — invalid records may be skipped with warnings; reconcile the accepted record count.
- **Promising customers a portable/exportable fine-tuned model** — weights live in a service-owned escrow account, reachable only via the Bedrock ARN; no export, no cross-account move.
