"""Download pinned public assets; no provider keys or audio upload."""
import asyncio
import hashlib
import json
from pathlib import Path
from urllib.request import urlopen

ROOT = Path(__file__).resolve().parent
MODEL_REV = "f316edbc70d9023a94aaf8965538aba4330dc28e"
CORPUS_REV = "26eb9aaf76e81b692f806f9140c2d2777410d7a1"
SPEAKERS = ("jackson", "nicolas", "theo", "yweweler", "george", "lucas")


def fetch(url: str, path: Path) -> dict[str, str]:
    path.parent.mkdir(parents=True, exist_ok=True)
    if not path.exists():
        with urlopen(url, timeout=60) as response:
            path.write_bytes(response.read())
    return {"path": str(path.relative_to(ROOT)), "url": url,
            "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}


async def main() -> None:
    with urlopen(f"https://huggingface.co/api/models/FluidInference/campplus-coreml/revision/{MODEL_REV}", timeout=30) as response:
        siblings = json.load(response)["siblings"]
    jobs = []
    for item in siblings:
        name = item["rfilename"]
        if name.startswith(("CamPlusPlus_v2.mlmodelc/", "CamPlusPreprocessor_v2.mlmodelc/")):
            jobs.append((f"https://huggingface.co/FluidInference/campplus-coreml/resolve/{MODEL_REV}/{name}", ROOT / ".cache/models" / name))
    for speaker in SPEAKERS:
        for digit in range(10):
            for take in (0, 5, 6):
                name = f"{digit}_{speaker}_{take}.wav"
                jobs.append((f"https://raw.githubusercontent.com/Jakobovski/free-spoken-digit-dataset/{CORPUS_REV}/recordings/{name}", ROOT / ".cache/audio" / name))
    semaphore = asyncio.Semaphore(6)

    async def bounded(url: str, path: Path) -> dict[str, str]:
        async with semaphore:
            return await asyncio.to_thread(fetch, url, path)

    manifest = await asyncio.gather(*(bounded(url, path) for url, path in jobs))
    (ROOT / "results/assets.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"Ready: {len(manifest)} pinned files; manifest in results/assets.json")


if __name__ == "__main__":
    asyncio.run(main())
