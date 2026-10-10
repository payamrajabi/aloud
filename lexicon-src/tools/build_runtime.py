#!/usr/bin/env python3
"""Offline, deterministic approved-master build. See ../delivery/README.md."""
import argparse
import csv
import fcntl
from contextlib import contextmanager
import io
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
REGISTRY = "lexicon-src/delivery/registry.json"
ORDER = ("word", "match", "us", "gb", "dictation", "pack_only", "unit", "caps_word", "evidence", "spoken", "spoken_context_only", "note")
REQUIRED = {"word", "match", "us"}
MODES = {"always", "context", "never"}


class BuildError(ValueError):
    pass


def sha(data):
    return hashlib.sha256(data).hexdigest()


def encoded(value):
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + "\n").encode()


def unique_object(pairs):
    out = {}
    for key, value in pairs:
        if key in out:
            raise BuildError(f"duplicate JSON key: {key}")
        out[key] = value
    return out


def read_json(path):
    try:
        return json.loads(path.read_bytes(), object_pairs_hook=unique_object)
    except (OSError, ValueError) as error:
        raise BuildError(f"{path}: {error}") from error


def inside(root, name):
    if not isinstance(name, str) or Path(name).is_absolute():
        raise BuildError(f"expected a relative repository path: {name}")
    path = (root / name).resolve()
    if not path.is_relative_to(root.resolve()):
        raise BuildError(f"path escapes repository: {name}")
    return path


def runtime_path(name):
    path = Path(name)
    if len(path.parts) != 2 or path.parts[0] != "Lexicons" or path.suffix != ".json":
        raise BuildError(f"runtime target must be Lexicons/NAME.json: {name}")


def assert_inventory(root, names):
    actual = {str(path.relative_to(root)) for path in (root / "Lexicons").glob("*.json")}
    if actual != set(names):
        raise BuildError(f"runtime pack inventory changed: undeclared {sorted(actual - set(names))}, missing {sorted(set(names) - actual)}")


def validate(rows, pack, vocab):
    if not isinstance(rows, list) or not rows:
        raise BuildError(f"{pack}: expected a nonempty entry array")
    seen = set()
    for entry in rows:
        if not isinstance(entry, dict) or not REQUIRED <= entry.keys() or entry.keys() - set(ORDER):
            raise BuildError(f"{pack}: unknown or missing runtime fields: {entry}")
        word = entry["word"]
        if not isinstance(word, str) or not word or word != word.strip():
            raise BuildError(f"{pack}: invalid word: {word}")
        match = entry["match"]
        if match not in ("case-sensitive", "case-insensitive", "exact", "name"):
            raise BuildError(f"{pack}/{word}: invalid match")
        key = (match in ("case-sensitive", "exact", "name"), word if match != "case-insensitive" else word.lower())
        if key in seen:
            raise BuildError(f"{pack}/{word}: duplicate matching spelling")
        seen.add(key)
        for locale in ("us", "gb"):
            if locale not in entry:
                continue
            phones = entry[locale]
            if not isinstance(phones, str) or not phones.strip():
                raise BuildError(f"{pack}/{word}: blank {locale} phonemes")
            bad = set(phones) - set(vocab[locale.upper() + "_OK"])
            if bad or set(phones) - set(vocab["KOKORO"]):
                raise BuildError(f"{pack}/{word}: unsupported {locale} phonemes: {sorted(bad)}")
        mode = entry.get("dictation", "never")
        if mode not in MODES:
            raise BuildError(f"{pack}/{word}: invalid dictation mode")
        for field in ("pack_only", "unit", "caps_word", "evidence"):
            if field in entry and type(entry[field]) is not bool:
                raise BuildError(f"{pack}/{word}: {field} must be boolean")
        if pack == "tech" and entry.get("pack_only"):
            raise BuildError(f"{pack}/{word}: tech cannot be pack_only")
        for field in ("spoken", "spoken_context_only"):
            values = entry.get(field, [])
            if not isinstance(values, list) or any(not isinstance(v, str) or not v.strip() or v != v.strip() for v in values):
                raise BuildError(f"{pack}/{word}: invalid {field}")
            if len(set(values)) != len(values):
                raise BuildError(f"{pack}/{word}: duplicate {field}")
        if not set(entry.get("spoken_context_only", [])) <= set(entry.get("spoken", [])):
            raise BuildError(f"{pack}/{word}: context gates must be spoken variants")
        if mode == "never" and (entry.get("spoken") or entry.get("spoken_context_only")):
            raise BuildError(f"{pack}/{word}: pronunciation-only entry cannot rewrite dictation")
        if pack == "names" and (mode != "never" or match != "name" or entry.get("pack_only")):
            raise BuildError(f"{pack}/{word}: names must use possessive-only matching, be always-on, and pronunciation-only")


