"""Reports must identify their exact inputs before inference, without a report/manifest cycle."""
import hashlib
import json
import shutil
import sys
from pathlib import Path

import pytest
import yaml

# Exercise the real CLI entrypoints; no Core ML prediction is needed for an intentionally rejected LUT artifact.
import full_convert
import validate_coreml


@pytest.fixture
def rejected_quantized_inputs(tmp_path: Path) -> tuple[Path, Path, Path]:
    model, source = tmp_path / "model", tmp_path / "source"
    model.mkdir()
    source.mkdir()
    params = {"context_length": 2048, "num_chunks": 1, "lut_ffn": 6, "lut_lmhead": 6,
              "embeddings": "emb.mlmodelc", "lm_head": "head.mlmodelc", "ffn": "ffn_chunk_01of01.mlmodelc"}
    (model / "meta.yaml").write_text(yaml.safe_dump({"model_info": {"parameters": params}}))
    for name in ("emb.mlmodelc", "head.mlmodelc", "ffn_chunk_01of01.mlmodelc"):
        folder = model / name
        folder.mkdir()
        (folder / "weight.bin").write_bytes(b"compiled-A")
    for name, value in {"model.safetensors": b"weights-A", "tokenizer.json": b"tokenizer-A", "tokenizer_config.json": b"template-A", "config.json": b"config-A"}.items():
        (source / name).write_bytes(value)
    return model, source, tmp_path / "verdict.json"


def test_rejected_report_binds_exact_inputs_validator_helpers_and_options_before_inference(
    rejected_quantized_inputs: tuple[Path, Path, Path], monkeypatch: pytest.MonkeyPatch,
) -> None:
    model, source, output = rejected_quantized_inputs
    monkeypatch.setattr(sys, "argv", ["validate_coreml.py", "--model", str(model), "--source", str(source), "--output", str(output), "--compute", "cpu-and-ne", "--prefill-batches", "1", "2"])
    assert validate_coreml.main() == 1
    report = json.loads(output.read_text())
    assert "input_provenance" in report, "verdict lacks exact input/validator identity"
    provenance = report["input_provenance"]
    assert provenance["source_files"]["model.safetensors"]["sha256"] == hashlib.sha256(b"weights-A").hexdigest()
    assert provenance["source_files"]["tokenizer.json"]["sha256"] == hashlib.sha256(b"tokenizer-A").hexdigest()
    assert provenance["compiled_files"]["ffn_chunk_01of01.mlmodelc/weight.bin"]["sha256"] == hashlib.sha256(b"compiled-A").hexdigest()
    assert provenance["fixture"]["sha256"] == hashlib.sha256((Path(validate_coreml.__file__).parent / "checks/fixtures/prefix-parity.json").read_bytes()).hexdigest()
    assert "validate_coreml.py" in provenance["validator_files"]
    assert "src/ane_conversion/parity_gate.py" in provenance["validator_files"]
    assert "src/ane_conversion/prefill_contract.py" in provenance["validator_files"]
    assert provenance["options"]["compute"] == "cpu-and-ne"
    assert provenance["options"]["prefill_batches"] == [1, 2]
    assert provenance["options"]["strict_quantized_gate"] is False
    assert len(provenance["inventory_sha256"]) == 64
    assert report["rows"] == []


def test_changed_source_or_compiled_input_changes_verdict_inventory(
    rejected_quantized_inputs: tuple[Path, Path, Path], monkeypatch: pytest.MonkeyPatch,
) -> None:
    model, source, output = rejected_quantized_inputs
    monkeypatch.setattr(sys, "argv", ["validate_coreml.py", "--model", str(model), "--source", str(source), "--output", str(output)])
    assert validate_coreml.main() == 1
    before = json.loads(output.read_text())
    assert "input_provenance" in before, "no inventory can detect changed model inputs"
    (source / "tokenizer.json").write_bytes(b"tokenizer-B")
    (model / "ffn_chunk_01of01.mlmodelc/weight.bin").write_bytes(b"compiled-B")
    assert validate_coreml.main() == 1
    after = json.loads(output.read_text())
    assert before["input_provenance"]["inventory_sha256"] != after["input_provenance"]["inventory_sha256"]


def test_arbitrary_upstream_is_rejected_before_checkpoint_download(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    upstream = tmp_path / "upstream"
    for name in ("anemll/utils/convert_model.sh", "anemll/ane_converter/qwen_converter.py", "anemll/models/qwen_model.py"):
        path = upstream / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("modified converter\n")
    downloads: list[str] = []
    def download_boundary(*_args: object, **_kwargs: object) -> None:
        downloads.append("attempted")
        raise RuntimeError("no downloads permitted in this regression")
    monkeypatch.setattr(full_convert, "snapshot_download", download_boundary)
    monkeypatch.setattr(sys, "argv", ["full_convert.py", "--upstream", str(upstream), "--output", str(tmp_path / "output")])
    with pytest.raises(ValueError, match="pinned"):
        full_convert.main()
    assert downloads == []
    assert not (tmp_path / "output").exists()


@pytest.mark.parametrize("helper", ["anemll/ane_converter/base_converter.py", "anemll/utils/combine_models.py", "tests/chat.py"])
def test_modified_converter_dependency_is_rejected_before_download(tmp_path: Path, monkeypatch: pytest.MonkeyPatch, helper: str) -> None:
    project = Path(full_convert.__file__).parent
    trusted = json.loads((project / "provenance/anemll-f4ad26d-source.json").read_text())
    original = project.parent / ".cache/Anemll-Anemll-f4ad26d"
    upstream = tmp_path / "upstream"
    for name in trusted["files"]:
        target = upstream / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(original / name, target)
    with (upstream / helper).open("a") as stream:
        stream.write("\n# modified dependency\n")
    downloads: list[str] = []
    def download_boundary(*_args: object, **_kwargs: object) -> None:
        downloads.append("attempted")
        raise RuntimeError("no downloads permitted in this regression")
    monkeypatch.setattr(full_convert, "snapshot_download", download_boundary)
    monkeypatch.setattr(sys, "argv", ["full_convert.py", "--upstream", str(upstream), "--output", str(tmp_path / "output")])
    with pytest.raises(ValueError, match="pinned"):
        full_convert.main()
    assert downloads == []
    assert not (tmp_path / "output").exists()


def test_verified_archive_accepts_the_complete_pinned_dependency_closure() -> None:
    from ane_conversion.provenance import verify_upstream

    upstream = Path(full_convert.__file__).parent.parent / ".cache/Anemll-Anemll-f4ad26d"
    verified = verify_upstream(upstream)
    assert verified["revision"] == "f4ad26d061dc2e426faa19f81c367343bdeb9f0d"
    assert len(verified["files"]) == 199
    assert verified["files"]["anemll/utils/convert_model.sh"]["sha256"] == "032a6ef92164e52677ac5441a494256b44e4392d05383f89cd253ec8a468a4fe"
