"""DialogTurn engine — §2 (constrained actions), §9 (safety), §10 (config).

One constrained Bedrock Converse call per turn:
  least-privilege context -> Converse(forced tool schema + guardrail) -> validate() -> action

Boto3 is imported defensively so the file stays importable (and unit-testable on
validate()) without AWS. When boto3/creds are absent, deterministic fallbacks keep
the pipeline green.
"""
import json
import os
import re
import time
import urllib.request

try:
    import boto3
    _bedrock = boto3.client("bedrock-runtime")
    _ddb = boto3.resource("dynamodb")
except Exception:  # no boto3 / no region in local dev
    _bedrock = None
    _ddb = None


# --- §9 #6: output validation is a SECURITY control -> stays in code, never in config ---
ALLOWED_ACTIONS = {
    "CONTINUE", "COLLECT_DTMF", "ACCEPT_REROUTE", "KEEP_CURRENT_ROUTE",
    "SKIP_STOP", "MARK_DO_NOT_CALL", "TRANSFER_TO_HUMAN", "END_CALL",
}
_CARD = re.compile(r"\b(?:\d[ -]?){13,16}\b")


def validate(turn: dict) -> dict:
    """Backstop before anything reaches TTS. Fail closed to a human transfer."""
    if turn.get("action") not in ALLOWED_ACTIONS:
        return _safe_transfer()
    if _CARD.search(turn.get("say", "")) or "SSN" in turn.get("say", ""):
        return _safe_transfer()
    return turn


def _safe_transfer() -> dict:
    return {"say": "Let me get a team member to help you.", "action": "TRANSFER_TO_HUMAN"}


# --- §10: behaviour (prompt/copy/knobs) from AppConfig at runtime, cached by the extension ---
def load_config() -> dict:
    app = os.environ.get("APPCONFIG_APP", "")
    env = os.environ.get("APPCONFIG_ENV", "")
    prof = os.environ.get("APPCONFIG_PROFILE", "")
    url = f"http://localhost:2772/applications/{app}/environments/{env}/configurations/{prof}"
    try:
        with urllib.request.urlopen(url, timeout=1) as r:  # AppConfig Lambda extension
            return json.load(r)
    except Exception:
        return _DEFAULT_CONFIG  # local/dev fallback (extension layer not attached yet)


_DEFAULT_CONFIG = {
    "model_id": os.environ.get("BEDROCK_MODEL_ID", "us.anthropic.claude-haiku-4-5-20251001-v1:0"),
    "max_turns": 6,
    "system_prompt": (
        "You handle ONLY this one disrupted route for {driver_first_name}. An incident "
        "({incident_summary}) invalidates the old stop order. Tell them the proposed order "
        "({remaining_stops}), capture accept / keep-the-old-order / skip-a-stop, and never "
        "disclose home, work, school street addresses, or coordinates. For anything unrelated, "
        "deflect or transfer."
    ),
    "copy": {
        "opener": (
            "Hi {driver_first_name}, this is Waze. {incident_summary}. I reordered your "
            "remaining stops — {proposed_next_stop} first. Press 1 to take it, or stay on the line."
        ),
        "deflect": "I can only help with this re-route.",
        "confirm": "Got it — take {proposed_next_stop} first. I've sent the next stop to Waze. Drive safe.",
    },
}


class _SafeDict(dict):
    """format_map helper: leave unknown {placeholders} intact instead of KeyError."""
    def __missing__(self, key):
        return "{" + key + "}"


# --- §9 #1: least-privilege context — a PROJECTION, sensitive fields never fetched ---
# Stop *names* only. Home/work/school street addresses and lat/long are NEVER loaded,
# so no prompt trick can extract a coordinate that was never in the window.
_ALLOWED_FIELDS = (
    "driver_first_name, route_name, incident_summary, delay_minutes, "
    "current_next_stop, proposed_next_stop, remaining_stops, proposed_eta"
)
_STUB_CONTEXT = {
    "driver_first_name": "Sam",
    "route_name": "afternoon errands",
    "incident_summary": "a crash closed Lincoln Avenue",
    "delay_minutes": "18",
    "current_next_stop": "Lincoln Pharmacy",
    "proposed_next_stop": "Oak Street school pickup",
    "remaining_stops": "school pickup, then the pharmacy via 4th Street, then home",
    "proposed_eta": "3:40 this afternoon",
}


def load_context(job_id: str) -> dict:
    # home/work/school street addresses, coordinates, and other routes are NEVER in
    # the projection, so no prompt trick can extract what was never loaded.
    if not _ddb or not job_id:
        return _STUB_CONTEXT
    try:
        table = _ddb.Table(os.environ["TABLE_NAME"])
        resp = table.get_item(
            Key={"PK": f"job#{job_id}", "SK": "meta"},
            ProjectionExpression=_ALLOWED_FIELDS,
        )
        return resp.get("Item") or _STUB_CONTEXT
    except Exception:
        return _STUB_CONTEXT


# --- §9 #2: constrained action space — the model can only return this schema ---
TOOL = {
    "toolSpec": {
        "name": "decide_turn",
        "description": "Choose the next action for the mid-trip re-route confirmation call.",
        "inputSchema": {"json": {
            "type": "object",
            "properties": {
                "say": {"type": "string"},
                "action": {"type": "string", "enum": sorted(ALLOWED_ACTIONS)},
            },
            "required": ["say", "action"],
            "additionalProperties": False,
        }},
    }
}


