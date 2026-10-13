#!/usr/bin/env python3
"""Preserve existing approved cache evidence privately, without fetching or research."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for part in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(part)
    return result.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cache", type=Path, required=True, help="existing aloud-names cache root")
    parser.add_argument("--out", type=Path, required=True, help="private durable directory outside the repository/cache")
    args = parser.parse_args()
    cache, output = args.cache.resolve(), args.out.resolve()
    try:
        if output.is_relative_to(ROOT) or output.is_relative_to(cache) or cache.is_relative_to(output):
            raise ValueError("archive must be outside the repository and original cache")
        source = ROOT / "lexicon-src/names/names.source.json"
        lock = ROOT / "lexicon-src/names/sources.lock.json"
        source_hash, lock_hash = digest(source), digest(lock)
        master, sources = json.loads(source.read_bytes()), json.loads(lock.read_bytes())
        plan = {}
        def add(path, relative, expected=None):
            if not path.resolve().is_relative_to(cache) or path.is_symlink() or not path.is_file():
                raise ValueError(f"missing or unsafe original evidence: {path}")
            checksum = digest(path)
            if expected is not None and checksum != expected:
                raise ValueError(f"original evidence disagrees with source lock: {relative}")
            plan[relative] = {"source": path, "sha256": checksum, "bytes": path.stat().st_size}
        for batch in sorted(master["batches"]):
            if not (batch.startswith("n") and batch[1:].isdigit()) and batch != "p0001":
                raise ValueError(f"unexpected existing batch {batch}")
            base = cache / "research/out"
            add(base / f"{batch}.json", f"research/out/{batch}.json")
            add(base / f"{batch}.checked.json", f"research/out/{batch}.checked.json")
            review = base / f"{batch}.review.json"
            if review.exists():
                add(review, f"research/out/{review.name}")
            audio = base / f"{batch}.audio"
            if audio.exists():
                for path in sorted(audio.rglob("*")):
                    if path.is_file():
                        add(path, str(path.relative_to(cache)))
        for name, record in sorted(sources["files"].items()):
            add(cache / "run-20261008" / name, f"run-20261008/{name}", record["sha256"])
        listening = cache / "research/listen"
        if listening.exists():
            for path in sorted(listening.rglob("*")):
                if path.is_file():
                    add(path, str(path.relative_to(cache)))
        manifest = {"schema": 1, "privacy": "private recovery archive; not a redistributable publication artifact",
                    "scope": "existing approved research and original references only; no fetch or new batch",
                    "master_sha256": source_hash, "source_lock_sha256": lock_hash,
                    "batches": sorted(master["batches"]),
                    "files": {name: {key: value for key, value in item.items() if key != "source"} for name, item in sorted(plan.items())}}
        output.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(output, 0o700)
        for name, item in plan.items():
            target = output / name
            if not target.resolve().is_relative_to(output):
                raise ValueError(f"archive path escapes private directory: {name}")
            target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            if target.exists():
                if target.is_symlink() or digest(target) != item["sha256"]:
                    raise ValueError(f"existing archive differs: {name}; preserve it and choose a new --out")
                os.chmod(target, 0o600)
                continue
            fd, temporary = tempfile.mkstemp(prefix=".evidence-", dir=target.parent)
            os.close(fd)
            try:
                shutil.copyfile(item["source"], temporary)
                if digest(Path(temporary)) != item["sha256"]:
                    raise ValueError(f"evidence changed while copying: {name}")
                with open(temporary, "rb") as stream:
                    os.fsync(stream.fileno())
                os.replace(temporary, target)
            finally:
                if os.path.exists(temporary):
                    os.unlink(temporary)
        if digest(source) != source_hash or digest(lock) != lock_hash:
            raise ValueError("approved source changed while archiving; archive is incomplete, rerun with stable source")
        data = (json.dumps(manifest, ensure_ascii=False, sort_keys=True, indent=2) + "\n").encode()
        # A completed manifest only appears after every file has been copied and verified.
        fd, temporary = tempfile.mkstemp(prefix=".manifest-", dir=output)
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, output / "evidence-manifest.json")
        print(f"Preserved {len(plan)} files, {sum(item['bytes'] for item in plan.values())} bytes, {len(master['batches'])} existing batches")
        print(f"Private receipt: {output / 'evidence-manifest.json'}")
        return 0
    except (OSError, ValueError, KeyError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
