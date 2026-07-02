"""Unit tests for the §9 #6 output validator — the security backstop.

These run without AWS. If validate() ever gets weaker, these fail.
"""
import handler


def test_allows_sanctioned_action():
    turn = {"say": "Your watch is ready.", "action": "CONFIRM_PICKUP"}
    assert handler.validate(turn) == turn


def test_rejects_unknown_action():
    turn = {"say": "ok", "action": "process_payment"}
    assert handler.validate(turn)["action"] == "TRANSFER_TO_HUMAN"


def test_blocks_card_number_in_speech():
    turn = {"say": "Your card is 4111 1111 1111 1111", "action": "CONFIRM_PICKUP"}
    assert handler.validate(turn)["action"] == "TRANSFER_TO_HUMAN"


def test_tool_enum_matches_allowlist():
    enum = set(handler.TOOL["toolSpec"]["inputSchema"]["json"]["properties"]["action"]["enum"])
    assert enum == handler.ALLOWED_ACTIONS
