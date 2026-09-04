"""End-to-end checks for scripts/check-agentskills-conformance.

Two things must hold for the check to be worth running in CI:
the whole skills tree passes, and the script actually fails on a
deliberately broken fixture rather than passing everything.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "scripts" / "check-agentskills-conformance"
FIXTURES = REPO_ROOT / "tests" / "fixtures" / "agentskills"


def run_check(*roots: Path, as_json: bool = False) -> subprocess.CompletedProcess[str]:
    argv = [sys.executable, str(SCRIPT)]
    if as_json:
        argv.append("--json")
    argv.extend(str(root) for root in roots)
    return subprocess.run(argv, cwd=REPO_ROOT, capture_output=True, text=True)


def test_every_shipped_skill_conforms() -> None:
    result = run_check(REPO_ROOT / "skills")
    assert result.returncode == 0, result.stdout + result.stderr


SHIPPED_SKILL_COUNT = 94


def count_skill_dirs() -> int:
    """Count skill directories without reusing the script's own glob.

    The script globs ``*/SKILL.md``. Asserting against that same expression
    proves nothing, so this walks the directory listing instead.
    """
    skills = REPO_ROOT / "skills"
    return sum(
        1
        for entry in os.listdir(skills)
        if (skills / entry).is_dir() and (skills / entry / "SKILL.md").is_file()
    )


def test_shipped_skill_count_is_scanned() -> None:
    result = run_check(REPO_ROOT / "skills", as_json=True)
    payload = json.loads(result.stdout)
    on_disk = count_skill_dirs()
    # Pinned so silently dropping a skill fails here too, not only the ratio.
    # Bump it deliberately in the same commit that adds or removes a skill.
    assert on_disk == SHIPPED_SKILL_COUNT
    assert payload["scanned"] == on_disk
    assert payload["violations"] == {}


def test_clean_fixture_passes() -> None:
    result = run_check(FIXTURES / "clean")
    assert result.returncode == 0, result.stdout + result.stderr


def test_broken_fixture_fails() -> None:
    result = run_check(FIXTURES / "broken")
    assert result.returncode == 1, result.stdout + result.stderr


@pytest.mark.parametrize(
    ("skill", "expected"),
    [
        ("bad_Name", "must be lowercase alphanumeric"),
        ("dir-mismatch", "does not match its directory"),
        ("long-description", "limit is 1024"),
        ("underscore-tools", "must be spelled 'allowed-tools'"),
        ("no-frontmatter", "missing YAML frontmatter"),
    ],
)
def test_each_rule_fires_on_its_fixture(skill: str, expected: str) -> None:
    result = run_check(FIXTURES / "broken", as_json=True)
    payload = json.loads(result.stdout)
    key = f"{FIXTURES / 'broken' / skill / 'SKILL.md'}"
    assert key in payload["violations"], payload["violations"]
    assert any(expected in message for message in payload["violations"][key])


def test_missing_root_is_a_usage_error() -> None:
    result = run_check(REPO_ROOT / "does-not-exist")
    assert result.returncode == 2
    assert "not a directory" in result.stderr
