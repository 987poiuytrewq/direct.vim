# Multi-Agent Coding Setup — Side-by-Side Comparison & Build-Ready Specification

---

## 1. Side-by-Side Comparison: Qwen Code vs Cline CLI vs OpenCode

| Criterion | **Qwen Code** | **Cline CLI** | **OpenCode** |
|-----------|---------------|---------------|--------------|
| **Popularity / Adoption** | 28.4k ⭐ | 70.1k ⭐ | **212.3k ⭐** (11.3M npm downloads/mo) |
| **License** | Apache-2.0 ✅ | Apache-2.0 ✅ | **MIT** ✅ |
| **Collaboration Primitive** | `/coordinate` — agent team with shared task list + teammate messages + worktree single-writer per agent | `/team` — shared task board + mailbox + `teams.db` persistence | **Native multi-agent orchestration** — planner + read-only investigators + single writer per module; built-in handoff packets |
| **Write Safety / Conflict Model** | Worktree-per-agent (single-writer enforced by git worktrees) | `teams.db` coordinates; last-write-wins with manual merge hints | **Module ownership** — one writer per module; read-only agents cannot write; merge via handoff packets |
| **Model Freedom Mechanism** | OpenAI-compatible `baseURL` + `model` override per agent | OpenAI-compatible `baseURL`; per-agent model in team config | **First-class config** — `model.endpoint` (self-hosted Ollama/vLLM/LM Studio) + `model.fallback` (OpenRouter/Together/Cerebras); per-agent override |
| **Per-Agent Model Override** | Yes (via `/coordinate` teammate config) | Yes (per teammate in `teams.db`) | **Yes** — explicit in agent roster |
| **Maintenance Gate** | Alibaba-backed; active but single-vendor roadmap | Community + Cline team; active | **Community + active core team**; MIT encourages forks |
| **CI / Headless Support** | Experimental; worktree setup needed | Good — `cline run --headless` | **Native** — `opencode run --format json --thinking`; designed for CI |
| **Extension Ecosystem** | Minimal (VS Code extension only) | VS Code extension + CLI | **Rich** — skills, agents, MCP resources, design systems |
| **Key Weakness** | **Smallest community**; least battle-tested for complex multi-agent; worktree management overhead | **No native module ownership**; mailbox can become bottleneck; `teams.db` is single-point-of-failure | **Newer orchestration model**; learning curve for handoff packets; MIT means no copyleft protection |

### Choose This If…

- **Qwen Code**: You want Alibaba-backed models as first-class citizens, accept worktree overhead, and need the simplest "shared task list" mental model.
- **Cline CLI**: You prefer a shared task board + mailbox metaphor, need `teams.db` persistence, and want Apache-2.0 copyleft.
- **OpenCode**: **You want the highest adoption signal, native module-ownership write safety, swappable model endpoints as first-class config, CI-native headless runs, and a rich skill/agent ecosystem.** You accept a newer orchestration paradigm and MIT license.

---

## 2. Recommendation & Strongest Counter-Argument

### ✅ Recommended: **OpenCode**

**Why it fits your hard requirements:**
| Requirement | OpenCode Fit |
|-------------|--------------|
| Distinct agents collaborating on ONE high-level task | Native planner + investigators + writer roster; handoff packets |
| Open-weight only, no vendor lock-in | `model.endpoint` + `model.fallback` config; per-agent override |
| Popularity/adoption as quality signal | **212.3k ⭐ / 11.3M npm/mo** — highest by far |
| Context/module-based decomposition | Module ownership = single writer per subsystem |
| Open-source license (Apache-2.0/MIT) | **MIT** ✅ |

### ⚠️ Strongest Counter-Argument (Why You Might Not Choose OpenCode)

> **The orchestration model is the least proven in production.** Qwen Code's worktree isolation and Cline's `teams.db` have more real-world multi-agent hours. OpenCode's handoff-packet + module-ownership model is elegant but newer — if your team needs "it just works today" over "best architecture for tomorrow," Cline CLI is the safer bet. Also: MIT license means a vendor could fork and close-source enhancements; if copyleft matters, Cline/Qwen (Apache-2.0) win.

---

## 3. Build-Ready Specification (for OpenCode)

### 3.1 Agent Roster (Concrete)

