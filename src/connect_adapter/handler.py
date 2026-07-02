"""Connect <-> DialogTurn adapter — §1, Phase B (interactive turn loop).

This is an Amazon Lex V2 **code hook**. Lex is used only as the speech pipe: a single
FallbackIntent catches every caller utterance and Lex calls this Lambda with the raw
transcript. We hand that to the Bedrock dialog engine (the actual brain) and translate
its {say, action} back into a Lex V2 response that either:
  - keeps listening (ElicitIntent) for CONTINUE / COLLECT_DTMF, or
  - closes the Lex session (Close) for a terminal action, stashing `finalAction` in
    session attributes so the Connect contact flow can branch (disconnect / transfer).

`jobId` arrives as a Lex session attribute (set by the contact flow from the outbound
call's contact attributes). Importable without boto3 for unit tests.
"""
import json
import os

try:
    import boto3
    _lambda = boto3.client("lambda")
except Exception:
    _lambda = None

_CONTINUE = {"CONTINUE", "COLLECT_DTMF"}


def lambda_handler(event, _context):
    ss = event.get("sessionState", {}) or {}
    attrs = dict(ss.get("sessionAttributes") or {})
    intent_name = ((ss.get("intent") or {}).get("name")) or "FallbackIntent"

    turn = _invoke_dialog({
        "jobId": attrs.get("jobId", ""),
        "callerUtterance": event.get("inputTranscript", "") or "",
    })
    say = turn.get("say", "")
    action = turn.get("action", "END_CALL")

    if action in _CONTINUE:
        return _elicit(attrs, say)                 # speak + keep listening
    attrs["finalAction"] = action                  # contact flow branches on this
    return _close(attrs, intent_name, say)         # speak + end Lex session


def _elicit(attrs, say):
    return {
        "sessionState": {
            "sessionAttributes": attrs,
            "dialogAction": {"type": "ElicitIntent"},
        },
        "messages": [{"contentType": "PlainText", "content": say}],
    }


def _close(attrs, intent_name, say):
    return {
        "sessionState": {
            "sessionAttributes": attrs,
            "dialogAction": {"type": "Close"},
            "intent": {"name": intent_name, "state": "Fulfilled"},
        },
        "messages": [{"contentType": "PlainText", "content": say}],
    }


def _invoke_dialog(payload):
    if not _lambda:
        return {"say": "", "action": "END_CALL"}
    r = _lambda.invoke(FunctionName=os.environ["DIALOG_FN"], Payload=json.dumps(payload).encode())
    return json.loads(r["Payload"].read())