def project_tech(entry):
    if not isinstance(entry, dict) or any(not isinstance(entry.get(k), str) or not entry[k].strip() for k in ("word", "match", "us", "source", "category", "confidence", "dictation")):
        raise BuildError("tech master: missing identity, evidence, classification or reading")
    row = {k: entry[k] for k in ("word", "match", "us")}
    if entry.get("gb"):
        row["gb"] = entry["gb"]
    row["dictation"] = entry["dictation"]
    for field in ("unit", "caps_word"):
        if entry.get(field):
            row[field] = entry[field]
    if row["dictation"] != "never":
        if entry.get("evidence") is False:
            row["evidence"] = False
        variants = entry.get("spoken_variants", [])
        if not isinstance(variants, list) or any(not isinstance(v, str) for v in variants):
            raise BuildError(f"tech/{entry['word']}: invalid researched spoken variants")
        if variants:
            row["spoken"] = sorted(set(variants))
    return row


def compile_tech(master, decisions):
    if not isinstance(master, list) or not isinstance(decisions, dict) or decisions.get("schema") != 1:
        raise BuildError("tech: invalid master/decision schema")
    patches = decisions.get("entries")
    if not isinstance(patches, dict):
        raise BuildError("tech: invalid decision entries")
    rows, used, words = [], set(), set()
    for entry in master:
        row = project_tech(entry)
        word = row["word"]
        if word in words:
            raise BuildError(f"tech master: duplicate word {word}")
        words.add(word)
        if word in patches:
            patch = patches[word]
            if not isinstance(patch, dict) or not isinstance(patch.get("reason"), str) or not patch["reason"].strip():
                raise BuildError(f"tech/{word}: decision must explain its provenance")
            changes = patch.get("set", {})
            removals = patch.get("remove", [])
            allowed = {"spoken", "spoken_context_only", "evidence"}
            if not isinstance(changes, dict) or not isinstance(removals, list) or set(changes) & set(removals) or (set(changes) | set(removals)) - allowed:
                raise BuildError(f"tech/{word}: decision may only restore approved dictation-safety fields")
            row.update(changes)
            for field in removals:
                if field not in row:
                    raise BuildError(f"tech/{word}: stale removal decision {field}")
                del row[field]
            used.add(word)
        rows.append({key: row[key] for key in ORDER if key in row})
    if set(patches) != used:
        raise BuildError(f"tech: stale decisions for {sorted(set(patches) - used)[:5]}")
    return sorted(rows, key=lambda row: row["word"].casefold())


