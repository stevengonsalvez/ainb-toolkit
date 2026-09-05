"""End-to-end checks for the QE pack's generated Backstage catalogue.

What has to hold for the catalogue to be trustworthy in CI:
the committed files match what the generator produces, every skill and agent
in the pack has an entity, every source-location resolves to real files at a
real commit, the eval annotation matches eval-score.json, the drift check
really fails when the pack changes, the Backstage validator really rejects a
broken entity, and the skills index matches the pack.
"""

from __future__ import annotations

import json
import re
import shutil
import subprocess
import sys
from pathlib import Path
from urllib.parse import urlparse

import pytest
import yaml

REPO_ROOT = Path(__file__).resolve().parents[2]
PACK = REPO_ROOT / "packages" / "qe-agent-pack"
GENERATOR = REPO_ROOT / "scripts" / "generate-backstage-catalog"
VALIDATOR = REPO_ROOT / "scripts" / "validate-backstage-catalog"
CATALOG = PACK / "catalog-info.yaml"
SKILLS_INDEX = PACK / ".well-known" / "skills" / "index.json"
INVALID_FIXTURE = REPO_ROOT / "tests" / "fixtures" / "backstage" / "invalid-catalog-info.yaml"
CATALOG_MODEL = REPO_ROOT / "node_modules" / "@backstage" / "catalog-model"

SKILL_NAME_RE = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")


def run_generator(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(GENERATOR), *args], cwd=REPO_ROOT, capture_output=True, text=True
    )


def run_validator(*files: Path) -> subprocess.CompletedProcess[str]:
    if not CATALOG_MODEL.is_dir():
        pytest.skip("run `npm ci` first: @backstage/catalog-model is not installed")
    return subprocess.run(
        ["node", str(VALIDATOR), *map(str, files)], cwd=REPO_ROOT, capture_output=True, text=True
    )


def entities() -> list[dict]:
    return [doc for doc in yaml.safe_load_all(CATALOG.read_text()) if doc]


def frontmatter(path: Path) -> dict:
    text = path.read_text()
    return yaml.safe_load(text[4 : text.index("\n---", 4)])


def skill_dirs() -> list[Path]:
    return sorted(p for p in (PACK / ".apm" / "skills").iterdir() if p.is_dir())


def agent_files() -> list[Path]:
    return sorted((PACK / ".apm" / "agents").glob("*.agent.md"))


def source_location(entity: dict) -> tuple[str, str]:
    """Return (sha, repo path) from the backstage.io/source-location annotation."""
    value = entity["metadata"]["annotations"]["backstage.io/source-location"]
    assert value.startswith("url:https://github.com/stevengonsalvez/ainb-toolkit/")
    parts = urlparse(value[len("url:"):]).path.strip("/").split("/")
    # /<owner>/<repo>/<tree|blob>/<sha>/<path...>
    assert parts[2] in ("tree", "blob")
    sha = parts[3]
    assert re.fullmatch(r"[0-9a-f]{40}", sha)
    return sha, "/".join(parts[4:])


# Committed output ------------------------------------------------------------


def test_committed_catalog_matches_generator_output() -> None:
    result = run_generator("--check")
    assert result.returncode == 0, result.stdout + result.stderr


def test_one_ai_resource_per_skill_and_agent() -> None:
    ai = {e["metadata"]["name"] for e in entities() if e["kind"] == "AiResource"}
    expected = {d.name for d in skill_dirs()} | {
        f.name[: -len(".agent.md")] for f in agent_files()
    }
    assert ai == expected
    assert len(expected) == 8


def test_agents_are_skills_in_the_agent_category() -> None:
    by_name = {e["metadata"]["name"]: e for e in entities()}
    for agent_file in agent_files():
        entity = by_name[agent_file.name[: -len(".agent.md")]]
        assert entity["spec"]["type"] == "skill"
        assert "agent" in entity["spec"]["categories"]


def test_system_and_mcp_api_entities_exist() -> None:
    kinds = {(e["kind"], e["metadata"]["name"]) for e in entities()}
    assert ("System", "qe-agent-pack") in kinds
    assert ("API", "playwright-test") in kinds
    api = next(e for e in entities() if e["kind"] == "API")
    assert api["spec"]["type"] == "mcp-server"
    assert api["spec"]["remotes"] == [
        {"type": "stdio", "url": "npx playwright run-test-mcp-server"}
    ]


def test_playwright_agents_declare_their_mcp_dependency() -> None:
    for entity in entities():
        name = entity["metadata"]["name"]
        servers = entity["metadata"]["annotations"].get("wololo.dev/mcp-servers")
        if name.startswith("playwright-test-"):
            assert servers == "playwright-test"
        elif entity["kind"] == "AiResource":
            assert servers is None


