# DeepSeek V4 Flash EXL3 on a single Dell Pro Max with GB10 - the 384,000-token single-seat deep workstation

> The opposite of the "multi-seat concurrent" setup: EXL3 3.0 bpw weights (an expert-pruned DeepSeek V4 Flash 0731 build) served by a community vLLM-based single-node launcher, one machine, one seat, 384,000-token context. 46.3 tok/s is the figure for structured output only; prose decodes at roughly 19 to 22 tok/s (see Update (2026-10)).
> Built for one caller with exclusive access, doing deep work on ultra-long context: the **deep workstation**.

> **Status (2026-10): superseded.** On 2026-09-26 we replaced this text-only build on the node with a single-node build that keeps vision input (see Update (2026-10)). This recipe stays available as a rollback option on the node and is documented here as run. Correction: earlier versions of this README described the engine as a source-built exllamav3; the recipe actually run is the community launcher and image listed in the table.

## Update (2026-10)

All measurements below used **Dell Pro Max with GB10 (128 GB unified memory)**. Labels distinguish **M** (measured) and **O** (observed once); author-reported results and documented configuration are identified separately. The evaluation bank is private: only scores, not questions or per-question results, are published.

### Engine and recipe correction

The 2026-08-22 deployment used the community launcher [MiaAI-Lab/DeepSeek-v4-Flash-One-DGX-Spark](https://github.com/MiaAI-Lab/DeepSeek-v4-Flash-One-DGX-Spark). EXL3 is the weight format; serving uses vLLM. The earlier engine description and source-build deploy script did not reproduce the measured recipe.

The documented launcher configuration at commit `fdcd538fbf95fb15b2d6850db9613d22b2c889b8` is:

| Setting | Recorded recipe |
|---|---|
| Image | `ghcr.io/0xsero/deepseek-v4-flash-0731-spark-sparkinfer@sha256:2e077489a83a0360952828051fe7f7a32c1801e5ce8436d85f7267583d614ff4` (NVIDIA vLLM 26.02 base, SparkInfer kernels, EXL3 loader port) |
| Weights | `0xSero/deepseek-v4-flash-0731-spark`, revision `22f28d32b9b29b4352eaa380ff8c2c170b2847ab` |
| Context and concurrency | `MAX_MODEL_LEN=384000`, `MAX_NUM_SEQS=1`, `MAX_NUM_BATCHED_TOKENS=8224` |
| Memory and KV cache | `GPU_MEMORY_UTILIZATION=0.94`, `KV_RECORD=stock432` (`nvfp4_ds_mla`, 432-byte records) |
| Speculative decoding | DSpark, 5 draft tokens, 64-expert draft |
| Prefill and graphs | `--long-prefill-token-threshold 1024`; CUDA graph capture sizes 6, 12, 24 |
| Loading and restart | Tensor-parallel size 1, `instanttensor` weight loading, restart policy `on-failure:1` |

This is documented configuration, not proof of the complete original deployment state. The 2026-08-22 launcher was the earlier commit `76c51c7defffd01025c75daaf241ea323dda4734` with local edits whose diff was not preserved. Only the digest prefix `2e07` was recorded then. The full digest above was used in the 2026-09-25 re-run; whether it matches the original image remains open.

**O, 2026-08-22:** server defaults were thinking on, reasoning effort `max`. Disable thinking per request using `chat_template_kwargs: {"thinking": false}`; the key is `thinking`, not `enable_thinking`. The launcher binds all interfaces without authentication by default, as documented by its author. We observed that exposure and re-bound with `SERVING_HOST`; the rewritten script defaults to `127.0.0.1` and warns for a non-loopback bind address. With the older launcher revision used that day, `restart` did not regenerate the compose file: changing a tunable required `down` followed by a fresh start. That observation is limited to that older revision.

The rewritten `scripts/deploy.sh` reproduces the recorded launch recipe in code, but **has not itself been re-run end to end on hardware**. Only T1/T2 offline tests and syntax checks have been run for this update; T3/T4 were not run. Registry pull availability is also unverified. The script is not hardware-validated.

### Speed depends on content

All rows below use thinking off and a single stream. These are different probes, not a controlled cross-node benchmark.

| Date | Content and conditions | Decode speed | Evidence |
|---|---|---|---|
| 2026-08-22 | Structured-output prompt; exact prompt and run count not preserved | 46.3 tok/s | O, headline observation; author reports 44 to 47 tok/s for structured content |
| 2026-08-31 | Chinese long text; same node and recipe, one of three fixed prompts | 22.1 to 22.5 tok/s | M, run count not recorded |
| 2026-08-31 | Code generation; same node and recipe, one of three fixed prompts | 35.9 to 39.0 tok/s | M, run count not recorded |
| 2026-08-31 | Tool-call smoke test; same node and recipe, one of three fixed prompts | 28.1 to 31.2 tok/s | M, run count not recorded |
| 2026-09-25 | Code; second node, streamed 320-token completion | 37.6 tok/s | O, one probe |
| 2026-09-25 | English prose; second node, streamed 320-token completion | 20.0 tok/s | O, one probe |
| 2026-09-25 | Chinese prose; second node, streamed 320-token completion | 18.8 tok/s | O, one probe |

**O, 2026-09-25:** DSpark draft-token acceptance across those probes was 1,650 of 6,670 (24.7%), read from the serve log. Low prose acceptance accounts for prose being about half the structured-output speed, but the exact counting definition was not re-verified. The 46.3 tok/s structured result was not re-measured on the second node. For the already-published 2026-09-16/17 comparison using the same recipe and a 400-token prose completion, see [dell-pro-max-gb10-vllm-stack-ab](https://github.com/ryangu00/dell-pro-max-gb10-vllm-stack-ab).

### Second-node re-run and long needles

**O, 2026-09-25:** the same pinned weights revision and full image digest were redeployed on a second Dell Pro Max with GB10. This used the launcher's settings through a one-shot container command, offline wheels (`xgrammar==0.2.4`, `transformers==5.13.1`), and restart disabled. It did not use `start.sh`. The image had been removed in an earlier disk cleanup and was re-pulled: 11.1 GB plus 146 MB of wheels.

Readiness took about 18 minutes after the node was put on standby, including first-boot tensor-parallel-1 merge and draft-model build (about 15 minutes) and two failed first starts. Container-written artifacts owned by root were unreadable by the next step, and a patched serve script lacked the executable bit; `chown`/`chmod` resolved these issues. The resulting KV pool held 401,410 tokens. These timings describe that re-run, not the rewritten deployment script.

**O, 2026-09-25:** needle retrieval at depth 0.5, context limit 384,000 tokens, single seat, thinking off, `cached_tokens=0`, one trial per length:

| Prompt tokens | Time to first token | Prefill | Retrieval |
|---|---|---|---|
| 131,072 | 113 s | 1,159 tok/s | Exact |
| 245,760 | 233 s | 1,054 tok/s | Exact |
| 370,000 | 386 s | 958 tok/s | Exact |

**O, 2026-08-22:** an earlier single trial retrieved the needle exactly at 192,111 tokens. Separately, the launcher's author reported exact recall at 320,037 and 370,104 tokens on 2026-08-21; these are author-reported results.

### Accuracy at lower thinking effort

**M, two runs per arm:** private 11-category bank, with 8 own categories and 3 pack categories. Most categories have 30 questions, so one question is about 3.3 points. The measurement dates for these effort-arm runs were not recorded in the supplied facts; the same-arm status comparison below is dated 2026-09-26.

| Arm | Request settings | Own mean, including vision | Own mean, excluding vision | Pack mean |
|---|---|---|---|---|
| Low effort, mean over two runs | Reasoning effort `low`, temperature 0.5, `top_p=0.95`, `max_tokens=8000` | 74.0 | 84.6 | 74.7 |
| Vendor default, run 1 | Thinking `max`, temperature 1.0, `top_p=1.0`, `max_tokens=32768` | 78.5 | 89.7 | 76.7 |
| Vendor default, run 2 | Thinking `max`, temperature 1.0, `top_p=1.0`, `max_tokens=32768` | 79.2 | 90.5 | 74.4 |

The vision category scored 0 because this build is text-only. Text-category means were about 5 to 6 points lower in the low-effort arm; pack categories showed no visible difference. Chinese instruction following fell from 90.0 and 86.7 at max effort to a low-effort mean of 68.3 (10 points between its two runs). Knowledge QA scored 83.3 and 90.0 at max effort versus 81.7 at low effort, within noise.

The arms differ in sampling and token budget as well as effort, so this is not a single-variable comparison. Per-category differences smaller than about 10 points are within run-to-run noise on this bank. The accuracy cost of expert pruning relative to the unpruned model has not been measured.

### Memory and first boot

The launcher's author requires earlyoom not to be running and at least 114.3 GiB free memory before launch. The wrapper detects and refuses earlyoom; it never stops it. Its disk gate is at least 220 GiB free, covering about 107 GB of downloaded weights, about 99 GB for the merged checkpoint (one disk measurement), image layers and caches.

**O, 2026-08-22:** available memory at engine start was 114.86 GiB. With weights already on disk, the first boot reached healthy in about 12 minutes. Download plus lossless merge to a tensor-parallel-1 checkpoint took about 35 minutes, observed once that day.

**O, 2026-09-25, one boot:** at GPU memory utilization 0.94, available memory was 2.8 GiB after boot and reached a minimum of 2.06 GiB during boot validation. A watchdog checked every 5 minutes overnight, making 173 checks while the service ran; the lowest reading was 3.47 GiB and no out-of-memory event occurred. It was configured to stop the service after two consecutive readings below 1.5 GiB and never triggered. This leaves little memory headroom; the rewritten script does not install that watchdog.

### Status

**M, 2026-09-26, two runs per arm:** with low effort and the same private bank, the single-node vision build scored own 85.6 and pack 81.7, with vision 76.2. This text-only build scored own 74.0 (84.6 without vision) and pack 74.7. These scores are specific to this bank and arm.

On 2026-09-26, about 07:30 local, the node switched to the vision build. This recipe was retained as a rollback option and was not re-tested after the switch. For the single-node vision build, a separate write-up is planned.

### Open / not verified

- **Original image identity:** only `2e07` was recorded on 2026-08-22; the earlier launcher commit `76c51c7defffd01025c75daaf241ea323dda4734` had unpreserved local edits. The weights revision on disk matched `22f28d32b9b29b4352eaa380ff8c2c170b2847ab`, but the full original image digest remains unverified. The 2026-09-25 re-run used the full digest documented above.
- **Speed provenance:** the exact prompt and run count behind 46.3 tok/s, and run counts behind the 2026-08-31 ranges, are unknown. The structured result was not re-measured on the second node.
- **Client budget provenance:** where the 65,536-token generation budget was configured in 2026-08 is unknown. The launcher has no separate server-side generation cap; treat it as a client request setting.
- **Acceptance metric:** the counting definition for 1,650 of 6,670 was not re-verified.
- **Launcher equivalence:** the 2026-09-25 one-shot container command was not a `start.sh` run, used a later launcher commit than the original deployment, and the differences between the commits are not recorded.
- **Rewritten script:** T1/T2 offline checks passed for this update using simulated preflight inputs; shell syntax passed with `bash -n`. Shellcheck is not installed and was not run. T3 (end-to-end deployment, pinned running image, inference, repeat-run idempotency) and T4 (three 320-token streamed decodes and an exact 128K needle at depth 0.5) were not run because hardware was unavailable. The script remains unverified on hardware until those checks pass. T4 targets are code 35 to 40, English prose about 19 to 22, and Chinese prose about 18 to 23 tok/s, with thinking off.
- **Pruning:** accuracy loss relative to the unpruned model is unmeasured.
- **Effort comparison:** sampling and token budgets differ too; differences smaller than about 10 points per category are within observed run-to-run noise.
- **Registry availability:** whether the pinned image can still be pulled was not checked for this update.

## Hardware and versions

| Item | Spec / version |
|---|---|
| Machine | Dell Pro Max with GB10, one node, 128 GB unified memory (sm_121/aarch64) |
| Engine / launcher | Community single-node launcher [MiaAI-Lab/DeepSeek-v4-Flash-One-DGX-Spark](https://github.com/MiaAI-Lab/DeepSeek-v4-Flash-One-DGX-Spark), commit `fdcd538fbf95fb15b2d6850db9613d22b2c889b8`. It runs a pre-built Docker image, pinned by digest: `ghcr.io/0xsero/deepseek-v4-flash-0731-spark-sparkinfer@sha256:2e077489a83a0360952828051fe7f7a32c1801e5ce8436d85f7267583d614ff4` (NVIDIA vLLM 26.02 base, SparkInfer kernels, EXL3 loader port, tensor-parallel size 1, DSpark speculative decoding). There is no source build in this recipe. |
| Weights | `0xSero/deepseek-v4-flash-0731-spark` at revision `22f28d32b9b29b4352eaa380ff8c2c170b2847ab`: DeepSeek V4 Flash 0731, expert-pruned (REAP; 216 of 256 routed experts kept, per the model card), EXL3 3.0 bpw. About 107 GB to download; on first boot it is merged to a tensor-parallel-1 checkpoint (about 99 GB on disk, one measurement). |
| Setup | **Single-seat**: `MAX_NUM_SEQS=1` (extra requests queue behind the running one), context limit 384,000 tokens (prompt plus output), GPU memory utilization 0.94, DSpark with 5 draft tokens, `nvfp4_ds_mla` KV cache (432-byte records), KV pool about 400K tokens |

## Results at a glance (measured)

| Metric | Value |
|---|---|
| Single-stream decode | 46.3 tok/s on a structured-output prompt (observed once, 2026-08-22; the launcher's author reports 44 to 47 tok/s for structured content). Prose and code are slower; see the per-content-type table in Update (2026-10). |
| Context | 384,000-token limit configured. Needle retrieval exact at 192,111 tokens (2026-08-22, one trial) and, in a 2026-09-25 re-run on a second node, at 131,072 / 245,760 / 370,000 tokens (one trial each; see Update (2026-10)). |
| Positioning | Deep workstation: one heavy task with exclusive access, trading concurrency for ultra-long context |

## One-command deploy

`scripts/deploy.sh [--port N] [--host ADDR]` checks preconditions (arm64, container GPU runtime, at least 114.3 GiB free memory, no earlyoom, enough disk), clones the pinned launcher commit, verifies the pinned image digest and weights revision, starts the launcher, waits for readiness (first boot can take 40+ minutes), and asserts a real completion.

The default port is 8888 and the default bind address is `127.0.0.1`. Startup uses `MODE=dspark`, `VERIFY_MODEL_CHECKSUMS=1`, and `ABLATE=0`, with the context, memory and KV settings above. It leaves the launcher's `on-failure:1` restart policy unchanged. Local checkout, requested settings and logs live under `.deploy/`. A matching running container must also serve `deepseek-v4-flash-0731` before start is skipped. Changing a tunable uses `./start.sh down` followed by a fresh start. A saved request only permits checking an existing container; memory and disk gates apply again before any fresh start. This allows an idempotent check when the running service already occupies memory.

`scripts/deploy.sh --dry-run` prints the five pins and resolved tunables after offline arm64, memory, earlyoom and disk checks, then exits without touching Docker or the network. `MEMINFO_PATH` can point to a fixture instead of `/proc/meminfo` for offline tests. Dry-run does not verify GPU access, launcher defaults, registry availability or inference. The readiness deadline is 45 minutes; container exit fails immediately at the next poll. **The rewritten script has not been re-run end to end on hardware (T3/T4 not run).**

Offline checks (stdlib only):

```sh
python3 -m unittest discover -s tests -v
python3 -m py_compile tests/test_deploy.py
bash -n scripts/deploy.sh
```

## Key config: client generation budget

```text
maxTokens = 65536  # client request setting
```

`maxTokens` is the per-request `max_tokens` the client sends; the engine has no separate per-generation cap, only the 384,000-token context limit. Where the 65,536 budget was configured in 2026-08 is not recorded. Budget for reasoning plus the answer within the prompt-plus-output context limit.

## Where EXL3 fits in this recipe

- **EXL3 role**: 3.0 bpw weights and controllable memory at ultra-long context (at 0.94 GPU memory utilization the node was left with only about 2 to 3.5 GiB of available memory in our runs, so there is little headroom; dated readings are above). EXL3 describes the weights; this serving path is vLLM-based.
- **Dependencies**: on aarch64 the working path depends on a community pre-built image and kernel patches pinned by digest (no source build in this recipe).
- **Best fit**: single-seat plus ultra-long context as requirements, when you can live with a third-party image pinned by digest. For the serving comparison, see [dell-pro-max-gb10-vllm-stack-ab](https://github.com/ryangu00/dell-pro-max-gb10-vllm-stack-ab).

## Positioning

The single-seat deep workstation handles one long request at a time. Extra requests queue behind it, so callers need timeouts that cover both the wait and their own generation. Retain weights and configuration when switching recipes if a rollback is needed.

## Pitfalls

1. **Client generation budget**: `maxTokens` is a request setting, not a server-side cap; its historical configuration location is unresolved.
2. Only if you build exllamav3 from source yourself (this recipe does not): `export TORCH_CUDA_ARCH_LIST="12.1a"` before the build; a missing arch only fails at runtime. With the pinned image, leave the launcher's architecture settings at the author's defaults.
3. Enforce single-seat semantics on the caller side. The engine does queue (with `MAX_NUM_SEQS=1` a second request waits until the first finishes), but a long request blocks everything behind it: in [dell-pro-max-gb10-vllm-stack-ab](https://github.com/ryangu00/dell-pro-max-gb10-vllm-stack-ab), 6 concurrent requests took 117 s wall (20.6 tok/s aggregate; published comparison, 2026-09-16/17). Put a single-seat queue or semaphore in front and set client timeouts that cover the wait.

## Credits

- Launcher and Docker recipe: Mia's AI Lab, [MiaAI-Lab/DeepSeek-v4-Flash-One-DGX-Spark](https://github.com/MiaAI-Lab/DeepSeek-v4-Flash-One-DGX-Spark). The repository glue is MIT; the image, weights and libraries retain their own licenses.
- Runtime image and hosted weights repository: 0xSero (`ghcr.io/0xsero/deepseek-v4-flash-0731-spark-sparkinfer`, `0xSero/deepseek-v4-flash-0731-spark`). The launcher's author limits that attribution to the hosted artifacts, not the EXL3 format.
- EXL3 format and underlying ExLlama work: turboderp ([turboderp-org/exllamav3](https://github.com/turboderp-org/exllamav3)) and BrandonMusicKy, per the launcher's credits.
- Base model: DeepSeek V4 Flash 0731 ([deepseek-ai/DeepSeek-V4-Flash-0731](https://huggingface.co/deepseek-ai/DeepSeek-V4-Flash-0731)); the upstream model license carries over to any serving.

This cookbook measures the recipe on Dell Pro Max with GB10; it does not claim authorship of the recipe.

---
*RyanAI Lab · Measurements and observations are qualified above. Updated 2026-10 (engine description corrected). Issues welcome.*
