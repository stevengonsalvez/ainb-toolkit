#!/usr/bin/env python3
"""Deterministic policy for Godmode programme state.

The driver remains responsible for work execution. This script makes the
state-machine decisions that must not depend on prose instructions alone.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any


HARD_STOPS = {"budget", "deadline", "security", "production_safety", "authority"}
MODES = {"finite", "perpetual"}
APPROVAL_POLICIES = {"none", "roadmap"}


def load(path: str) -> dict[str, Any]:
    value = json.loads(Path(path).read_text())
    if not isinstance(value, dict):
        raise ValueError("state must be a JSON object")
    return value


def fail(message: str) -> None:
    print(message, file=sys.stderr)
    raise SystemExit(2)


def mode_of(state: dict[str, Any]) -> str:
    mode = state.get("mode", "finite")
    if mode not in MODES:
        fail("mode must be finite or perpetual")
    return mode


def validate(state: dict[str, Any]) -> None:
    if not state.get("phase"):
        fail("state requires phase")
    if not (state.get("epics") or state.get("dashboard_slug")):
        fail("state requires epics or dashboard_slug")

    mode = mode_of(state)
    approval = state.get("approval_policy", "roadmap")
    if approval not in APPROVAL_POLICIES:
        fail("approval_policy must be none or roadmap")
    if mode == "perpetual" and approval == "none" and state.get("human_gate") == "pending":
        fail("perpetual programmes with approval_policy none cannot wait at human_gate")

    termination = state.get("termination", {})
    if not isinstance(termination, dict):
        fail("termination must be an object")
    if mode == "perpetual" and termination.get("backlog_dry"):
        fail("perpetual programmes cannot enable backlog_dry termination")
    reason = termination.get("reason")
    if reason is not None and reason not in HARD_STOPS:
        fail("termination reason must be a hard-stop reason")

    lanes = state.get("lanes", {})
    if not isinstance(lanes, dict):
        fail("lanes must be an object")
    mutation = lanes.get("mutation", {})
    if mutation and not isinstance(mutation, dict):
        fail("lanes.mutation must be an object")
    owner = mutation.get("owner") if isinstance(mutation, dict) else None
    if owner is not None and not isinstance(owner, str):
        fail("lanes.mutation.owner must be a string or null")

    quorum = state.get("creative_quorum", {})
    if quorum and not isinstance(quorum, dict):
        fail("creative_quorum must be an object")
    if isinstance(quorum, dict) and quorum.get("status") == "ready":
        models = quorum.get("models", [])
        if not isinstance(models, list) or len(set(models)) < 2:
            fail("creative_quorum ready requires two distinct models")


def next_action(state: dict[str, Any]) -> dict[str, str]:
    validate(state)
    termination = state.get("termination", {})
    reason = termination.get("reason")
    if reason in HARD_STOPS:
        return {"action": "halt", "reason": reason}

    for incident in state.get("incidents", []):
        if isinstance(incident, dict) and incident.get("status") == "confirmed":
            return {"action": "repair", "reason": incident.get("id", "confirmed_defect")}

    lanes = state.get("lanes", {})
    regression = lanes.get("regression", {}) if isinstance(lanes, dict) else {}
    if isinstance(regression, dict) and regression.get("status") in {"queued", "failed"}:
        return {"action": "run_regression", "reason": "cumulative_regression"}
    if str(state.get("phase", "")).endswith("_SHIP"):
        return {"action": "run_regression", "reason": "post_epic_ship"}

    if mode_of(state) == "perpetual":
        discovery = lanes.get("discovery", {}) if isinstance(lanes, dict) else {}
        if isinstance(discovery, dict) and discovery.get("status") == "backoff":
            return {"action": "research", "reason": "adaptive_backoff"}
        return {"action": "discover", "reason": "perpetual_progression"}

    if termination.get("backlog_dry"):
        return {"action": "complete", "reason": "finite_backlog_dry"}
    return {"action": "select_epic", "reason": "finite_backlog_open"}


def creative_route(request: dict[str, Any]) -> dict[str, Any]:
    host = request.get("host")
    models = request.get("models", [])
    if host not in {"claude", "codex", "copilot"}:
        fail("host must be claude, codex, or copilot")
    if not isinstance(models, list) or any(not isinstance(model, str) for model in models):
        fail("models must be a list of model identifiers")
    available = list(dict.fromkeys(models))

    def pick(prefix: str) -> str | None:
        return next((model for model in available if model.startswith(prefix)), None)

    if host == "claude":
        preferred = [pick("claude:"), pick("codex:")]
    elif host == "codex":
        preferred = [pick("codex:"), pick("claude:")]
    else:
        copilot = [model for model in available if model.startswith("copilot:")]
        preferred = copilot[:2] if len(copilot) >= 2 else copilot + [pick("claude:"), pick("codex:")]

    selected = []
    for model in preferred + available:
        if model and model not in selected:
            selected.append(model)
        if len(selected) == 2:
            break
    if len(selected) < 2:
        return {"status": "deferred", "host": host, "reason": "creative_quorum_unavailable"}
    return {"status": "ready", "host": host, "models": selected}


def main() -> None:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("validate-state", "next-action"):
        command = sub.add_parser(name)
        command.add_argument("state")
    route = sub.add_parser("creative-route")
    route.add_argument("availability")
    args = parser.parse_args()

    if args.command == "validate-state":
        validate(load(args.state))
        return
    if args.command == "next-action":
        print(json.dumps(next_action(load(args.state)), sort_keys=True))
        return
    print(json.dumps(creative_route(load(args.availability)), sort_keys=True))


if __name__ == "__main__":
    main()
