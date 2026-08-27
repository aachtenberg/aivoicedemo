"""Unit tests for the §9 #6 output validator — the security backstop.

These run without AWS. If validate() ever gets weaker, these fail.
"""
import handler


def test_allows_sanctioned_action():
    turn = {"say": "Take the school pickup first.", "action": "ACCEPT_REROUTE"}
    assert handler.validate(turn) == turn


def test_rejects_unknown_action():
    turn = {"say": "ok", "action": "process_payment"}
    assert handler.validate(turn)["action"] == "TRANSFER_TO_HUMAN"


def test_blocks_card_number_in_speech():
    turn = {"say": "Your card is 4111 1111 1111 1111", "action": "ACCEPT_REROUTE"}
    assert handler.validate(turn)["action"] == "TRANSFER_TO_HUMAN"


def test_tool_enum_matches_allowlist():
    enum = set(handler.TOOL["toolSpec"]["inputSchema"]["json"]["properties"]["action"]["enum"])
    assert enum == handler.ALLOWED_ACTIONS


def test_accept_attaches_waze_deep_link():
    out = handler.lambda_handler({"jobId": "job-1042", "callerUtterance": ""}, None)
    assert out["action"] == "ACCEPT_REROUTE"
    assert out["nextStopWazeLink"].startswith("https://waze.com/ul?")
    assert "utm_source=waze-voice-demo" in out["nextStopWazeLink"]
    # Coords are a public landmark from Waze's own docs, never in the LLM projection.
    assert "nextStopWazeLink" not in handler._STUB_CONTEXT
    assert "40.758895" not in " ".join(str(v) for v in handler._STUB_CONTEXT.values())


def test_stub_context_has_no_coordinates():
    blob = " ".join(str(v) for v in handler._STUB_CONTEXT.values()).lower()
    assert "school pickup" in blob  # stop *name* is in-scope
    for token in ("ll=", "latitude", "longitude", "@", "card"):
        assert token not in blob
    import re
    assert not re.search(r"\b\d{1,5}\s+\w+\s+(st|street|ave|rd|road)\b", blob)
    assert not re.search(r"-?\d{1,3}\.\d+,\s*-?\d{1,3}\.\d+", blob)