def test_eval_annotation_matches_eval_score_json() -> None:
    score = json.loads((PACK / "eval-score.json").read_text())
    for entity in entities():
        payload = json.loads(entity["metadata"]["annotations"]["wololo.dev/eval-score"])
        assert payload["metrics"] == score["metrics"]
        assert payload["source"] == score["source"]
        assert payload["recorded"] == score["recorded"]
        assert payload["verdict"] == score["verdict"]
    assert score["metrics"]["mutation_kill_rate"]["candidate"] == 0.3012
    assert score["metrics"]["seeded_defects_caught"]["candidate"] == 0.3636


def test_source_locations_resolve_to_real_files_at_one_commit() -> None:
    shas = set()
    for entity in entities():
        sha, path = source_location(entity)
        shas.add(sha)
        if entity["kind"] == "System":
            assert path == "packages/qe-agent-pack"
        resolved = subprocess.run(
            ["git", "cat-file", "-e", f"{sha}:{path}"], cwd=REPO_ROOT, capture_output=True, text=True
        )
        assert resolved.returncode == 0, f"{entity['metadata']['name']}: {sha}:{path} {resolved.stderr}"
    assert len(shas) == 1, "every entity must share the provenance commit"


def test_skill_source_location_points_at_the_skill_directory() -> None:
    by_name = {e["metadata"]["name"]: e for e in entities()}
    sha, path = source_location(by_name["expect-test"])
    assert path == "packages/qe-agent-pack/.apm/skills/expect-test"
    listing = subprocess.run(
        ["git", "ls-tree", "--name-only", f"{sha}:{path}"], cwd=REPO_ROOT, capture_output=True, text=True
    )
    assert "SKILL.md" in listing.stdout.split()


# Drift check -------------------------------------------------------------------


@pytest.fixture
def pack_copy(tmp_path: Path) -> Path:
    copy = tmp_path / "qe-agent-pack"
    shutil.copytree(PACK, copy)
    return copy


def test_check_passes_on_a_faithful_copy_and_fails_after_adding_a_skill(pack_copy: Path) -> None:
    sha, _ = source_location(entities()[0])
    common = ["--pack", str(pack_copy), "--sha", sha, "--pack-rel", "packages/qe-agent-pack"]
    assert run_generator("--check", *common).returncode == 0

    new_skill = pack_copy / ".apm" / "skills" / "brand-new-skill"
    new_skill.mkdir()
    (new_skill / "SKILL.md").write_text(
        "---\nname: brand-new-skill\ndescription: Added without regenerating.\n---\n# Body\n"
    )
    result = run_generator("--check", *common)
    assert result.returncode == 1
    assert "drift: catalog-info.yaml" in result.stderr
    assert "drift: .well-known/skills/index.json" in result.stderr
    assert "brand-new-skill" in result.stderr


def test_generator_rejects_an_out_of_range_eval_score(pack_copy: Path) -> None:
    score_file = pack_copy / "eval-score.json"
    score = json.loads(score_file.read_text())
    score["metrics"]["mutation_kill_rate"]["candidate"] = 1.5
    score_file.write_text(json.dumps(score))
    sha, _ = source_location(entities()[0])
    result = run_generator("--pack", str(pack_copy), "--sha", sha)
    assert result.returncode == 2
    assert "mutation_kill_rate" in result.stderr


# Backstage schema validation ---------------------------------------------------


def test_validator_accepts_the_committed_catalog() -> None:
    result = run_validator(CATALOG)
    assert result.returncode == 0, result.stdout + result.stderr


def test_validator_rejects_the_invalid_fixture() -> None:
    result = run_validator(INVALID_FIXTURE)
    assert result.returncode == 1
    assert "metadata.name" in result.stderr
    assert "remotes" in result.stderr


# Skills index ------------------------------------------------------------------


def test_skills_index_matches_the_pack() -> None:
    index = json.loads(SKILLS_INDEX.read_text())
    assert set(index) == {"skills"}
    by_name = {entry["name"]: entry for entry in index["skills"]}
    assert set(by_name) == {d.name for d in skill_dirs()}
    for skill_dir in skill_dirs():
        entry = by_name[skill_dir.name]
        assert set(entry) == {"name", "description", "files"}
        assert SKILL_NAME_RE.match(entry["name"])
        assert entry["description"] == frontmatter(skill_dir / "SKILL.md")["description"].strip()
        assert "SKILL.md" in entry["files"]
        on_disk = sorted(p.relative_to(skill_dir).as_posix() for p in skill_dir.rglob("*") if p.is_file())
        assert entry["files"] == on_disk
