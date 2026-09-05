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
import os
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
        if os.environ.get("CI"):
            pytest.fail("@backstage/catalog-model is not installed; CI must run npm ci first")
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
    system = next(e for e in entities() if e["kind"] == "System")
    payload = json.loads(system["metadata"]["annotations"]["wololo.dev/eval-score"])
    assert payload["metrics"] == score["metrics"]
    assert payload["source"] == score["source"]
    assert payload["recorded"] == score["recorded"]
    assert payload["verdict"] == score["verdict"]
    assert payload["sourceVisibility"] == score["visibility"] == "internal"
    link = next(l for l in system["metadata"]["links"] if l["type"] == "eval")
    assert link["url"] == score["source"]
    assert "internal" in link["title"]
    for entity in entities():
        annotations = entity["metadata"]["annotations"]
        if entity["kind"] == "System":
            assert "wololo.dev/eval-score-ref" not in annotations
        else:
            assert "wololo.dev/eval-score" not in annotations
            assert annotations["wololo.dev/eval-score-ref"] == "system:default/qe-agent-pack"


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


def git(cwd: Path, *args: str) -> str:
    return subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True, check=True).stdout.strip()


@pytest.fixture
def pack_repo(tmp_path: Path) -> Path:
    """A throwaway repository holding the pack, with sources committed."""
    repo = tmp_path / "repo"
    pack = repo / "packages" / "qe-agent-pack"
    shutil.copytree(PACK, pack)
    for generated in (pack / "catalog-info.yaml", pack / ".well-known"):
        shutil.rmtree(generated) if generated.is_dir() else generated.unlink()
    git(repo, "init", "--quiet")
    git(repo, "config", "user.email", "test@test.com")
    git(repo, "config", "user.name", "Test")
    git(repo, "add", ".")
    git(repo, "commit", "--quiet", "--no-gpg-sign", "-m", "pack sources")
    return pack


def test_check_fails_after_adding_a_skill_without_regenerating(pack_repo: Path) -> None:
    common = ["--pack", str(pack_repo), "--pack-rel", "packages/qe-agent-pack"]
    assert run_generator(*common).returncode == 0
    git(pack_repo, "add", ".")
    git(pack_repo, "commit", "--quiet", "--no-gpg-sign", "-m", "generated catalogue")
    assert run_generator("--check", *common).returncode == 0

    new_skill = pack_repo / ".apm" / "skills" / "brand-new-skill"
    new_skill.mkdir()
    (new_skill / "SKILL.md").write_text(
        "---\nname: brand-new-skill\ndescription: Added without regenerating.\n---\n# Body\n"
    )
    result = run_generator("--check", *common)
    assert result.returncode == 1
    assert "drift: catalog-info.yaml" in result.stderr
    assert "drift: .well-known/skills/index.json" in result.stderr
    assert "brand-new-skill" in result.stderr


def test_generator_rejects_an_out_of_range_eval_score(pack_repo: Path) -> None:
    score_file = pack_repo / "eval-score.json"
    score = json.loads(score_file.read_text())
    score["metrics"]["mutation_kill_rate"]["candidate"] = 1.5
    score_file.write_text(json.dumps(score))
    result = run_generator("--pack", str(pack_repo), "--pack-rel", "packages/qe-agent-pack", "--allow-dirty")
    assert result.returncode == 2
    assert "mutation_kill_rate" in result.stderr


def test_generator_refuses_a_pack_outside_a_git_repository(tmp_path: Path) -> None:
    copy = tmp_path / "qe-agent-pack"
    shutil.copytree(PACK, copy)
    sha, _ = source_location(entities()[0])
    result = run_generator("--pack", str(copy), "--sha", sha, "--pack-rel", "packages/qe-agent-pack")
    assert result.returncode == 2
    assert "not inside a git repository" in result.stderr


def test_check_pins_the_committed_sha_and_fails_when_sources_move_past_it(pack_repo: Path) -> None:
    repo = pack_repo.parents[1]
    sources_sha = git(repo, "rev-parse", "HEAD")
    assert run_generator("--pack", str(pack_repo), "--pack-rel", "packages/qe-agent-pack").returncode == 0
    assert sources_sha in (pack_repo / "catalog-info.yaml").read_text()
    git(repo, "add", ".")
    git(repo, "commit", "--quiet", "--no-gpg-sign", "-m", "generated catalogue")
    # The regenerating commit is HEAD now, yet the check must still resolve
    # against the pinned sources commit rather than deriving a new one.
    assert run_generator("--check", "--pack", str(pack_repo), "--pack-rel", "packages/qe-agent-pack").returncode == 0

    skill = pack_repo / ".apm" / "skills" / "find-missing-tests" / "SKILL.md"
    skill.write_text(skill.read_text().replace("Analyze codebase", "Analyse codebase"))
    git(repo, "commit", "--quiet", "--no-gpg-sign", "-am", "edit a skill without regenerating")
    result = run_generator("--check", "--pack", str(pack_repo), "--pack-rel", "packages/qe-agent-pack")
    assert result.returncode == 2
    assert f"differ from provenance commit {sources_sha[:12]}" in result.stderr


def test_check_fails_when_the_pinned_commit_is_unreachable(pack_repo: Path) -> None:
    repo = pack_repo.parents[1]
    assert run_generator("--pack", str(pack_repo), "--pack-rel", "packages/qe-agent-pack").returncode == 0
    catalog = pack_repo / "catalog-info.yaml"
    catalog.write_text(catalog.read_text().replace(git(repo, "rev-parse", "HEAD"), "0" * 40))
    result = run_generator("--check", "--pack", str(pack_repo), "--pack-rel", "packages/qe-agent-pack")
    assert result.returncode == 2
    assert "not in this repository" in result.stderr


def test_skills_index_ignores_untracked_build_artefacts() -> None:
    result = subprocess.run(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "--", "."],
        cwd=PACK / ".apm" / "skills" / "webapp-testing", capture_output=True, text=True, check=True,
    )
    assert not [f for f in result.stdout.split() if "__pycache__" in f or f.endswith(".pyc")]


# Backstage schema validation ---------------------------------------------------


def test_validator_accepts_the_committed_catalog() -> None:
    result = run_validator(CATALOG)
    assert result.returncode == 0, result.stdout + result.stderr


def test_validator_rejects_the_invalid_fixture() -> None:
    result = run_validator(INVALID_FIXTURE)
    assert result.returncode == 1
    assert "metadata.name" in result.stderr
    assert "remotes" in result.stderr
    assert "disciplines" in result.stderr
    assert 'unknown spec.type "skil"' in result.stderr
    assert 'unknown spec.type "constructor"' in result.stderr
    assert "TypeError" not in result.stderr


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
        for rel in entry["files"]:
            assert (skill_dir / rel).is_file()
