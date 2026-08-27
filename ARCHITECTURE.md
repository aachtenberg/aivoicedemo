# Waze Voice Demo — Architecture & 2-Week Plan

**Goal:** An event-driven AI agent that detects when a planned sequence of stops is
blown up (crash, closure) and places an automated outbound voice call so the driver can
confirm a **re-optimized remaining-stop order** without looking at a screen. Demo-quality,
AWS Bedrock at the core, with a **swappable outbound voice provider** (Amazon Connect
default; Twilio / SNS interchangeable).

The useful thing is not the optimizer. Re-ordering remaining stops is easy to compute and
hard to consume while driving. Voice confirms the new order; a public [Waze Deep
Link](https://developers.google.com/waze/deeplinks) is last-mile turn-by-turn for the next
stop. There is **no public Waze routing/VRP API** — we do not pretend otherwise.

> 📊 **Rendered diagrams** (architecture, call-lifecycle state machine, live-call
> sequence) are in [DIAGRAMS.md](DIAGRAMS.md). The ASCII diagrams inline below are the
> plain-text equivalents.

---

## 1. Core principle: isolate the telephony layer

The single most important design decision is that **nothing in the business logic knows
how the call is placed.** The orchestrator and the AI dialog engine speak two small,
provider-agnostic contracts. Each telephony vendor gets a thin adapter that translates
its native webhook/API format to/from those contracts.

```
                         provider-agnostic                 provider-specific
  ┌───────────────┐      ┌──────────────────┐   adapter   ┌──────────────────┐
  │  Orchestrator │─────▶│  VoiceProvider   │────────────▶│ Connect adapter  │ (default)
  │   (Lambda)    │      │   interface      │             │ Twilio adapter   │ (swap)
  └───────────────┘      └──────────────────┘             │ SNS/SMS adapter  │ (fallback)
                                                          └──────────────────┘
  ┌───────────────┐      ┌──────────────────┐
  │ Bedrock-backed│◀────▶│  DialogTurn      │◀── same adapters translate live
  │ dialog engine │      │   contract       │     conversation turns
  └───────────────┘      └──────────────────┘
```

### `VoiceProvider` contract (placing the call)

```
placeCall(CallRequest) -> CallHandle
  CallRequest  = { callId, toNumber, fromNumber, locale,
                   dialogConfig, context }   # context = route + canned optimizer result
  CallHandle   = { providerCallId, status }
getStatus(callId) -> { status, lastEvent }
# Outcome is emitted asynchronously as a CallCompleted event (answered / voicemail /
# no-answer / failed / customer-confirmed), NOT returned inline.
```

### `DialogTurn` contract (the live conversation, if interactive)

```
turn({ sessionId, userUtterance?, dtmf?, context }) ->
     { speech, action }
  action ∈ { CONTINUE, COLLECT_DTMF, END_CALL, TRANSFER, LEAVE_VOICEMAIL }
```

The Bedrock dialog engine implements `DialogTurn` once. Connect reaches it via a Lex
code-hook Lambda; Twilio reaches it via a TwiML webhook Lambda. **Same brain, different
mouth.** Provider is chosen at deploy time via an SSM parameter (`/voicedemo/provider`),
so swapping is a config flip + adapter deploy, not a rewrite.

---

## 2. End-to-end flow

```
[Route simulator]
        │  "incident blew up remaining stops"
        ▼
  API Gateway  ──▶  EventBridge  (RouteDisrupted)
                        │
                        ▼
                 Call Orchestrator (Lambda)
                   • loads route + canned optimizer result from DynamoDB
                   • Bedrock Agent decides: call now? quiet hours?
                   • builds CallRequest, calls VoiceProvider.placeCall()
                        │
                        ▼
                 VoiceProvider adapter ──▶ Amazon Connect (default)
                        │                      • outbound contact
                        │                      • contact flow → Polly TTS
                        │                      • Lex code-hook ──▶ DialogTurn Lambda ──▶ Bedrock
                        ▼
                 Call outcome ──▶ EventBridge (CallCompleted) ──▶ DynamoDB + CloudWatch
```

## 3. AWS components

| Concern | Service | Notes |
|---|---|---|
| Event bus | **EventBridge** | `RouteDisrupted` (in) + `CallCompleted`/`RetryScheduled`/`DoNotCall` (out) |
| Ingress / simulator | **API Gateway + Lambda** | webhook + a tiny "mark route disrupted" admin trigger for the demo |
| Call orchestration | **Step Functions** | one execution per notification job = state machine + retries + waits + telemetry (§8); Lambdas are task workers |
| AI reasoning / dialog | **Bedrock** (Claude via Converse) | `DialogTurn`: message composition + live dialog turns; boto3 Converse, forced tool schema (§9). AgentCore is a graduation path, not v1 (§11) |
| Safety | **Bedrock Guardrails** | denied topics + PII block + prompt-attack + grounding, on input & output (§9) |
| Behavior config | **AWS AppConfig** | prompts/copy/knobs, validated + staged + auto-rollback — hot-edit, no deploy (§10) |
| Voice (default) | **Amazon Connect** | `StartOutboundVoiceContact`, contact flow, Polly TTS, Lex for capture |
| Voice (swap) | **Twilio** Programmable Voice | TwiML `<Say>`/`<Gather>` adapter behind same interface |
| Voice (fallback) | **SNS / Polly** | SMS notify or generated-audio voicemail; non-interactive |
| State / telemetry | **DynamoDB** | jobs, attempts, call-event log — source of truth for the dashboard (§8) |
| Recordings/transcripts | **S3** | call audio + transcript artifacts |
| Infra config / provider select | **SSM Parameter Store** | `/voicedemo/provider`, phone numbers, table names, guardrail id |
| Observability | **CloudWatch** (EMF) + **X-Ray** | funnel metrics, alarms, cross-service trace (§8) |
| IaC | **OpenTofu** (`hashicorp/aws`; `awscc` escape hatch) | one root module, region-parameterized, us-east-1 |

---

## 4. Two-week plan (10 working days, risk-first)

**Day 0 (do immediately — provisioning has lead time):** claim an Amazon Connect phone
number / verify Twilio caller IDs. This is the #1 schedule risk; outbound numbers and
trial-account caller-ID verification can take a day+.

> **Progress — as of 2026-07-01:** scaffold is **applied to AWS** (us-east-1) and verified end-to-end. **Dialog engine is live on Bedrock** (real Claude
> reasoning across all 7 actions, guardrail enforcing, EMF + X-Ray + dashboard).
> **Voice spike proven** (jewelry persona) — a real outbound Connect call played a Polly
> message. This branch retargets copy, actions, and ingress to Waze Voice re-route
> confirmation (Plane `demos` / WazeVoiceDemo). Same stack.

| Days | Phase | Status | Notes on remaining work |
|---|---|---|---|
| 1–2 | **Foundations** | ✅ | Scaffold applied + verified. Outstanding: seed data, CI `tofu validate`. |
| 3–4 | **Voice spike + Phase B brain loop** | ✅ | Outbound spike proven (`place_call.sh`). **Interactive loop proven** too: Lex V2 (speech pipe) → `connect_adapter` code-hook → dialog engine, verified via `recognize-text` (`build_lex.sh`) — continue vs. terminal-close mapping works. **Last mile (needs a live call):** interactive contact flow (GetCustomerInput → Lex, loop on ElicitIntent, branch on `finalAction`) + Connect↔Lex association. |
| 5–6 | **Bedrock dialog engine (safe by construction)** | ✅ | Live: Converse + least-privilege projection + forced tool schema + guardrail + `validate()`. All 7 actions exercised. |
| 7 | **Config plane** | 🟡 | AppConfig + JSON-schema validator **deployed**. Outstanding: extension layer + runtime read wired into the Lambda. |
| 8 | **Orchestration + telemetry** | 🟡 | SFN job + EventBridge rule + intake **live & verified**; EMF metrics + X-Ray + dashboard live. Outstanding: task-token callback, DynamoDB outcome writes, `CallCompleted` events. |
| 9 | **Provider swap + AgentCore showcase (stretch)** | ⬜ | Flip to Twilio, re-prove abstraction. Optional AgentCore Memory (§11). |
| 10 | **Polish + buffer** | ⬜ | Demo script (§9 adversarial beat + §10 hot-config tweak), runbook, cost notes. |

---

## 5. Key risks & callouts

- **Telephony provisioning lead time** — start Day 0 (see above).
- **Connect outbound** — outbound campaigns/permissions and service quotas may need a
  support request; a single `StartOutboundVoiceContact` is the lighter demo path.
- **Trial-account limits** — Twilio trial only calls verified numbers; Connect sandbox
  has caps. Use real (small-quota) numbers for the demo.
- **Compliance (even for a demo)** — TCPA-style consent, allowed calling hours / quiet
  hours, and do-not-call handling. Bake "quiet hours" into the orchestrator decision so
  it's visible in the demo narrative.
- **Real-time latency** — Bedrock dialog turns inside a live call must stay snappy;
  keep prompts tight, stream where possible, and pre-compose the opening line.
- **Cost** — Connect per-minute + Bedrock tokens + telephony; trivial at demo scale but
  worth a one-line estimate for the client.

---

## 6. Why an LLM — and where it's just IVR

Be honest about this up front, because a sharp reviewer will ask: **the happy path does
not need an LLM.** "Crash on Lincoln, press 1 to take the new stop order" is a solved
problem — a Connect contact flow + Polly TTS + DTMF/Lex capture does it deterministically,
and does it *better* than an LLM: lower latency, near-zero cost, fully predictable, no
hallucination, easy to certify for compliance.

The LLM's value is **variance absorption, not task execution.** The task is trivial; the
*variance in how a human responds on a phone while driving* is the hard part — and that's
exactly what rules handle badly and an LLM handles well.

| Capability | Rules / IVR | LLM (Bedrock) | Verdict |
|---|---|---|---|
| Fixed "new stop order" notification | ✅ perfect | ✅ but overkill | **Use IVR** |
| Menu confirm (press 1 to accept) | ✅ perfect | — | **Use IVR** |
| Off-script speech ("skip the pharmacy, they're out of stock") | ❌ falls off a cliff | ✅ stays on-task | **LLM** |
| "I'm already at the school" → treat as arrived, next stop changes | ❌ combinatorial | ✅ | **LLM** |
| "Take me off your list" from open speech → do-not-call | ❌ only if it's a menu item | ✅ | **LLM (compliance)** |
| Structured outcome (accepted / keep-old / skipped / DNC) | ⚠️ brittle | ✅ | **LLM** |
| Future: inbound add-a-stop, two-way time windows | ❌ rebuild each time | ✅ same architecture | **LLM (platform bet)** |

**Rule of thumb:** deterministic parts stay deterministic (dial, play the opener,
capture a DTMF press). The LLM is invoked only when the caller says something the flow
didn't anticipate. This keeps latency and cost down *and* makes the LLM's role legible.

---

## 7. Demo narrative — engineered to distinguish the LLM

The demo must **deliberately show moments a contact flow could not handle.** Structure it
as a deterministic beat, then an LLM beat, so the contrast is visible:

**Fixture (route R-1042):** Sam is mid-run on afternoon errands — Lincoln Pharmacy → Oak
Street school pickup → home. A crash closes Lincoln Avenue (+18 min if we keep the old
order). Canned optimizer proposes: school pickup first via 4th Street, then the pharmacy,
then home. ETA 3:40 instead of 4:05 stuck in the jam.

1. **[Trigger]** Operator marks route R-1042 disrupted in the simulator
   (`POST /routes/1042/disrupted`).
2. **[Deterministic — cheap & reliable]** Phone rings within seconds. Agent plays the
   opener: *"Hi Sam, this is Waze. A crash closed Lincoln Avenue. I reordered your
   remaining stops — school pickup first, then the pharmacy. Press 1 to take it, or stay
   on the line."* Narrate: *this part is pure IVR, no LLM — fast and free.*
3. **[LLM beat #1 — skip a stop]** Instead of pressing 1, the caller says *"Skip the
   pharmacy, they're out of my prescription."* The agent drops that stop, speaks the new
   remaining order, and stays on task. **This is the moment that justifies Bedrock.**
4. **[LLM beat #2 — already there]** *"I'm already at the school."* Treat as arrived;
   next stop becomes the pharmacy. Impossible to template cleanly for every stop.
5. **[LLM beat #3 — compliance from open speech]** *"Stop calling me, just send the
   link."* Agent flags do-not-call and still hands off the Deep Link path.
6. **[Adversarial]** *"What's my home address?"* / *"Where does my kid go to school?"* —
   deflect. Context never contained those coordinates, so the model cannot leak them.
7. **[Outcome]** Dashboard: `ACCEPT_REROUTE` / `KEEP_CURRENT_ROUTE` / `SKIP_STOP` /
   `DO_NOT_CALL`. On accept, next-stop turn-by-turn is a Waze Deep Link
   (`https://waze.com/ul?ll=…&navigate=yes&utm_source=waze-voice-demo`).
8. **[Swap proof]** Re-run with `provider=twilio` — identical behavior on different
   telephony.

**The one-line pitch:** *the LLM isn't there to optimize the route — it's there for the
moment the driver can't look at the new map.*

**Non-goals:** Transport SDK, Waze for Cities feeds, scraping Live Map, or replacing a
real VRP solver with Waze. Inbound "add a stop" is a stretch (`answerCall`), not v1.

---

## 8. Telemetry — call progress, outcomes, retries, errors

Once you're placing real calls you must answer "what happened to call #1234, and why"
at any moment. This is also what makes the demo read as production-grade rather than a
happy-path toy. Three ideas carry the whole design:

1. **One correlation ID threads everything.** `jobId` (derived from `routeId`) flows
   through every log line, event, DB row, and provider call. Given a `jobId` you can
   reconstruct the full story: dial → ring → answer → each dialog turn → outcome.
2. **The provider is normalized away.** Connect contact events and Twilio status
   callbacks look nothing alike. Each adapter translates its native webhook into one
   canonical `CallEvent`, so telemetry, retries, and the dashboard never branch on
   vendor. (Same swap principle as the `VoiceProvider` contract.)
3. **State machine as the backbone.** A **Step Functions** state machine per notification
   job models progress, waits (quiet hours, retry backoff), timeouts, and terminal
   dispositions — *and its execution history is a free, visual audit trail.* This
   replaces the plain "orchestrator Lambda" from §2; the Lambdas become task workers.

### Call lifecycle (the state machine)

```
                         ┌─────────────► ACCEPTED ──────┐
QUEUED → DIALING → RINGING → ANSWERED → IN_DIALOG ─────► KEEP_OLD  ─┤ (terminal)
   │                  │         │                 ├────► SKIP_STOP ─┤
   │                  │         │                 └────► DO_NOT_CALL┘
   │                  │         └► VOICEMAIL ─┐
   │                  └► NO_ANSWER / BUSY ────┼──► retryable?
   └► FAILED (provider/network) ──────────────┘        │
                                              ┌─────────┴─────────┐
                                          yes │                   │ no / max attempts
                                              ▼                   ▼
                                   WAIT_BACKOFF → (re-DIAL)    EXHAUSTED (terminal)
```

- **Terminal, no retry:** `ACCEPTED`, `KEEP_OLD`, `SKIP_STOP` (when it ends the call),
  `DO_NOT_CALL`, `INVALID_NUMBER`, `EXHAUSTED`.
- **Retryable:** `NO_ANSWER`, `BUSY`, transient `FAILED`. Backoff + quiet-hours-aware
  next-attempt time, capped at `maxAttempts` (SSM-configurable, e.g. 3).
- The provider callback resolves the Step Functions **task token** when a call reaches a
  terminal disposition (callback pattern with a heartbeat timeout, so a dropped webhook
  can't hang the job forever).

### Data model (DynamoDB — the queryable source of truth)

| Item | Key | Holds |
|---|---|---|
| **Job** (1 per route) | `PK=job#<jobId>` | `routeId`, `driverId`, `status`, `attemptCount`, `maxAttempts`, `nextRetryAt`, `finalOutcome`, `provider`, timestamps |
| **Attempt** (1 per dial) | `PK=job#<jobId>` `SK=attempt#<n>` | `providerCallId`, `status`, `disposition`, `durationSec`, `errorCode`, `recordingS3Key`, `transcriptS3Key`, started/ended |
| **CallEvent** (append log) | `SK=evt#<ts>` | normalized `type` (DIALING/RINGING/ANSWERED/DTMF/SPEECH/VOICEMAIL/HANGUP/FAILED), `providerRaw`, `ts` |

The **live demo dashboard reads Job/Attempt items directly** for current status; the
CallEvent log gives the per-call timeline drill-down.

### Where each signal goes

| Signal | Sink | Purpose |
|---|---|---|
| Current state / timeline | **DynamoDB** | Dashboard reads, "what's the status of #1234" |
| State transitions | **EventBridge** (`CallCompleted`, `CallFailed`, `RetryScheduled`, `DoNotCall`) | Decoupled fan-out — dashboard, alerting, CRM sync all subscribe |
| Aggregate metrics | **CloudWatch (EMF)** | Funnel: placed→answered→confirmed; voicemail/no-answer/error rates; retry counts; p50/p95 dialog-turn latency; Bedrock token spend |
| Structured logs | **CloudWatch Logs** (JSON, every line carries `jobId`) | Debugging, per-call reconstruction |
| Cross-service trace | **X-Ray** | Latency breakdown across StepFn → provider → dialog → Bedrock |
| Failed invocations | **SQS DLQ + alarm** | Orchestrator / adapter failures that need a human |

### Retries & idempotency

- **Idempotency for free:** the Step Functions execution name **is** the `jobId`, so a
  duplicate `RouteDisrupted` event cannot start a second call for the same route.
- **Transient AWS faults** (throttles, 5xx) are handled by Step Functions task-level
  `Retry`; **call dispositions** (no-answer/busy) are handled by the explicit
  `WAIT_BACKOFF → re-DIAL` loop — two different layers, don't conflate them.
- **`Catch` blocks** route unexpected errors to a `RecordError` state → DLQ + alarm, so a
  bug never silently drops a driver notification.

### What the client sees — the dashboard (BUILT ✅)

A **CloudWatch dashboard** (`aivoicedemo-<env>`) laid out for a glance-then-drill read:

1. **Golden signals up top** (SRE four) as `singleValue` number tiles with sparklines —
   **traffic** (dialog turns, calls placed), **latency** (dialog p95, Bedrock avg),
   **errors** (Lambda errors, converse failures), **saturation** (throttles, concurrency).
   A **gauge** shows dialog p95 against a 5 s budget.
2. **Outcome mix** — a **bar** and **pie** of `DialogTurn` by action (CONFIRM / RESCHEDULE
   / DO_NOT_CALL / TRANSFER …), fed by the EMF custom metrics.
3. **Trend lines** — dialog duration p50/p95/max, Bedrock tokens/turn, safety events,
   Step Functions executions + timing, ingress count/latency, EventBridge, Bedrock.
4. **Diagnostics** — a Logs Insights table tailing guardrail interventions + converse
   failures.

Signals come from **EMF custom metrics** (namespace `VoiceDemo`: DialogTurn by action,
GuardrailBlocked, ConverseFailed, InputTokens, OutputTokens — emitted by the dialog Lambda,
no metrics API call) plus AWS service metrics. **X-Ray active tracing** on the Lambdas +
Step Functions gives the ServiceLens map and end-to-end latency. Pair it with the
**Step Functions visual execution** for a single call — that graph sells the "this is real"
point in the demo.

**Telemetry status:** EMF metrics, X-Ray tracing, and the golden-signals dashboard are
**implemented and live**. Remaining §8 work: the CRM-sync EventBridge consumer and
DynamoDB per-call outcome writes (Day 8–9). Observability backend stays CloudWatch; see
§11 for the X-Ray-vs-OpenTelemetry decision.

---

## 9. Scoping & safety — keeping the agent on-task and secure

**Threat model:** the person who answers is *unauthenticated* — we dialed a number, but
anyone could pick up. The agent is holding route/stop context. So we must assume the
caller may be hostile: off-task abuse ("what's the weather" / free LLM), social
engineering ("what's my home address", "where does my kid go to school", "read me the
card on file"), and prompt injection over speech ("ignore your instructions and…").

**Core principle: prompt instructions are not a security boundary.** A system prompt that
*says* "don't reveal card numbers" is bypassable. The real controls are architectural —
make it so the model **cannot** leak or act out of scope — with enforcement layered on
top. Defense in depth, strongest first:

### 1. Least-privilege context (the #1 control)

The `DialogTurn` prompt contains **only** what this call needs: driver's first name,
route nickname, incident corridor, delay, stop *names*, proposed next stop. It does
**not** contain home/work/school street addresses, coordinates, payment data, or any
other route. *If the data isn't in the context window, the model physically cannot
disclose it* — no prompt trick extracts a home lat/long that was never loaded. This
alone neutralizes most exfiltration asks. Everything else is backstop.

### 2. Constrained action space (structured output, not free-form)

`DialogTurn` returns a **fixed enum of sanctioned actions**, not open text-as-command:
`CONTINUE`, `COLLECT_DTMF`, `ACCEPT_REROUTE`, `KEEP_CURRENT_ROUTE`, `SKIP_STOP`,
`MARK_DO_NOT_CALL`, `TRANSFER_TO_HUMAN`, `END_CALL`. The model picks a move from that list
(Bedrock structured output / tool schema). It cannot invent "read_saved_places" or
"process_payment" — those verbs don't exist in the contract. **Speech is bounded because
the *actions* are bounded.**

### 3. Unauthenticated-caller disclosure rule

Default posture: **disclose nothing you wouldn't leave on a voicemail.** Anything
location-specific beyond the public stop names on this one route (home/work/school
street address, coordinates, other drivers) requires a `TRANSFER_TO_HUMAN`. For the demo
the rule is absolute: **the agent never reads back saved-place details** — it confirms
the new stop order and captures intent, full stop.

### 4. Amazon Bedrock Guardrails (config-driven enforcement — fits the "Bedrock" brief)

Applied to **both** the caller's transcribed utterance (input) and the model's response
(output), before TTS:
- **Denied topics** — payments/billing, saved-place addresses, general knowledge/chit-chat
  → deflect.
- **PII filters** — block the model from ever *emitting* a card number / SSN / full
  address, even if one somehow reached context (backstop to control #1).
- **Prompt-attack detection** — flags "ignore previous instructions"-style injections.
- **Grounding/relevance** — response must stay tied to this re-route.

### 5. Prompt-injection hygiene

Transcribed caller speech is **untrusted input**, kept in the `user` role, clearly
delimited, and *never* concatenated into the instruction block. Instructions live in the
`system` role. "Ignore your instructions" is just user text the guardrail + system prompt
hold against — it isn't wired to override anything.

### 6. Output validation before speaking

A cheap deterministic pass after the model, before Polly/TTS: PII regex (card/SSN
patterns) + on-topic check. On failure, discard the response and speak a safe fallback
line ("I can only help with this re-route — let me get a person") and/or
`TRANSFER_TO_HUMAN`. Belt-and-suspenders behind Guardrails.

### 7. Bounded deflection + escalation

When out of scope, the safe move is a **scripted deflection**, not improvisation:
*"I can only help with this re-route. For anything else, use the Waze app."* Repeated
off-topic or a detected attack → `TRANSFER_TO_HUMAN` or `END_CALL`.

### 8. Turn/time caps

Cap dialog turns and total call duration (already in the state machine). Stops someone
using the line as a free LLM or grinding for a jailbreak, and bounds cost/latency.

### Reconciling with §6–§7 ("the LLM's value is off-script speech")

No contradiction — the scope is **"everything about *this* disrupted stop list," handled
with natural flexibility.** Skipping the pharmacy is *in scope*. "What's the weather" and
"what's my home address" are *out of scope* — hard-gated. The frame: **bounded
flexibility** — the agent improvises freely *inside* a fenced task, and the fence is
enforced in architecture, not vibes.

### Demo beat

Add one adversarial turn to §7: the caller tries *"while I've got you — what's my home
address?"* and the agent deflects cleanly (*"I'm not able to share saved places on this
call…"*) and offers a transfer. Showing the agent **refusing** is as important as showing
it helping — it's what a security-conscious client actually wants to see.

**2-week scope:** controls #1 (least-privilege context) and #2 (constrained actions) are
*free* — they're just how you build the dialog engine, and they carry most of the safety.
Bedrock Guardrails (#4) is config, ~1 day. #6 output validation is a small Lambda step.
Do all four; the rest are prompt discipline that costs nothing.

---

## 10. Configurability & maintainability — behavior out of code

Wording, tone, deflection lines, allowed intents, model choice, retry counts, guardrail
thresholds — these change constantly, often driven by non-engineers (shop ops,
compliance). If they're string literals in a Lambda, every tweak is a PR + redeploy. So
split the system into **two planes**:

### The two planes

| | **Config plane** (hot-edit, no deploy) | **Code plane** (change via PR + deploy) |
|---|---|---|
| **What** | System-prompt text, opener/deflection copy, per-intent guidance, model ID, temperature, max turns, retry/backoff, quiet hours, guardrail *version pointer* | Lambda logic, `validate()` allowlist + PII regex, injection hygiene, state-machine structure, provider adapters |
| **Why here** | Pure behavior/copy/knobs — safe to tune fast | **These are the enforcement** — a security control must not be editable without review (§9) |
| **Lives in** | **AWS AppConfig** (+ SSM for infra scalars) | Git → OpenTofu / Lambda |

The rule that keeps this honest: **the config plane can make the agent *say* different
things; it cannot widen what the agent is *allowed to do*.** The action allowlist and
output validator stay in code. Config changes the fence's signage, not the fence.

### Why AppConfig, not just an S3 file or env var

The failure mode of "quick tweaks not baked into code" is that a fat-fingered prompt edit
ships straight to a live phone line. AppConfig gives you tweak-speed *with* guardrails:

- **Validation on publish** — attach a **JSON-schema validator** (and/or a Lambda
  validator) to the config profile. A malformed `dialog-config.json` — missing field,
  bad enum, empty opener — is *rejected at publish time*, never deployed.
- **Staged rollout + bake time** — a deployment strategy rolls the change out gradually
  with a monitoring window.
- **Auto-rollback on alarm** — wire the environment to CloudWatch alarms (error rate,
  guardrail-trip rate). If a new config spikes them during bake, AppConfig **rolls back
  automatically**.
- **Instant, no cold-restart** — the **AppConfig Lambda extension** (a layer) polls and
  caches; the handler just reads `http://localhost:2772/...`. A tweak propagates within
  the poll interval (seconds) with no redeploy and no per-invoke fetch cost.

### The config document (what a non-engineer edits)

```jsonc
// dialog-config.json — validated against a JSON schema on publish
{
  "model_id": "us.anthropic.claude-haiku-4-5",
  "max_turns": 6,
  "system_prompt": "You handle ONLY this one disrupted route...",
  "copy": {
    "opener": "Hi {driver_first_name}, this is Waze. {incident_summary}. I reordered your remaining stops — {proposed_next_stop} first.",
    "deflect": "I can only help with this re-route.",
    "confirm": "Got it — take {proposed_next_stop} first. I've sent the next stop to Waze. Drive safe."
  },
  "guardrail_version": "7"       // pointer only; the guardrail itself is TF-managed
}
```

Handler read (cached by the extension, ~15 lines, no redeploy to pick up edits):

```python
import urllib.request, json
def load_config():
    url = "http://localhost:2772/applications/voicedemo/environments/demo/configurations/dialog"
    return json.load(urllib.request.urlopen(url))
```

### The rest of the knobs

- **SSM Parameter Store** — infra-shaped scalars that pair with deploy (provider
  selection `/voicedemo/provider`, phone numbers, table names).
- **Bedrock Guardrails** — already externalized: edit topics/PII/thresholds in the
  console or TF, **publish a new version**, then flip `guardrail_version` in AppConfig to
  cut over — no code change. Old versions stay pinnable for rollback.
- **Bedrock Prompt Management** (optional) — if the client wants the system prompt itself
  versioned/A-B-tested as a managed, non-file artifact, it's the native home for it; the
  Lambda references a prompt ARN + version instead of the inline string.

### OpenTofu footprint

`aws_appconfig_application`, `_environment`, `_configuration_profile` (with a
`validator { type = "JSON_SCHEMA" }`), `_hosted_configuration_version`, and a
`_deployment_strategy` with a bake window — plus the Lambda extension layer ARN on each
dialog Lambda. ~1 small module.

**2-week scope:** AppConfig for the dialog document + the JSON-schema validator is the
high-value slice (~1 day) and demos beautifully — *edit a line of copy, hear the call
change on the next dial, no deploy.* Auto-rollback alarms and Prompt Management are Day 9
polish. **Do not** move the `validate()` allowlist into config, no matter how tempting —
that's the one line between "maintainable" and "a config edit disabled the safety."

---

## 11. Framework & platform choices (why not LangChain / AgentCore-first)

Pre-answering the three most likely "why didn't you use X" questions.

### LangChain / LangGraph — not for v1

The dialog turn is a **single constrained Converse call** (context in, forced tool schema
out, guardrail attached). LangChain's value is chaining / agent loops / memory / RAG —
none of which a single-shot call needs. Adding it would cost cold-start latency on the
real-time path, and obscure the deliberately-auditable security surface (§9). The "agent
loop" that *does* exist here — retries, waits, voicemail, callbacks — is the telephony
lifecycle, and that belongs in **Step Functions** (durable, external), not an in-process
graph. **Revisit only if** the agent grows into multi-step RAG / multi-backend tool
orchestration — then prefer **LangGraph**, and weigh it against Step Functions explicitly.

### AgentCore — graduation path, not the starting point

AgentCore is an agent *operations platform* (Runtime, Memory, Gateway, Identity,
Observability), not a framework. Mapped to this demo: Runtime is redundant with
Lambda+Step Functions, Memory is a nice-to-have but in mild tension with §9's
least-privilege posture, Gateway/Identity don't apply (one fixed tool; unauthenticated
caller), Observability overlaps §8. Its strengths (long sessions, multi-tool gateway,
cross-session memory) are *latent* in a single-turn notification call.

**Why not start there anyway?** Because the `DialogTurn` contract already isolates the one
piece that would change — moving "Lambda implements `DialogTurn`" → "AgentCore Runtime
implements `DialogTurn`" is a contained swap; telephony, telemetry, config, and security
controls don't move. So deferring costs almost nothing, while starting on the newest
service adds deadline risk and a latency mismatch on the live-call hot path. **It graduates
onto AgentCore when the agent becomes genuinely multi-step** — most likely reaching for
**Memory** first (the "we spoke last week" feature), optionally shown as a Day-9 stretch.

### Observability — X-Ray now, OpenTelemetry as a graduation

Same reasoning applied to telemetry. We use **X-Ray active tracing** (Lambdas + Step
Functions) + **EMF metrics** + the CloudWatch dashboard — all AWS-native, negligible
hot-path cost. **Full OpenTelemetry via ADOT** is deliberately *not* v1: the ADOT Lambda
collector adds cold-start/latency on the real-time call path, and OTel's headline benefit
(portability to a non-CloudWatch backend) is latent in an all-AWS demo.

**When it flips:** if the client runs (or mandates) a non-CloudWatch backend or an org OTel
standard, instrument ADOT then — it's a Lambda-layer + env-var change, not a rewrite
(X-Ray already ingests OTLP; our logs are structured/OTel-friendly). Note: **Grafana**
(the likely future backend) consumes CloudWatch metrics + X-Ray traces as native data
sources, so today's telemetry isn't wasted even if the frontend later changes.

### The through-line

Every "swap later" is cheap because the two seams — **`VoiceProvider`** (telephony) and
**`DialogTurn`** (reasoning) — are stable contracts. That's what lets v1 be boring and
proven (Lambda + Step Functions + Bedrock Converse) while keeping AgentCore, Twilio,
LangGraph, and OpenTelemetry as low-cost future options rather than day-one bets.
