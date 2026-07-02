# Diagrams

Rendered Mermaid views of the system. These render on GitHub and in VS Code with a
Mermaid preview extension. Narrative and rationale live in [ARCHITECTURE.md](ARCHITECTURE.md);
section refs (§) point there.

---

## 1. Architecture

Deployed components plus the swappable voice layer (§1) and telemetry (§8). Solid arrows =
request/data flow; dotted = async events, config reads, and telemetry.

```mermaid
flowchart TB
  OP["Operator / repair system"]

  subgraph ingress["Ingress"]
    APIGW["API Gateway HTTP"]
    INTAKE["λ intake"]
  end

  EB[("EventBridge bus")]
  SFN{{"Step Functions<br/>call-job state machine"}}

  subgraph brain["Dialog engine §2 / §9"]
    DLG["λ dialog<br/>DialogTurn"]
    BR["Bedrock Converse<br/>Claude Haiku 4.5"]
    GR[["Guardrail §9"]]
    DDB[("DynamoDB<br/>jobs / attempts")]
    AC[/"AppConfig<br/>prompt + copy §10"/]
  end

  subgraph voice["Voice provider §1 · swappable"]
    CONNECT["Amazon Connect<br/>contact flow · Polly · Lex"]
    CADAPT["λ connect_adapter"]
    TWILIO["Twilio webhook"]
    TADAPT["λ twilio_adapter"]
  end

  subgraph obs["Telemetry §8"]
    EMF["EMF metrics"]
    XRAY["X-Ray traces"]
    CW["CloudWatch dashboard"]
  end

  OP -->|POST order ready| APIGW --> INTAKE
  INTAKE -.->|RepairOrderCompleted| EB
  EB -.->|rule order-ready| SFN
  SFN -->|PlaceCall task| DLG
  DLG --> BR
  BR -. guardrail in and out .-> GR
  DLG --> DDB
  DLG -. reads .-> AC
  SFN -.->|CallCompleted| EB

  SFN -->|placeCall| CONNECT
  CONNECT -->|Lex code-hook per turn| CADAPT --> DLG
  TWILIO --> TADAPT --> DLG

  DLG -. emits .-> EMF --> CW
  DLG -. traces .-> XRAY --> CW
  SFN -. traces .-> XRAY

  classDef stub stroke-dasharray:4 3,opacity:0.7;
  class CADAPT,TWILIO,TADAPT stub;
```

> Dashed-border nodes (`connect_adapter`, Twilio path) are scaffolded but not yet wired —
> the live-call turn loop (diagram 3) is the target. Only one voice provider is
> instantiated at a time (`voice_provider` var).

---

## 2. Call lifecycle (state machine)

The per-notification Step Functions job (§8). Retryable dispositions loop through backoff;
terminal outcomes end the execution.

```mermaid
stateDiagram-v2
  [*] --> QUEUED
  QUEUED --> DIALING
  DIALING --> RINGING
  DIALING --> FAILED: provider or network
  RINGING --> ANSWERED
  RINGING --> NO_ANSWER
  RINGING --> BUSY
  RINGING --> VOICEMAIL
  ANSWERED --> IN_DIALOG

  IN_DIALOG --> CONFIRMED
  IN_DIALOG --> RESCHEDULE
  IN_DIALOG --> DO_NOT_CALL
  IN_DIALOG --> TRANSFER: to human

  state retry <<choice>>
  NO_ANSWER --> retry
  BUSY --> retry
  FAILED --> retry
  VOICEMAIL --> retry
  retry --> WAIT_BACKOFF: attempts remaining
  retry --> EXHAUSTED: max attempts hit
  WAIT_BACKOFF --> DIALING: quiet-hours aware

  CONFIRMED --> [*]
  RESCHEDULE --> [*]
  DO_NOT_CALL --> [*]
  TRANSFER --> [*]
  EXHAUSTED --> [*]
```

> Idempotency: the Step Functions execution name is the `jobId`, so a duplicate
> `RepairOrderCompleted` can't start a second call for the same order (§8).

---

## 3. Live-call turn loop (sequence) — target

How the Lambdas are invoked during a real call (Phase B). Each caller utterance drives one
`DialogTurn`; the provider resolves the Step Functions task token on a terminal disposition.

```mermaid
sequenceDiagram
  actor Cust as Customer
  participant CN as Amazon Connect
  participant CA as connect_adapter
  participant DL as dialog
  participant BR as Bedrock + Guardrail
  participant SF as Step Functions

  SF->>CN: placeCall (StartOutboundVoiceContact)
  CN->>Cust: rings + Polly opener
  loop until terminal action
    Cust-->>CN: speaks
    CN->>CA: Lex code-hook (utterance)
    CA->>DL: DialogTurn jobId + utterance
    DL->>BR: Converse (forced tool + guardrail)
    BR-->>DL: say + action
    DL-->>CA: validated say + action
    CA-->>CN: speak (Polly) + collect next
  end
  CN-->>SF: resolve task token (disposition)
  SF->>SF: EvaluateOutcome then retry or Done
```

> Provider swap (§1): with `voice_provider = "twilio"`, replace Connect + `connect_adapter`
> with a Twilio webhook then `twilio_adapter` then the same `dialog` Lambda. Same brain, different mouth.