def _run_model(cfg: dict, ctx: dict, utterance: str):
    """Single constrained Converse call. Returns (unvalidated {say, action}, meta)."""
    meta = {"guardrail_blocked": 0, "converse_failed": 0, "in_tokens": 0, "out_tokens": 0}
    if not _bedrock:
        opener = cfg.get("copy", {}).get("opener", "I reordered your remaining stops.")
        return {"say": opener.format_map(_SafeDict(ctx)), "action": "ACCEPT_REROUTE"}, meta

    system_text = cfg["system_prompt"].format_map(_SafeDict(ctx))
    try:
        resp = _bedrock.converse(
            modelId=cfg["model_id"],
            system=[{"text": system_text}],
            # §9 #5: caller speech is UNTRUSTED — wrapped in guardContent, kept in the
            # user turn as data, never concatenated into instructions.
            messages=[{"role": "user", "content": [
                {"guardContent": {"text": {"text": utterance or "(the driver just answered)"}}},
            ]}],
            # §9 #2: forced tool — the only legal output shape.
            toolConfig={"tools": [TOOL], "toolChoice": {"tool": {"name": "decide_turn"}}},
            # §9 #4: guardrail on input (guardContent) and output.
            guardrailConfig={
                "guardrailIdentifier": os.environ["GUARDRAIL_ID"],
                "guardrailVersion": os.environ["GUARDRAIL_VERSION"],
                "trace": "enabled",
            },
            inferenceConfig={"maxTokens": 300},
        )
    except Exception as e:  # e.g. model access not yet enabled — log & fall back
        print(json.dumps({"level": "error", "msg": "converse_failed", "error": str(e)}))
        meta["converse_failed"] = 1
        return {"say": cfg.get("copy", {}).get("deflect", "I can only help with this re-route."),
                "action": "TRANSFER_TO_HUMAN"}, meta

    usage = resp.get("usage", {})
    meta["in_tokens"] = usage.get("inputTokens", 0)
    meta["out_tokens"] = usage.get("outputTokens", 0)

    if resp.get("stopReason") == "guardrail_intervened":
        print(json.dumps({"level": "warn", "msg": "guardrail_intervened",
                          "trace": resp.get("trace", {}).get("guardrail")}, default=str))
        meta["guardrail_blocked"] = 1
        return {"say": cfg.get("copy", {}).get("deflect", "I can only help with this re-route."),
                "action": "TRANSFER_TO_HUMAN"}, meta

    for block in resp.get("output", {}).get("message", {}).get("content", []):
        tu = block.get("toolUse")
        if tu and tu.get("name") == "decide_turn":
            return tu.get("input", {}), meta
    return _safe_transfer(), meta


def _emit_metrics(action: str, meta: dict) -> None:
    """CloudWatch EMF (§8) — one structured log becomes metrics, no metrics API call."""
    try:
        ts = int(time.time() * 1000)
    except Exception:
        ts = 0
    print(json.dumps({
        "_aws": {
            "Timestamp": ts,
            "CloudWatchMetrics": [{
                "Namespace": "VoiceDemo",
                "Dimensions": [["Provider"], ["Provider", "Action"]],
                "Metrics": [
                    {"Name": "DialogTurn", "Unit": "Count"},
                    {"Name": "GuardrailBlocked", "Unit": "Count"},
                    {"Name": "ConverseFailed", "Unit": "Count"},
                    {"Name": "InputTokens", "Unit": "Count"},
                    {"Name": "OutputTokens", "Unit": "Count"},
                ],
            }],
        },
        "Provider": os.environ.get("VOICE_PROVIDER", "connect"),
        "Action": action,
        "DialogTurn": 1,
        "GuardrailBlocked": meta.get("guardrail_blocked", 0),
        "ConverseFailed": meta.get("converse_failed", 0),
        "InputTokens": meta.get("in_tokens", 0),
        "OutputTokens": meta.get("out_tokens", 0),
    }))


def _extract(event: dict, key: str):
    """Accept both a flat payload and the EventBridge envelope (detail.*)."""
    if key in event:
        return event[key]
    return (event.get("detail") or {}).get(key)


def lambda_handler(event, _context):
    """event: {jobId, callerUtterance} (flat or under .detail). -> validated {say, action}."""
    job_id = _extract(event, "jobId") or ""
    utterance = _extract(event, "callerUtterance") or ""
    cfg = load_config()
    ctx = load_context(job_id)
    turn, meta = _run_model(cfg, ctx, utterance)
    final = validate(turn)  # §9 #6 backstop
    if final.get("action") in {"ACCEPT_REROUTE", "SKIP_STOP"}:
        # Deep Link is a code-plane handoff, never loaded into the model context.
        final = dict(final)
        final["nextStopWazeLink"] = os.environ.get(
            "NEXT_STOP_WAZE_LINK",
            "https://waze.com/ul?ll=40.758895,-73.985131&navigate=yes&utm_source=waze-voice-demo",
        )
    _emit_metrics(final.get("action", "UNKNOWN"), meta)
    return final
