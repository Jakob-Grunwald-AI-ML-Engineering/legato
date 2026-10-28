"""Bind verdicts to exact files; verify the converter's conservative pinned source closure."""
import hashlib
import importlib.metadata
import json
import os
import sys
from collections.abc import Mapping
from pathlib import Path
from typing import cast

PINNED_REVISION = "f4ad26d061dc2e426faa19f81c367343bdeb9f0d"
PROJECT = Path(__file__).resolve().parents[2]
TRUSTED_MANIFEST = PROJECT / "provenance/anemll-f4ad26d-source.json"
PACKAGING_FILES = {"pyproject.toml", "setup.cfg", "requirements.txt", "requirements-ci.txt"}


def sha256(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def file_identity(path: Path) -> dict[str, object]:
    return {"bytes": path.stat().st_size, "sha256": sha256(path)}


def canonical_digest(value: object) -> str:
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def source_scope(name: str) -> bool:
    path = Path(name)
    return (name.startswith(("anemll/", "tests/")) or path.suffix in {".py", ".sh", ".so", ".dylib", ".pyc"}
            or name in PACKAGING_FILES)


def scoped_source_files(upstream: Path) -> dict[str, Path]:
    result: dict[str, Path] = {}
    for folder, directories, names in os.walk(upstream):
        directories[:] = [name for name in directories if name not in {".git", ".venv", ".cache", "__pycache__"}]
        for name in names:
            path = Path(folder) / name
            relative = str(path.relative_to(upstream))
            if source_scope(relative):
                result[relative] = path
    return result


def verify_upstream(upstream: Path) -> dict[str, object]:
    """Reject mismatched executable sources before output creation, download or converter launch."""
    manifest = cast(dict[str, object], json.loads(TRUSTED_MANIFEST.read_text()))
    if manifest["revision"] != PINNED_REVISION:
        raise ValueError("trusted pinned source manifest has an unexpected revision")
    expected = cast(dict[str, dict[str, object]], manifest["files"])
    actual = scoped_source_files(upstream)
    if actual.keys() != expected.keys():
        missing, extra = sorted(expected.keys() - actual.keys()), sorted(actual.keys() - expected.keys())
        raise ValueError(f"upstream differs from pinned dependency closure: missing={missing}, extra={extra}")
    verified: dict[str, object] = {}
    for name, identity in expected.items():
        path = actual[name]
        if path.is_symlink() or not path.resolve().is_relative_to(upstream.resolve()):
            raise ValueError(f"upstream pinned source must be a regular local file: {name}")
        observed = file_identity(path)
        if observed["sha256"] != identity["sha256"] or observed["bytes"] != identity["bytes"]:
            raise ValueError(f"upstream differs from pinned dependency closure: {name}")
        verified[name] = observed
    return {"revision": PINNED_REVISION, "manifest_sha256": sha256(TRUSTED_MANIFEST),
            "scope": manifest["scope"], "files": verified, "closure_sha256": canonical_digest(verified)}


def validation_provenance(model: Path, source: Path, parameters: Mapping[str, object],
                          fixture: Path, options: Mapping[str, object]) -> dict[str, object]:
    """Hash prediction inputs and validator implementation without hashing an output report/manifest."""
    model, source = model.resolve(), source.resolve()
    source_files = {path.name: file_identity(path) for path in sorted(source.iterdir()) if path.is_file()}
    for required in ("model.safetensors", "config.json", "tokenizer.json", "tokenizer_config.json"):
        if required not in source_files:
            raise ValueError(f"missing source input: {required}")
    selected = {"meta.yaml"}
    chunks = int(cast(int, parameters["num_chunks"]))
    for key in ("embeddings", "lm_head", "ffn"):
        base = parameters[key]
        if not isinstance(base, str):
            raise ValueError(f"invalid compiled model path: {key}")
        for number in (range(1, chunks + 1) if key == "ffn" else [1]):
            selected.add(base.replace("01of", f"{number:02d}of") if key == "ffn" else base)
    compiled: dict[str, object] = {}
    for name in sorted(selected):
        path = model / name
        if not path.exists() or not path.resolve().is_relative_to(model):
            raise ValueError(f"compiled input missing or outside model directory: {name}")
        files = sorted(path.rglob("*")) if path.is_dir() else [path]
        for child in files:
            if child.is_file():
                if child.is_symlink() or not child.resolve().is_relative_to(model):
                    raise ValueError(f"compiled input is not a regular local file: {child}")
                compiled[str(child.relative_to(model))] = file_identity(child)
    validator_paths = [PROJECT / "validate_coreml.py", PROJECT / "uv.lock", PROJECT / "pyproject.toml",
                       PROJECT / ".python-version", *sorted((PROJECT / "src/ane_conversion").glob("*.py"))]
    identity: dict[str, object] = {
        "model_root": str(model), "source_root": str(source), "source_files": source_files,
        "compiled_files": compiled, "fixture": {"path": str(fixture.resolve()), **file_identity(fixture)},
        "validator_files": {str(path.relative_to(PROJECT)): file_identity(path) for path in validator_paths},
        "options": dict(options), "python": sys.version, "python_executable": sys.executable,
        "installed_packages": dict(sorted((str(dist.metadata["Name"]), dist.version) for dist in importlib.metadata.distributions())),
        "scope": "Exact source inputs, selected compiled trees/meta, fixture, validator/helpers/lock/runtime/options; excludes output reports and install manifests to avoid circular identity.",
    }
    identity["inventory_sha256"] = canonical_digest(identity)
    return identity
