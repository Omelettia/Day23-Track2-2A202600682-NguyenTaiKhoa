"""Tests for the AgentOps harness + the B3 extension (hallucinated-tool failure mode).

Runs with or without pytest:
    python BONUS-agentops/test_agentops.py     # standalone
    pytest BONUS-agentops/test_agentops.py      # if pytest installed
"""
from __future__ import annotations

import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
from agent_run import TASKS, detect_loop, run_task  # noqa: E402


def test_detect_loop_true():
    assert detect_loop([("a", 1), ("a", 1), ("a", 1)]) is True


def test_detect_loop_false():
    assert detect_loop([("a", 1), ("b", 2), ("a", 1)]) is False


def test_success_task_has_no_failure_modes():
    rec = run_task(TASKS[0], tracer=None)
    assert rec["success"] is True
    assert rec["failure_modes"] == []


def test_tool_error_task_flags_tool_error():
    rec = run_task(TASKS[1], tracer=None)  # has the flaky "inventory" 503 tool
    assert rec["tool_errors"] >= 1
    assert "tool-error" in rec["failure_modes"]


def test_loop_task_flags_loop_and_failed():
    rec = run_task(TASKS[2], tracer=None)
    assert rec["looped"] is True
    assert "loop/no-progress" in rec["failure_modes"]
    assert "task-failed" in rec["failure_modes"]


def test_hallucinated_tool_detected():
    # The B3 extension task (index 3) calls "refund", which is not in the registry.
    rec = run_task(TASKS[3], tracer=None)
    assert rec["hallucinated_tool_calls"] >= 1
    assert "hallucinated-tool" in rec["failure_modes"]
    assert rec["success"] is False


if __name__ == "__main__":
    tests = [v for k, v in sorted(globals().items())
             if k.startswith("test_") and callable(v)]
    failed = 0
    for fn in tests:
        try:
            fn()
            print(f"PASS  {fn.__name__}")
        except AssertionError as e:
            failed += 1
            print(f"FAIL  {fn.__name__}: {e}")
    print(f"\n{len(tests) - failed}/{len(tests)} passed")
    sys.exit(1 if failed else 0)
