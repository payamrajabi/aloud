#!/usr/bin/env python3
"""Integrity, determinism and interrupted-apply checks, with isolated offline fixtures."""
import importlib.util
import contextlib
import io
import hashlib
import json
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("build_runtime", ROOT / "lexicon-src/tools/build_runtime.py")
build_runtime = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(build_runtime)
M = build_runtime


class RuntimeBuildTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / "repo"
        self.root.mkdir()
        self.out = self.root / "stage"
        for name in ("build_runtime.py", "check_packs.py", "vocab.json"):
            source = ROOT / "lexicon-src/tools" / name
            destination = self.root / "lexicon-src/tools" / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, destination)
        all_source = M.read_json(ROOT / "lexicon-src/tech-lexicon-10k.source.json")
        all_runtime = M.read_json(ROOT / "Lexicons/tech-lexicon.json")
        self.source = [row for row in all_source if row["word"] in ("JSON", "$HOME")]
        self.approved = [row for row in all_runtime if row["word"] in ("JSON", "$HOME")]
        self.runtime = json.dumps(self.approved, ensure_ascii=False, separators=(",", ":")).encode()
        entries = {}
        for row in self.approved:
            source = next(e for e in self.source if e["word"] == row["word"])
            before = M.project_tech(source)
            entries[row["word"]] = {"reason": "Verified fixture approval", "set": {k: v for k, v in row.items() if before.get(k) != v}, "remove": sorted(set(before) - set(row))}
        self.decisions = {"schema": 1, "entries": entries, "approved_runtime_sha256": M.sha(self.runtime)}
        self.registry = {"schema": 1, "packs": [{"id": "tech", "kind": "tech", "source": "lexicon-src/master.json", "decisions": "lexicon-src/delivery/decisions.json", "runtime": "Lexicons/tech-lexicon.json"}], "preserve": [], "conflicts": "lexicon-src/decisions/conflicts.json", "safety_decisions": ["lexicon-src/decisions/conflicts.json"]}
        self.write_json("lexicon-src/decisions/conflicts.json", [])
        self.write_json(M.REGISTRY, self.registry)
        self.update_source()
        M.atomic_write(self.root / "Lexicons/tech-lexicon.json", self.runtime)

    def write_json(self, name, value):
        M.atomic_write(self.root / name, M.encoded(value))

    def update_source(self):
        self.write_json("lexicon-src/master.json", self.source)
        self.decisions["source_sha256"] = M.sha((self.root / "lexicon-src/master.json").read_bytes())
        self.write_json("lexicon-src/delivery/decisions.json", self.decisions)

    def test_exact_baseline_and_repeatability(self):
        first = M.build(self.root, self.out)
        second = M.build(self.root, self.root / "stage2")
        self.assertEqual(first, second)
        self.assertEqual(self.runtime, (self.out / "runtime/Lexicons/tech-lexicon.json").read_bytes())
        self.assertEqual(first, M.build(self.root, self.out))
        self.assertIn("lexicon-src/master.json", first["inputs"])

    def test_schema_gates_and_locale_symbols(self):
        vocab = M.read_json(ROOT / "lexicon-src/tools/vocab.json")
        for field, value in (("us", "☃"), ("evidence", "false"), ("spoken_context_only", ["missing"]), ("pack_only", True), ("dictation", "surprise"), ("extra", "unknown")):
            with self.subTest(field=field), self.assertRaises(M.BuildError):
                M.validate([{**self.approved[0], field: value}], "tech", vocab)
        with self.assertRaises(M.BuildError):
            M.validate(self.approved * 2, "tech", vocab)

    def test_research_change_needs_reconciled_decisions(self):
        self.write_json("lexicon-src/master.json", self.source + [self.source[0]])
        with self.assertRaisesRegex(M.BuildError, "source changed"):
            M.build(self.root, self.out)
        self.assertFalse(self.out.exists())

    def test_invalid_phones_never_produce_an_applicable_stage(self):
        self.source[0]["us"] = "☃"
        self.update_source()
        with self.assertRaisesRegex(M.BuildError, "unsupported"):
            M.build(self.root, self.out)
        self.assertFalse(self.out.exists())
        self.assertEqual(self.runtime, (self.root / "Lexicons/tech-lexicon.json").read_bytes())

    def test_stale_decision_and_pronunciation_override_refused(self):
        self.decisions["entries"]["missing"] = {"reason": "not in master"}
        self.update_source()
        with self.assertRaisesRegex(M.BuildError, "stale decisions"):
            M.build(self.root, self.out)
        del self.decisions["entries"]["missing"]
        self.decisions["entries"]["JSON"]["set"]["us"] = "hˈOm"
        self.update_source()
        with self.assertRaisesRegex(M.BuildError, "safety fields"):
            M.build(self.root, self.out)

    def test_conflict_has_to_be_recorded(self):
        self.registry["preserve"] = ["Lexicons/peer.json"]
        self.write_json(M.REGISTRY, self.registry)
        self.write_json("Lexicons/peer.json", [{"word": "JSON", "match": "case-insensitive", "us": "hˈOm"}])
        with self.assertRaisesRegex(M.BuildError, "conflict validation"):
            M.build(self.root, self.out)
        self.assertFalse(self.out.exists())

    def test_inputs_changed_after_validation_block_apply(self):
        M.build(self.root, self.out)
        self.write_json("lexicon-src/master.json", self.source + [self.source[0]])
        with self.assertRaisesRegex(M.BuildError, "input changed"):
            M.apply(self.root, self.out)
        self.assertEqual(self.runtime, (self.root / "Lexicons/tech-lexicon.json").read_bytes())

    def test_undeclared_pack_cannot_bypass_release_validation(self):
        M.build(self.root, self.out)
        self.write_json("Lexicons/undeclared.json", [{"word": "JSON", "match": "case-insensitive", "us": "hˈOm"}])
        with self.assertRaisesRegex(M.BuildError, "inventory changed"):
            M.apply(self.root, self.out)
        with self.assertRaisesRegex(M.BuildError, "inventory changed"):
            M.build(self.root, self.root / "new-stage")

    def test_runtime_edited_after_staging_is_preserved(self):
        M.build(self.root, self.out)
        edited = b"[]\n"
        M.atomic_write(self.root / "Lexicons/tech-lexicon.json", edited)
        with self.assertRaisesRegex(M.BuildError, "runtime changed"):
            M.apply(self.root, self.out)
        with self.assertRaisesRegex(M.BuildError, "neither before nor generated"):
            M.apply(self.root, self.out, recover=True)
        self.assertEqual(edited, (self.root / "Lexicons/tech-lexicon.json").read_bytes())

    def test_staged_output_and_recovery_integrity(self):
        M.build(self.root, self.out)
        output = self.out / "runtime/Lexicons/tech-lexicon.json"
        M.atomic_write(output, b"[]")
        with self.assertRaisesRegex(M.BuildError, "stage changed"):
            M.apply(self.root, self.out)
        M.atomic_write(output, self.runtime)
        M.atomic_write(self.out / "before/Lexicons/tech-lexicon.json", b"[]")
        with self.assertRaisesRegex(M.BuildError, "snapshot changed"):
            M.apply(self.root, self.out, recover=True)

    def test_failed_multifile_apply_restores_first_file(self):
        spec = {**self.registry["packs"][0], "id": "copy", "runtime": "Lexicons/copy.json"}
        self.registry["packs"].append(spec)
        self.write_json(M.REGISTRY, self.registry)
        original = M.encoded(self.approved)
        M.atomic_write(self.root / "Lexicons/tech-lexicon.json", original)
        M.atomic_write(self.root / "Lexicons/copy.json", original)
        M.build(self.root, self.out)
        real_write = M.atomic_write
        failed = False
        def failing_write(path, data):
            nonlocal failed
            if path.resolve() == (self.root / "Lexicons/tech-lexicon.json").resolve() and data == self.runtime and not failed:
                failed = True
                raise OSError("simulated interruption after first target replacement")
            real_write(path, data)
        with patch.object(M, "atomic_write", side_effect=failing_write), self.assertRaises(OSError):
            M.apply(self.root, self.out)
        self.assertTrue(failed)
        for name in ("tech-lexicon", "copy"):
            self.assertEqual(original, (self.root / f"Lexicons/{name}.json").read_bytes())
        self.assertEqual("recovered", M.read_json(self.out / "transaction.json")["state"])

    def test_recover_after_process_disappeared_mid_apply(self):
        original = M.encoded(self.approved)
        M.atomic_write(self.root / "Lexicons/tech-lexicon.json", original)
        M.build(self.root, self.out)
        # Simulate a process death after replacing its target, before writing final journal state.
        M.atomic_write(self.root / "Lexicons/tech-lexicon.json", self.runtime)
        M.apply(self.root, self.out, recover=True)
        self.assertEqual(original, (self.root / "Lexicons/tech-lexicon.json").read_bytes())

    def test_duplicate_json_keys_and_path_escape_refused(self):
        file = self.root / "duplicate.json"
        M.atomic_write(file, b'{"word":"one","word":"two"}')
        with self.assertRaisesRegex(M.BuildError, "duplicate JSON key"):
            M.read_json(file)
        with self.assertRaises(M.BuildError):
            M.inside(self.root, "../outside.json")
        with self.assertRaises(M.BuildError):
            M.runtime_path("lexicon-src/master.json")


