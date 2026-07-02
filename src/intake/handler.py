"""Ingress / simulator — §2. 'Mark order ready' -> RepairOrderCompleted event.

POST /orders/{orderId}/ready  ->  EventBridge RepairOrderCompleted
An EventBridge rule then starts ONE Step Functions execution per job (§8),
using jobId as the execution name for idempotency (a duplicate event can't
place a second call).
"""
import json
import os

try:
    import boto3
    _events = boto3.client("events")
except Exception:  # importable without boto3 in local dev
    _events = None


def lambda_handler(event, _context):
    order_id = (event.get("pathParameters") or {}).get("orderId", "unknown")
    detail = {"jobId": f"job-{order_id}", "orderId": order_id}
    if _events:
        _events.put_events(Entries=[{
            "Source": "voicedemo.simulator",
            "DetailType": "RepairOrderCompleted",
            "Detail": json.dumps(detail),
            "EventBusName": os.environ.get("EVENT_BUS_NAME", "default"),
        }])
    return {"statusCode": 202, "body": json.dumps({"queued": detail["jobId"]})}
