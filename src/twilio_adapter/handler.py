"""Twilio <-> DialogTurn adapter — §1 (VoiceProvider swap).

Same DialogTurn brain as the Connect adapter, different mouth: a TwiML webhook.
Proves the provider abstraction. Scaffold stub.
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
        "jobId": "job-demo",
        "callerUtterance": (event.get("SpeechResult") or ""),
    })
    twiml = f"<Response><Say>{turn.get('say', '')}</Say></Response>"
    return {
        "statusCode": 200,
        "headers": {"Content-Type": "application/xml"},
        "body": twiml,
    }


def _invoke_dialog(payload) -> dict:
    if not _lambda:
        return {"say": "I reordered your remaining stops.", "action": "END_CALL"}
    r = _lambda.invoke(FunctionName=os.environ["DIALOG_FN"], Payload=json.dumps(payload).encode())
    return json.loads(r["Payload"].read())