class NamesBuildTests(unittest.TestCase):
    def setUp(self):
        self.master = M.read_json(ROOT / "lexicon-src/names/names.source.json")
        self.decisions = M.read_json(ROOT / "lexicon-src/delivery/names-runtime.decisions.json")
        self.manifest = (ROOT / "lexicon-src/names/manifest.tsv").read_bytes()

    def test_current_approved_names_and_honest_scope_counts(self):
        rows, coverage = M.compile_names(self.master, self.decisions, self.manifest)
        approved = M.read_json(ROOT / "Lexicons/names.json")
        self.assertEqual(approved, rows)
        self.assertEqual(5000, coverage["ranked_candidates_with_research"] + coverage["ranked_candidates_without_research"])
        self.assertEqual(4726, sum(coverage["all_researched_dispositions"].values()))
        self.assertEqual(76, coverage["existing_special_candidates_outside_ranks"])
        self.assertEqual(72, coverage["existing_special_corrections_outside_ranks"])
        self.assertNotIn("Sui", {row["word"] for row in rows})
        self.assertIn("PAH-yuhm", next(row["respelling"] for row in self.master["entries"] if row["name"] == "Payam"))

    def test_scope_manifest_and_recorded_validation_cannot_be_bypassed(self):
        self.decisions["scope"]["rank_limit"] = 100000
        with self.assertRaisesRegex(M.BuildError, "limited"):
            M.compile_names(self.master, self.decisions, self.manifest)
        self.decisions["scope"]["rank_limit"] = 5000
        extra = next(row for row in self.master["entries"] if row.get("rank", 0) > 5000)
        extra["batch"] = "n9999"
        with self.assertRaisesRegex(M.BuildError, "outside first-5000"):
            M.compile_names(self.master, self.decisions, self.manifest)
        extra["batch"] = "p0001"
        row = next(row for row in self.master["entries"] if row["shipped"])
        row["after"]["us_sentence"] = "wrong"
        with self.assertRaisesRegex(M.BuildError, "evidence disagrees"):
            M.compile_names(self.master, self.decisions, self.manifest)

    def test_duplicate_manifest_and_names_never_silently_replace(self):
        header, first, rest = self.manifest.split(b"\n", 2)
        with self.assertRaisesRegex(M.BuildError, "duplicate manifest"):
            M.compile_names(self.master, self.decisions, header + b"\n" + first + b"\n" + first + b"\n" + rest)
        self.master["entries"].append(self.master["entries"][0])
        with self.assertRaisesRegex(M.BuildError, "duplicate source"):
            M.compile_names(self.master, self.decisions, self.manifest)


class EvidenceArchiveTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        self.repo, self.cache, self.out = (self.base / name for name in ("repo", "cache", "private"))
        self.repo.mkdir()
        source = self.repo / "lexicon-src/names"
        source.mkdir(parents=True)
        (source / "names.source.json").write_text('{"batches":{"n0001":1}}')
        raw = self.cache / "run-20261008/data.txt"
        raw.parent.mkdir(parents=True)
        raw.write_bytes(b"original reference")
        self.reference = raw
        (source / "sources.lock.json").write_text(json.dumps({"files": {"data.txt": {"sha256": hashlib.sha256(raw.read_bytes()).hexdigest()}}}))
        batch = self.cache / "research/out"
        batch.mkdir(parents=True)
        for suffix in ("json", "checked.json"):
            (batch / ("n0001." + suffix)).write_bytes(b"[]")
        spec = importlib.util.spec_from_file_location("archive", ROOT / "lexicon-src/tools/archive_names_evidence.py")
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)
        self.module.ROOT = self.repo

    def run_archive(self, out=None):
        with patch("sys.argv", ["archive", "--cache", str(self.cache), "--out", str(out or self.out)]), contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            return self.module.main()

    def test_resume_checks_original_bytes_and_retains_private_permissions(self):
        self.assertEqual(0, self.run_archive())
        manifest = (self.out / "evidence-manifest.json").read_bytes()
        self.assertEqual(0, self.run_archive())
        self.assertEqual(manifest, (self.out / "evidence-manifest.json").read_bytes())
        self.assertEqual(0o700, self.out.stat().st_mode & 0o777)
        self.assertEqual(0o600, (self.out / "run-20261008/data.txt").stat().st_mode & 0o777)
        self.assertEqual(b"original reference", self.reference.read_bytes())

    def test_corrupt_archive_is_never_overwritten(self):
        self.assertEqual(0, self.run_archive())
        target = self.out / "run-20261008/data.txt"
        target.write_bytes(b"later private edit")
        self.assertEqual(1, self.run_archive())
        self.assertEqual(b"later private edit", target.read_bytes())

    def test_source_lock_and_repository_boundary_block_unsafe_archive(self):
        self.assertEqual(1, self.run_archive(self.repo / "evidence"))
        self.reference.write_bytes(b"changed reference")
        self.assertEqual(1, self.run_archive())
        self.assertFalse(self.out.exists())


if __name__ == "__main__":
    unittest.main()
