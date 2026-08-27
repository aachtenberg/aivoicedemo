"""Unit tests for the Lex V2 code-hook mapping (no AWS needed)."""
import handler


def _event(utterance, job="job-1"):
    return {
        "inputTranscript": utterance,
        "sessionState": {
            "sessionAttributes": {"jobId": job},
            "intent": {"name": "FallbackIntent"},
        },
    }


def _patch_dialog(monkeypatch, action, say="ok"):
    monkeypatch.setattr(handler, "_invoke_dialog", lambda p: {"say": say, "action": action})


def test_continue_keeps_listening(monkeypatch):
    _patch_dialog(monkeypatch, "CONTINUE", "go on")
    out = handler.lambda_handler(_event("tell me more"), None)
    assert out["sessionState"]["dialogAction"]["type"] == "ElicitIntent"
    assert out["messages"][0]["content"] == "go on"
    assert "finalAction" not in out["sessionState"]["sessionAttributes"]


def test_terminal_closes_and_flags_action(monkeypatch):
    _patch_dialog(monkeypatch, "ACCEPT_REROUTE", "take the school pickup first")
    out = handler.lambda_handler(_event("yes take the new order"), None)
    assert out["sessionState"]["dialogAction"]["type"] == "Close"
    assert out["sessionState"]["sessionAttributes"]["finalAction"] == "ACCEPT_REROUTE"
    assert out["sessionState"]["sessionAttributes"]["jobId"] == "job-1"


def test_transfer_is_terminal(monkeypatch):
    _patch_dialog(monkeypatch, "TRANSFER_TO_HUMAN", "one moment")
    out = handler.lambda_handler(_event("what's my card number"), None)
    assert out["sessionState"]["dialogAction"]["type"] == "Close"
    assert out["sessionState"]["sessionAttributes"]["finalAction"] == "TRANSFER_TO_HUMAN"
