"""Connect <-> DialogTurn adapter — §1 (VoiceProvider swap).

Translates a Connect/Lex code-hook event into the canonical DialogTurn call,
then maps the {say, action} result back into a contact-flow/Lex response.
Scaffold stub; wired Days 3-4.
"""
import json
import os

try:
    import boto3
    _lambda = boto3.client("lambda")
except Exception:
    _lambda = None


def lambda_handler(event, _context):
    turn = _invoke_dialog({
        "jobId": event.get("jobId", ""),
        "callerUtterance": _extract_utterance(event),
    })
    # TODO(day3): shape into the Lex/contact-flow response the code-hook expects.
    return {"say": turn.get("say", ""), "action": turn.get("action", "END_CALL")}


def _extract_utterance(event) -> str:
    # Connect/Lex put transcribed speech in different places depending on flow.
    return (event.get("inputTranscript") or "")


def _invoke_dialog(payload) -> dict:
    if not _lambda:
        return {"say": "", "action": "END_CALL"}
    r = _lambda.invoke(FunctionName=os.environ["DIALOG_FN"], Payload=json.dumps(payload).encode())
    return json.loads(r["Payload"].read())
