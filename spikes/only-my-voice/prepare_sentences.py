"""Prepare a pinned, chapter-disjoint LibriSpeech speaker evaluation subset."""
from __future__ import annotations

import argparse
import hashlib
import json
import tarfile
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent
URL = "https://openslr.trmal.net/resources/12/test-clean.tar.gz"
MD5 = "32fa31d27d2e1cad72775fee3f4849a9"


def digest(path: Path, algorithm: str) -> str:
    checksum = hashlib.new(algorithm)
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            checksum.update(chunk)
    return checksum.hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=Path, help="Reuse an existing test-clean.tar.gz")
    parser.add_argument("--output", type=Path, default=ROOT / ".cache" / "sentences")
    args = parser.parse_args()
    output: Path = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    archive: Path = args.archive or output / "test-clean.tar.gz"
    if not archive.exists():
        if args.archive:
            parser.error(f"Archive does not exist: {archive}")
        print(f"Downloading public CC BY 4.0 LibriSpeech audio: {URL}", flush=True)
        urllib.request.urlretrieve(URL, archive)
    if digest(archive, "md5") != MD5:
        raise ValueError("Archive differs from official OpenSLR checksum")
    provenance = json.loads((ROOT / "results" / "sentence-provenance.json").read_text())
    expected_sha256 = provenance["archive_sha256"]
    if digest(archive, "sha256") != expected_sha256:
        raise ValueError("Archive SHA256 mismatch")
    wanted = {entry["source"]: entry for entry in provenance["clips"]}
    manifest: dict[str, dict[str, list[str]]] = {}
    with tarfile.open(archive, "r|gz") as source:
        for member in source:
            if member.name not in wanted:
                continue
            entry = wanted.pop(member.name)
            stream = source.extractfile(member)
            if stream is None:
                raise ValueError(f"Missing file body: {member.name}")
            payload = stream.read()
            if hashlib.sha256(payload).hexdigest() != entry["sha256"]:
                raise ValueError(f"Clip checksum mismatch: {member.name}")
            destination = output / entry["speaker"] / Path(member.name).name
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(payload)
            manifest.setdefault(entry["speaker"], {})[entry["split"]] = [str(destination)]
    if wanted:
        raise ValueError(f"Missing archive members: {sorted(wanted)}")
    result = output / "manifest.json"
    result.write_text(json.dumps(manifest, indent=2) + "\n")
    print(result)


if __name__ == "__main__":
    main()