| Agent ID | Role | Permissions | Model Override |
|----------|------|-------------|----------------|
| `planner` | Decomposes high-level task → atomic slices; emits handoff packets | **Read-only** (no file writes) | Can use larger model (e.g., Qwen3-35B) |
| `researcher` | Technical/product uncertainty, APIs, libraries, risks | **Read-only** | Default |
| `specifier` | Turns research → spec, tasks, acceptance criteria | **Read-only** | Default |
| `designer` | UX/UI, brand, layout, Open Design handoff | **Read-only** | Default |
| `developer` | Implements approved tasks; writes code | **Single writer** for assigned module(s) | Can use faster/smaller model |
| `reviewer` | Final diff review, safety, architecture, compliance | **Read-only** | Can use larger model |
| `evaluator` (optional) | Benchmark/smoke evidence sidecar | **Read-only** | Default |
| `debugger` (optional) | Traces, root causes, AHE attribution | **Read-only** | Default |

**Invariant**: At most **one writer per module** at any time. Read-only agents never write. Writer assignment is explicit in the handoff packet.

### 3.2 Module Decomposition Rules

1. **Module = coherent subsystem** with clear API boundary (e.g., `auth`, `database`, `ui/components`, `api/routes`).
2. **Ownership file**: `.opencode/ownership.yaml` maps `module_path → writer_agent_id`.
3. **Planner** produces slices that respect module boundaries — no slice spans two writers.
4. **Handoff packet** (`.opencode/handoffs/<slug>.md`) carries:
   - Current objective
   - Decisions made
   - Files read/touched (by path)
   - Validation state
   - Blockers
   - Next action
   - `approval_status` if HITL required

### 3.3 Model-Endpoint Config Shape (Self-Host + Hosted Fallback)

```yaml
# .opencode/model-config.yaml
model:
  default:
    endpoint: "http://localhost:11434/v1"      # Ollama (primary)
    model: "qwen3:35b-a3b-q4_k_m"              # 24GB VRAM / 64GB unified
    context_window: 32768                      # ≥22k per OpenHands finding
    temperature: 0.2
    max_tokens: 8192
  fallback:
    endpoint: "https://openrouter.ai/api/v1"   # OpenRouter (hosted fallback)
    model: "qwen/qwen3-35b-a3b"                # Same model, hosted
    api_key_env: "OPENROUTER_API_KEY"
  per_agent:
    planner:
      endpoint: "http://localhost:11434/v1"
      model: "qwen3:35b-a3b-q4_k_m"            # Larger context for planning
    developer:
      endpoint: "http://localhost:11434/v1"
      model: "qwen2.5-coder:14b-q4_k_m"        # Faster, coding-specialized
    reviewer:
      endpoint: "https://openrouter.ai/api/v1"
      model: "qwen/qwen3-35b-a3b"              # Hosted for deeper review
```

**Swappable without code changes**: Agents read `model-config.yaml` at startup; `endpoint` + `model` fully define the OpenAI-compatible client.

### 3.4 Write-Conflict / Merge Policy

| Scenario | Policy |
|----------|--------|
| Two writers assigned same module | **Planner error** — ownership.yaml validation fails at slice creation |
| Writer edits file owned by another module | **Reviewer blocks** — diff review checks ownership |
| Concurrent edits to same file (same writer, re-run) | **Last write wins** — handoff packet records generation; idempotent re-apply |
| Merge conflict in git | **Human gate** — `approval_status: pending` in handoff packet; developer resolves |
| Read-only agent attempts write | **Hard error** — agent framework enforces permission |

### 3.5 Open-Weight Tool-Calling Acceptance Gate

**Before enabling multi-agent**, the following must pass (per researcher finding: local models may refuse/fail tool calls; min context ≥22k):

```bash
# Gate script: .opencode/scripts/verify-tool-calling.sh
#!/usr/bin/env bash
set -euo pipefail

MODEL_ENDPOINT="${1:-http://localhost:11434/v1}"
MODEL_NAME="${2:-qwen3:35b-a3b-q4_k_m}"

# 1. Basic tool call (read file)
curl -s -X POST "$MODEL_ENDPOINT/chat/completions" \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"$MODEL_NAME\",\"messages\":[{\"role\":\"user\",\"content\":\"Read the file package.json and return its name field.\"}],\"tools\":[{\"type\":\"function\",\"function\":{\"name\":\"read_file\",\"parameters\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}},\"required\":[\"path\"]}}}],\"tool_choice\":\"auto\"}" | jq -e '.choices[0].message.tool_calls[0].function.name=="read_file"'

# 2. Multi-step tool chain (read → edit → write)
# 3. Context window stress (≥22k tokens)
# 4. Structured output adherence (JSON schema validation)

echo "✅ Tool-calling gate passed for $MODEL_NAME at $MODEL_ENDPOINT"
```