def compile_names(master, decisions, manifest_bytes):
    if not isinstance(master, dict) or not isinstance(master.get("entries"), list) or decisions.get("schema") != 1:
        raise BuildError("names: invalid master/decision schema")
    scope = decisions.get("scope", {})
    if scope.get("rank_limit") != 5000 or scope.get("existing_special_batches") != ["p0001"]:
        raise BuildError("names: this delivery is limited to first 5000 and existing approved p0001")
    ranked = {}
    for row in csv.DictReader(io.StringIO(manifest_bytes.decode()), delimiter="\t"):
        rank = int(row["rank"])
        if rank <= 5000:
            if rank in ranked:
                raise BuildError(f"names: duplicate manifest rank {rank}")
            ranked[rank] = row["name"]
    if set(ranked) != set(range(1, 5001)):
        raise BuildError("names: manifest must contain every rank 1–5000 exactly once")
    rows, seen, ranked_research, extras = [], set(), {}, []
    disposition_counts = Counter()
    for entry in master["entries"]:
        name, rank, batch = entry.get("name"), entry.get("rank", 0), entry.get("batch")
        if not isinstance(name, str) or not name.strip() or type(rank) is not int or rank < 0 or not isinstance(batch, str):
            raise BuildError("names: invalid candidate identity/rank/batch")
        if name in seen:
            raise BuildError(f"names: duplicate source name {name}")
        seen.add(name)
        if rank in ranked:
            if ranked[rank] != name or rank in ranked_research:
                raise BuildError(f"names/{name}: source disagrees with candidate manifest")
            ranked_research[rank] = entry
        elif batch != "p0001":
            raise BuildError(f"names/{name}: outside first-5000 delivery scope")
        else:
            extras.append(entry)
        disposition = entry.get("disposition")
        if disposition not in ("corrected", "already-correct", "unresolved", "protect-word", "not-a-name") or type(entry.get("shipped")) is not bool:
            raise BuildError(f"names/{name}: unknown disposition or shipping decision")
        disposition_counts[disposition + ("-shipped" if entry["shipped"] else "-held" if disposition == "corrected" else "")] += 1
        if not entry["shipped"]:
            if disposition == "corrected" and not entry.get("drop_reason"):
                raise BuildError(f"names/{name}: held correction needs its reason")
            continue
        if disposition != "corrected" or not entry.get("source") or entry.get("reads_as_written") is not True:
            raise BuildError(f"names/{name}: shipped correction lacks evidence or recorded validation")
        row = {"word": name, "match": "name", "us": entry.get("us"), "gb": entry.get("gb") or entry.get("us"), "dictation": "never"}
        after = entry.get("after", {})
        if any(after.get(field) != row[locale] for locale, field in (("us", "us"), ("gb", "gb"), ("us", "us_sentence"), ("gb", "gb_sentence"))):
            raise BuildError(f"names/{name}: committed before/after evidence disagrees with chosen reading")
        rows.append(row)
    coverage = {"ranked_candidates_in_scope": 5000, "ranked_candidates_with_research": len(ranked_research),
                "ranked_candidates_without_research": 5000 - len(ranked_research),
                "ranked_dispositions": dict(sorted(Counter(entry["disposition"] + ("-shipped" if entry["shipped"] else "-held" if entry["disposition"] == "corrected" else "") for entry in ranked_research.values()).items())),
                "existing_special_candidates_outside_ranks": len(extras),
                "existing_special_corrections_outside_ranks": sum(entry["shipped"] for entry in extras),
                "all_researched_dispositions": dict(sorted(disposition_counts.items())),
                "listening": "No new listening exercise performed; recorded evidence preserved, not independently re-listened."}
    return rows, coverage


