# Waze Voice Demo

An event-driven AI agent that detects a disrupted multi-stop route, re-orders the
remaining stops, and places an automated outbound call so the driver can confirm the
new order **without looking at a screen**.

**Use case:** mid-trip re-route confirmation. Computing a new stop order is easy;
consuming it while driving is not. Waze Voice reads the proposed order, captures
accept / keep-old / skip-a-stop, and hands turn-by-turn to a public [Waze Deep
Link](https://developers.google.com/waze/deeplinks). We are **not** a Waze routing
API — there isn't a public one. The optimizer result is an input; voice confirms it.

**Tracked in Plane:** workspace `demos`, project
[WazeVoiceDemo](http://plane.xgrunt.com/demos/projects/5e523cdf-87e0-47e5-97d5-97d386e40d83/)
(WAZEVOICED-1…8).

**Design & rationale:** [ARCHITECTURE.md](ARCHITECTURE.md) — read this first. It covers the
swappable telephony (§1), where the LLM earns its keep vs. plain IVR (§6–7), telemetry &
retries (§8), the security/scoping model (§9), the config plane (§10), and the
framework/platform decisions — LangChain, AgentCore, OpenTelemetry (§11).

**Diagrams:** [DIAGRAMS.md](DIAGRAMS.md) — Mermaid architecture, call-lifecycle state
machine, and live-call sequence (render on GitHub / VS Code Mermaid preview).

## Layout

```
infra/                 OpenTofu root module (region-parameterized, us-east-1)
  modules/
    data_store/        DynamoDB single table + S3 recordings
    event_bus/         EventBridge custom bus
    guardrail/         Bedrock Guardrail (§9 #4)
    dialog_config/     AppConfig app/env/profile + JSON-schema validator (§10)
    dialog_engine/     DialogTurn Lambda + least-privilege IAM (§2, §9)
    orchestrator/      intake API + EventBridge rule + Step Functions call-job (§8)
    voice_connect/     Amazon Connect (default provider, §1)
    voice_twilio/      Twilio TwiML webhook (swap provider, §1)
src/                   Lambda handlers (importable without AWS for unit tests)
config/                dialog-config.json + its JSON schema (edited without a deploy, §10)
```

## Two planes (§10)

- **Config plane** — `config/dialog-config.json` (prompt, copy, model, knobs). Validated on
  publish; in production, hot-edited via AppConfig with no deploy.
- **Code plane** — `src/` + `infra/`. The `validate()` allowlist in
  `src/dialog_engine/handler.py` is a **security control** and deliberately stays here.

## Prerequisites

- OpenTofu ≥ 1.6 (`tofu`)
- AWS creds for us-east-1 with Bedrock model access enabled
- Confirm the Bedrock inference-profile ID:
  `aws bedrock list-inference-profiles --region us-east-1`

## Usage

```bash
cd infra
cp terraform.tfvars.example terraform.tfvars   # adjust if needed
tofu init
tofu validate
tofu plan
# tofu apply        # provisions Connect etc. — review first

# Swap the voice provider without touching code:
#   voice_provider = "twilio"   in terraform.tfvars, then tofu apply

# Trigger the demo (after apply):
#   curl -X POST "$(tofu output -raw intake_url | sed 's/{routeId}/1042/')"
```

## Tests

```bash
python -m pytest src/dialog_engine/test_handler.py src/connect_adapter/test_handler.py
```

## Status

Scaffold retargeted from the jewelry-pickup persona to Waze Voice re-route confirmation.
`tofu validate` was clean on the original stack; Lambda handlers keep the security
controls (`validate()`, least-privilege projection, forced tool schema). The Bedrock
Converse wiring, Connect contact flow, and Step Functions task-token callback remain
the TODOs marked in the source.

> The Connect contact-flow JSON and the Step Functions ASL are minimal placeholders —
> intentionally, so the graph/flow is real but the behavior is filled in during the
> voice spike (Days 3–4) and orchestration phase (Day 8).
