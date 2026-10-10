#!/usr/bin/env python3
"""Integrity, determinism and interrupted-apply checks, with isolated offline fixtures."""
import importlib.util
import contextlib
import io
import hashlib
import subprocess
import sys
import selectors
import time
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
        with self.assertRaisesRegex(M.BuildError, "neither the expected original nor generated"):
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
        def failing_write(path, data, **options):
            nonlocal failed
            if path.resolve() == (self.root / "Lexicons/tech-lexicon.json").resolve() and data == self.runtime and not failed:
                failed = True
                raise OSError("simulated interruption after first target replacement")
            real_write(path, data, **options)
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

    def multiple_targets(self):
        self.registry["packs"].append({**self.registry["packs"][0], "id": "copy", "runtime": "Lexicons/copy.json"})
        self.write_json(M.REGISTRY, self.registry)
        original = M.encoded(self.approved)
        for name in ("copy", "tech-lexicon"):
            M.atomic_write(self.root / f"Lexicons/{name}.json", original)
        M.build(self.root, self.out)
        return original

    def test_real_concurrent_apply_and_recover_fail_fast(self):
        original = M.encoded(self.approved)
        M.atomic_write(self.root / "Lexicons/tech-lexicon.json", original)
        M.build(self.root, self.out)
        child_code = """
import importlib.util, pathlib, sys
spec = importlib.util.spec_from_file_location('runtime', sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
root, output = pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3])
real = m.atomic_write
waiting = True
def pause(path, data, **options):
    global waiting
    if path == root / 'Lexicons/tech-lexicon.json' and waiting:
        waiting = False
        print('locked apply', flush=True)
        sys.stdin.readline()
    real(path, data, **options)
m.atomic_write = pause
m.apply(root, output)
"""
        child = subprocess.Popen([sys.executable, "-B", "-I", "-c", child_code,
                                  str(ROOT / "lexicon-src/tools/build_runtime.py"),
                                  str(self.root.resolve()), str(self.out.resolve())],
                                 stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            with selectors.DefaultSelector() as ready:
                ready.register(child.stdout, selectors.EVENT_READ)
                self.assertTrue(ready.select(5), "child failed to reach locked apply")
            self.assertEqual("locked apply", child.stdout.readline().strip())
            for recover in (False, True):
                started = time.monotonic()
                with self.assertRaisesRegex(M.BuildError, "publisher owns"):
                    M.apply(self.root, self.out, recover=recover)
                self.assertLess(time.monotonic() - started, 2)
            self.assertEqual(original, (self.root / "Lexicons/tech-lexicon.json").read_bytes())
            self.assertEqual("prepared", M.read_json(self.out / "transaction.json")["state"])
            _, error = child.communicate("release\n", timeout=5)
            self.assertEqual(0, child.returncode, error)
        finally:
            if child.poll() is None:
                child.kill()
                child.communicate()
        # Same stable lock file works again after process exit; it is never unlinked.
        M.apply(self.root, self.out, recover=True)
        self.assertEqual(original, (self.root / "Lexicons/tech-lexicon.json").read_bytes())

    def test_mid_transaction_edit_is_preserved_and_eligible_file_rolls_back(self):
        original = self.multiple_targets()
        edited = b"external edit made between target replacements"
        real = M.atomic_write
        def edit_after_first(path, data, **options):
            real(path, data, **options)
            if path == self.root.resolve() / "Lexicons/copy.json" and data == self.runtime:
                real(self.root / "Lexicons/tech-lexicon.json", edited)
        with patch.object(M, "atomic_write", side_effect=edit_after_first), self.assertRaisesRegex(M.BuildError, "recovery preserved"):
            M.apply(self.root, self.out)
        self.assertEqual(original, (self.root / "Lexicons/copy.json").read_bytes())
        self.assertEqual(edited, (self.root / "Lexicons/tech-lexicon.json").read_bytes())
        journal = M.read_json(self.out / "transaction.json")
        self.assertEqual("recovery_required", journal["state"])
        self.assertEqual(["Lexicons/copy.json"], journal["restored"])
        self.assertIn("Lexicons/tech-lexicon.json", journal["preserved_or_pending"])

    def test_edit_to_already_replaced_file_is_detected_before_next_write(self):
        original = self.multiple_targets()
        edited = b"external edit to already published first target"
        real = M.atomic_write
        def edit_first(path, data, **options):
            real(path, data, **options)
            if path == self.root.resolve() / "Lexicons/copy.json" and data == self.runtime:
                real(path, edited)
        with patch.object(M, "atomic_write", side_effect=edit_first), self.assertRaisesRegex(M.BuildError, "recovery preserved"):
            M.apply(self.root, self.out)
        self.assertEqual(edited, (self.root / "Lexicons/copy.json").read_bytes())
        self.assertEqual(original, (self.root / "Lexicons/tech-lexicon.json").read_bytes())

    def test_edit_during_rollback_is_checked_immediately_before_replace(self):
        original = self.multiple_targets()
        edited = b"external edit during rollback temp-file write"
        real = M.atomic_write
        failed = False
        def interrupt_and_edit(path, data, **options):
            nonlocal failed
            target = self.root.resolve() / "Lexicons/tech-lexicon.json"
            if path == target and data == self.runtime and not failed:
                failed = True
                raise OSError("second target interrupted")
            if path == target and data == original and failed:
                real(path, edited)
            real(path, data, **options)
        with patch.object(M, "atomic_write", side_effect=interrupt_and_edit), self.assertRaisesRegex(M.BuildError, "recovery preserved"):
            M.apply(self.root, self.out)
        self.assertEqual(original, (self.root / "Lexicons/copy.json").read_bytes())
        self.assertEqual(edited, (self.root / "Lexicons/tech-lexicon.json").read_bytes())
        self.assertEqual("recovery_required", M.read_json(self.out / "transaction.json")["state"])

    def test_input_change_mid_transaction_freezes_mutation_until_reconciled(self):
        original = self.multiple_targets()
        changed_source = b"[]"
        real = M.atomic_write
        def change_source(path, data, **options):
            real(path, data, **options)
            if path == self.root.resolve() / "Lexicons/copy.json" and data == self.runtime:
                real(self.root / "lexicon-src/master.json", changed_source)
        with patch.object(M, "atomic_write", side_effect=change_source), self.assertRaisesRegex(M.BuildError, "input changed"):
            M.apply(self.root, self.out)
        self.assertEqual(self.runtime, (self.root / "Lexicons/copy.json").read_bytes())
        self.assertEqual(original, (self.root / "Lexicons/tech-lexicon.json").read_bytes())
        self.assertEqual(changed_source, (self.root / "lexicon-src/master.json").read_bytes())
        self.assertEqual("recovery_required", M.read_json(self.out / "transaction.json")["state"])

    def test_pack_inventory_change_mid_transaction_blocks_further_replaces(self):
        original = self.multiple_targets()
        real = M.atomic_write
        extra = b"external new pack"
        def add_pack(path, data, **options):
            real(path, data, **options)
            if path == self.root.resolve() / "Lexicons/copy.json" and data == self.runtime:
                real(self.root / "Lexicons/undeclared.json", extra)
        with patch.object(M, "atomic_write", side_effect=add_pack), self.assertRaisesRegex(M.BuildError, "inventory changed"):
            M.apply(self.root, self.out)
        self.assertEqual(self.runtime, (self.root / "Lexicons/copy.json").read_bytes())
        self.assertEqual(original, (self.root / "Lexicons/tech-lexicon.json").read_bytes())
        self.assertEqual(extra, (self.root / "Lexicons/undeclared.json").read_bytes())
        self.assertEqual("recovery_required", M.read_json(self.out / "transaction.json")["state"])

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
        self.assertEqual({"name"}, {row["match"] for row in rows})
        self.assertEqual(5000, coverage["ranked_candidates_with_research"] + coverage["ranked_candidates_without_research"])
        self.assertEqual(4726, sum(coverage["all_researched_dispositions"].values()))
        self.assertEqual(76, coverage["existing_special_candidates_outside_ranks"])
        self.assertEqual(72, coverage["existing_special_corrections_outside_ranks"])
        self.assertNotIn("Sui", {row["word"] for row in rows})
        self.assertIn("PAH-yuhm", next(row["respelling"] for row in self.master["entries"] if row["name"] == "Payam"))

    def test_names_cannot_regress_to_plural_matching(self):
        vocab = M.read_json(ROOT / "lexicon-src/tools/vocab.json")
        row = M.read_json(ROOT / "Lexicons/names.json")[0]
        for match in ("case-sensitive", "case-insensitive", "exact"):
            with self.subTest(match=match), self.assertRaisesRegex(M.BuildError, "possessive-only"):
                M.validate([{**row, "match": match}], "names", vocab)

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