def atomic_write(path, data, before_replace=None):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix="." + path.name + ".", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        if before_replace is not None:
            before_replace()
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def build(root, output):
    registry = read_json(inside(root, REGISTRY))
    if registry.get("schema") != 1 or not isinstance(registry.get("packs"), list):
        raise BuildError("unsupported registry")
    inputs = {REGISTRY, "lexicon-src/tools/build_runtime.py", "lexicon-src/tools/check_packs.py", "lexicon-src/tools/vocab.json"}
    inputs.update(registry["safety_decisions"])
    inputs.add(registry["conflicts"])
    for spec in registry["packs"]:
        inputs.update((spec["source"], spec["decisions"]))
        inputs.update(spec.get("evidence", []))
    inputs.update(registry["preserve"])
    input_data = {name: inside(root, name).read_bytes() for name in sorted(inputs)}
    if json.loads(input_data[REGISTRY], object_pairs_hook=unique_object) != registry:
        raise BuildError("registry changed while reading inputs")
    def load(name):
        return json.loads(input_data[name], object_pairs_hook=unique_object)
    vocab = load("lexicon-src/tools/vocab.json")
    generated, rows_by_pack, coverage = {}, {}, {}
    for spec in registry["packs"]:
        source, decisions_path, target = (spec[k] for k in ("source", "decisions", "runtime"))
        inputs.update((source, decisions_path))
        runtime_path(target)
        master = load(source)
        decisions = load(decisions_path)
        if decisions.get("source_sha256") != sha(input_data[source]):
            raise BuildError(f"{spec['id']}: source changed; reconcile approved decisions before building")
        if spec["kind"] == "tech":
            rows = compile_tech(master, decisions)
        elif spec["kind"] == "names":
            rows, coverage["names"] = compile_names(master, decisions, input_data[spec["manifest"]])
        else:
            raise BuildError(f"unsupported source kind: {spec['kind']}")
        validate(rows, spec["id"], vocab)
        if spec["kind"] == "names":
            data = ("[\n" + ",\n".join(json.dumps(row, ensure_ascii=False, separators=(",", ":")) for row in rows) + "\n]\n").encode()
        else:
            data = json.dumps(rows, ensure_ascii=False, separators=(",", ":")).encode()
        if sha(data) != decisions.get("approved_runtime_sha256"):
            raise BuildError(f"{spec['id']}: generated runtime differs from approved decision receipt")
        if target in generated:
            raise BuildError(f"duplicate runtime target {target}")
        generated[target] = data
        rows_by_pack[spec["id"]] = len(rows)
    # Freeze the peer files used for conflict checking, never read live files halfway through apply.
    peers = {}
    for name in registry["preserve"]:
        runtime_path(name)
        data = input_data[name]
        pack = Path(name).stem.removesuffix("-lexicon")
        validate(load(name), pack, vocab)
        peers[name] = data
        inputs.add(name)
    all_files = {**peers, **generated}
    if len(all_files) != len(peers) + len(generated):
        raise BuildError("a generated target is also a preserved peer")
    assert_inventory(root, all_files)
    # Validate conflicts in an ephemeral stage; leave no replaceable output on validation failure.
    with tempfile.TemporaryDirectory(prefix="aloud-runtime-") as temporary:
        stage = Path(temporary)
        for name, data in all_files.items():
            atomic_write(stage / "Lexicons" / Path(name).name, data)
        checked = subprocess.run([sys.executable, str(inside(root, "lexicon-src/tools/check_packs.py")), "--lexicons", str(stage / "Lexicons"), "--conflicts", str(inside(root, registry["conflicts"]))], capture_output=True, text=True)
        if checked.returncode:
            raise BuildError("conflict validation failed:\n" + checked.stdout + checked.stderr)
        before = {name: inside(root, name).read_bytes() for name in generated}
        input_hashes = {name: sha(data) for name, data in input_data.items()}
        receipt = {"schema": 1, "status": "validated; not installed or publicly released", "inputs": input_hashes,
                   "outputs": {name: sha(data) for name, data in sorted(generated.items())},
                   "before": {name: sha(data) for name, data in sorted(before.items())},
                   "preserved_peers": {name: sha(data) for name, data in sorted(peers.items())},
                   "entry_counts": rows_by_pack, "coverage": coverage, "validation": checked.stdout.splitlines(),
                   "recovery": "recover --out THIS_STAGE restores the before snapshots; source evidence is never modified"}
        receipt["build_id"] = sha(encoded(receipt))
        # Inputs are reread after checks so an external writer cannot create a mixed receipt.
        assert_inputs(root, receipt)
        if output.exists():
            old = read_json(output / "receipt.json")
            if old != receipt:
                raise BuildError("output stage already holds another build; use a new --out directory")
            verify_stage(output, receipt)
            return receipt
        staging = Path(tempfile.mkdtemp(prefix="." + output.name + ".", dir=output.parent))
        try:
            for name, data in all_files.items():
                atomic_write(staging / "runtime" / name, data)
            for name, data in before.items():
                atomic_write(staging / "before" / name, data)
            atomic_write(staging / "receipt.json", encoded(receipt))
            os.rename(staging, output)
        finally:
            if staging.exists():
                import shutil
                shutil.rmtree(staging)
    return receipt


def assert_inputs(root, receipt):
    for name, expected in receipt["inputs"].items():
        try:
            now = sha(inside(root, name).read_bytes())
        except OSError as error:
            raise BuildError(f"input disappeared after validation: {name}") from error
        if now != expected:
            raise BuildError(f"input changed after validation: {name}; rebuild into a new stage")


def verify_stage(output, receipt):
    for name in receipt["outputs"]:
        runtime_path(name)
    if set(receipt["before"]) != set(receipt["outputs"]):
        raise BuildError("recovery targets differ from generated targets")
    payload, snapshots = {}, {}
    for name, expected in {**receipt["outputs"], **receipt["preserved_peers"]}.items():
        payload[name] = inside(output / "runtime", name).read_bytes()
        if sha(payload[name]) != expected:
            raise BuildError(f"stage changed: {name}")
    for name, expected in receipt["before"].items():
        snapshots[name] = inside(output / "before", name).read_bytes()
        if sha(snapshots[name]) != expected:
            raise BuildError(f"recovery snapshot changed: {name}")
    return payload, snapshots


@contextmanager
def mutation_lock(root):
    """One cooperating publisher per checkout; never unlink this stable lock inode."""
    path = inside(root, "build/.lexicon-runtime.lock")
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a+b") as lock:
        try:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise BuildError("another apply/recover publisher owns this repository lock; retry after it finishes") from error
        try:
            yield
        finally:
            fcntl.flock(lock.fileno(), fcntl.LOCK_UN)


