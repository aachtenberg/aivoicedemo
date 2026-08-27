"""Ingress / simulator — §2. 'Route disrupted' -> RouteDisrupted event.

POST /routes/{routeId}/disrupted  ->  EventBridge RouteDisrupted
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
    route_id = (event.get("pathParameters") or {}).get("routeId", "unknown")
    detail = {"jobId": f"job-{route_id}", "routeId": route_id}
    if _events:
        _events.put_events(Entries=[{
            "Source": "voicedemo.simulator",
            "DetailType": "RouteDisrupted",
            "Detail": json.dumps(detail),
            "EventBusName": os.environ.get("EVENT_BUS_NAME", "default"),
        }])
    return {"statusCode": 202, "body": json.dumps({"queued": detail["jobId"]})}
