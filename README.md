# DeepSeek V4 Flash EXL3 on a single Dell Pro Max with GB10 — the 384K single-seat deep workstation

> The opposite of the "multi-seat concurrent" setup: exllamav3 (EXL3) quantization, one machine, one seat, 384K ultra-long context, 46.3 tok/s.
> Built for "one person / one agent with exclusive access, doing deep work on ultra-long context" — we call it the **deep workstation**.

## Hardware and versions

| Item | Spec / version |
|---|---|
| Machine | Dell Pro Max with GB10 ×1 (sm_121/aarch64) |
| Engine | [exllamav3](https://github.com/turboderp-org/exllamav3) (EXL3 format; works on aarch64+sm_121, build from source — follow the official build docs, the key is `TORCH_CUDA_ARCH_LIST` including `12.1a`, see pitfall #2) |
| Weights | DeepSeek V4 Flash, EXL3 3.0bpw quantization |
| Setup | **Single-seat** (no concurrency), max ctx 384K |

## Results at a glance (measured)

| Metric | Value |
|---|---|
| Single-stream decode | 46.3 tok/s (steady-state single stream on medium-to-long prompts, greedy/low-temperature sampling) |
| Context | 384K configured and actually run; needle retrieval hits at 192K on deep tasks (same staircase methodology as the Flash-Next chapter in this series) |
| Positioning | Deep workstation: one heavy task with exclusive access, trading concurrency for ultra-long context plus stable speed |

## One-command deploy

`scripts/deploy.sh [--port N] [--ctx N]` — includes the exllamav3 source build (arch set explicitly, `EXL3_COMMIT` pinnable) → idempotent startup → a real inference assertion.

## Key config, and one parameter we burned through twice before learning it

```
maxTokens (per-generation cap) = 65536
```

**Why so large**: with thinking enabled, this model's reasoning stream on heavy tasks (long code reviews, multi-step reasoning) measured **30k+ tokens** (maxTokens here is the server-side per-generation cap). We set maxTokens to 8192 and then 32768 — **thinking burned through the cap both times** (reasoning ate the entire budget and the answer got truncated before it started). 65536 is what finally held.
General lesson: **budget a thinking model's generation cap as "peak reasoning + answer", not just the answer**. Peak reasoning can only be measured — feed it your heaviest real task once and count the reasoning tokens.

## Where EXL3 fits (vs vLLM/llama.cpp)

- **EXL3 strengths**: at the same bpw, its quantization quality has a better reputation than traditional 4bit routes (community consensus — verify on your own tasks), stable single-stream speed, controllable memory at ultra-long ctx (3.0bpw weights are significantly smaller than 4bit).
- **Weaknesses**: small ecosystem (few tools and tutorials), concurrency/serving capability behind vLLM, and on aarch64 you build it yourself.
- **Best fit**: single-seat plus ultra-long context as hard requirements, and you can live with building from source. For multi-seat concurrency, see the DSV4F dual-machine chapter in this series.

## Positioning

The single-seat deep workstation and the concurrent serving setup are **complementary**, not competing: the concurrent setup handles everyday short tasks, the deep workstation handles "stuff a 200K codebase in and think slowly" work. General advice for running multiple setups side by side: give each its own port with clear semantics and let callers pick by port; when switching setups, keep each one's weights and config (storage is cheap, rebuilding is expensive).

## Pitfalls

1. **maxTokens burned through** (above — the lesson that cost us two burn-throughs).
2. Building exllamav3 on aarch64: `export TORCH_CUDA_ARCH_LIST="12.1a"` before the build — miss this arch at build time and the error only surfaces at runtime.
3. Enforce single-seat semantics on the caller side: the EXL3 server won't queue or govern for you, and concurrent requests will drag each other down — put a single-seat queue or semaphore in front.

---
*RyanAI Lab · All numbers measured on our resident environment. Updated 2026-09. Issues welcome.*