def assert_target(root, name, allowed):
    try:
        current = sha(inside(root, name).read_bytes())
    except OSError as error:
        raise BuildError(f"{name}: target disappeared; preserve and reconcile it manually") from error
    if current not in allowed:
        raise BuildError(f"{name}: current file is neither the expected original nor generated version; preserve and reconcile it manually")


def mutation_guard(root, receipt):
    assert_inputs(root, receipt)
    assert_inventory(root, set(receipt["outputs"]) | set(receipt["preserved_peers"]))


def restore(root, output, receipt, snapshots):
    restored, problems = [], {}
    # Restore eligible files while preserving any external edit, including one made
    # during rollback. Recheck immediately before each atomic replacement.
    for name in receipt["outputs"]:
        def guard(name=name):
            mutation_guard(root, receipt)
            assert_target(root, name, {receipt["before"][name], receipt["outputs"][name]})
        try:
            atomic_write(inside(root, name), snapshots[name], before_replace=guard)
            restored.append(name)
        except (BuildError, OSError) as error:
            problems[name] = str(error)
    transaction = {"build_id": receipt["build_id"], "state": "recovery_required" if problems else "recovered",
                   "restored": restored, "preserved_or_pending": problems}
    atomic_write(output / "transaction.json", encoded(transaction))
    if problems:
        raise BuildError("recovery preserved changed files or could not finish; see transaction.json and reconcile manually: "
                         + "; ".join(problems.values()))


def apply(root, output, recover=False):
    root, output = root.resolve(), output.resolve()
    with mutation_lock(root):
        return apply_locked(root, output, recover)


def apply_locked(root, output, recover):
    receipt = read_json(output / "receipt.json")
    check = dict(receipt)
    expected_id = check.pop("build_id", None)
    if expected_id != sha(encoded(check)):
        raise BuildError("invalid receipt hash")
    payload, snapshots = verify_stage(output, receipt)
    if recover:
        restore(root, output, receipt, snapshots)
        return receipt
    mutation_guard(root, receipt)
    for name, expected in receipt["before"].items():
        if sha(inside(root, name).read_bytes()) != expected:
            raise BuildError(f"runtime changed since staging: {name}")
    atomic_write(output / "transaction.json", encoded({"build_id": expected_id, "state": "prepared", "targets": list(receipt["outputs"])}))
    replaced = set()
    def guard(target=None):
        mutation_guard(root, receipt)
        for name in receipt["outputs"]:
            expected = receipt["outputs"][name] if name in replaced else receipt["before"][name]
            assert_target(root, name, {expected})
        if target is not None:
            expected = receipt["outputs"][target] if target in replaced else receipt["before"][target]
            assert_target(root, target, {expected})
    try:
        for name in receipt["outputs"]:
            atomic_write(inside(root, name), payload[name], before_replace=lambda name=name: guard(name))
            replaced.add(name)
        guard()
        atomic_write(output / "transaction.json", encoded({"build_id": expected_id, "state": "applied"}))
    except BaseException as original:
        try:
            restore(root, output, receipt, snapshots)
        except (BuildError, OSError) as recovery_error:
            raise BuildError(f"apply stopped ({original}); {recovery_error}") from original
        raise
    return receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("build", "check", "apply", "recover"))
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--out", type=Path, default=Path("build/lexicon-runtime"))
    args = parser.parse_args()
    root, output = args.root.resolve(), args.out.resolve()
    try:
        if output == root or root.is_relative_to(output) or output.is_relative_to(root / "Lexicons") or output.is_relative_to(root / "lexicon-src"):
            raise BuildError("stage must not overwrite source evidence or runtime files")
        output.parent.mkdir(parents=True, exist_ok=True)
        if args.action in ("build", "check"):
            receipt = build(root, output)
            if args.action == "check":
                for name, expected in receipt["outputs"].items():
                    if sha(inside(root, name).read_bytes()) != expected:
                        raise BuildError(f"approved generated runtime differs from repository: {name}")
        else:
            receipt = apply(root, output, recover=args.action == "recover")
        print(f"{args.action}: {receipt['build_id']} — {receipt['entry_counts']}")
        print(f"Receipt: {output / 'receipt.json'}")
        return 0
    except (BuildError, OSError, KeyError, TypeError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