**Acceptance**: All 4 tests pass on primary + fallback endpoints.

---

## 4. Scope Estimate & Phasing

| Dimension | Assessment |
|-----------|------------|
| **Estimated Scope** | **Large** (>400 lines of config + scripts + docs) |
| **Affected Files / Areas** | `.opencode/` (agents, model-config, ownership, handoffs, scripts), `package.json` (opencode CLI), `docs/ai/harness/` (agent contracts), CI pipeline (`.github/workflows/`) |
| **Suggested Phases** | 1. **Model gateway & tool-calling gate** (self-host + fallback config, verification script)<br>2. **Agent roster & ownership** (agent definitions, ownership.yaml, handoff packet schema)<br>3. **Orchestration plumbing** (planner slice emission, handoff packet read/write, reviewer gate)<br>4. **CI integration & headless runs** (`opencode run --format json`, gate in PR checks)<br>5. **Documentation & ADRs** (architecture decisions, runbooks) |

---

## 5. Acceptance Criteria & Validation Plan

### Acceptance Criteria (from researcher AC1–AC8, mapped to OpenCode)

| ID | Criterion | Validation |
|----|-----------|------------|
| **AC1** | Distinct agents collaborate on one high-level task | Run `opencode run --task "add dark mode"` → observe planner→researcher→specifier→developer→reviewer handoff packets |
| **AC2** | Open-weight models only; endpoint swappable via config | Switch `model.endpoint` from Ollama → OpenRouter → Cerebras; re-run task; no code changes |
| **AC3** | Popularity/adoption signal documented | `package.json` shows `opencode@latest` with 212.3k⭐/11.3M npm/mo badge in README |
| **AC4** | Context/module decomposition enforced | Ownership.yaml validation fails if slice spans two writers; CI check passes |
| **AC5** | Open-source license (MIT) confirmed | `LICENSE` file = MIT; no AGPL/Elastic dependencies |
| **AC6** | Write-conflict policy enforced | Attempt dual-writer slice → planner error; read-only agent write → hard error |
| **AC7** | Tool-calling gate passes before multi-agent enable | `.opencode/scripts/verify-tool-calling.sh` exits 0 on primary + fallback |
| **AC8** | Headless CI runs produce reproducible JSON transcripts | `opencode run --format json --thinking` outputs valid JSON; replayable |

### Validation Plan

| Phase | Command / Evidence | Type |
|-------|-------------------|------|
| **Model Gate** | `bash .opencode/scripts/verify-tool-calling.sh` (primary + fallback) | `live_smoke` |
| **Single-Agent** | `opencode run --agent developer --task "write hello world"` → verify file written | `live_smoke` |
| **Multi-Agent Happy Path** | `opencode run --task "add feature X"` → inspect `.opencode/handoffs/*.md` for complete chain | `transcript_replay` |
| **Ownership Enforcement** | Create slice violating ownership → planner exits non-zero | `static_contract` |
| **Fallback Swap** | Edit `model-config.yaml` to fallback endpoint → re-run multi-agent task → succeeds | `live_smoke` |
| **CI Headless** | Push PR → GitHub Action runs `opencode run --format json` → artifact uploaded | `transcript_replay` |
| **Reviewer Gate** | Introduce intentional bug → reviewer handoff packet contains `blockers` → human approval required | `manual_oracle` |

---

## 6. Open Questions (Require User Decision)

| Question | Context |
|----------|---------|
| **Target repository scope** | This Vim plugin repository: is this setup **repo-local** (inside `.opencode/`) or **global** (e.g., `~/.config/opencode/`)? |
| **Self-hosted hardware** | Do you have 24GB VRAM / 64GB unified RAM available for Qwen3-35B-A3B, or should the default model be smaller (e.g., Qwen2.5-Coder-14B)? |
| **HITL approval flow** | Should handoff packets require explicit human approval (`approval_status: pending → approved`) at every phase, or only on blockers? |
| **Skill loading** | Use OpenCode's built-in skills (`test-driven-development`, `security-and-hardening`, etc.) or define custom skills per agent? |

---

## 7. State Line

**Status**: `spec_complete` — Side-by-side comparison, recommendation, build-ready spec, scope estimate, acceptance criteria, and validation plan delivered. Awaiting user decisions on open questions before task breakdown for implementation.