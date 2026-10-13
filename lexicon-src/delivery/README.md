# Approved research → runtime delivery (FIN-888)

Run from the repository root with Python 3.9 or later. No network, third-party dependencies,
voice/model loading, new research, or automatic publication is involved.

```
python3 -B -I lexicon-src/tools/build_runtime.py check --out build/lexicon-runtime
python3 -B -I Tests/lexicon-pipeline/test_runtime.py
```

`check` builds a private staging directory and requires byte-for-byte agreement with the
approved runtime and the repository's current pack files. `receipt.json` records every
source/tool/decision input hash, output hashes, pack counts, ordinary-word conflict decisions,
honest first-5,000 coverage, and the hashes of recoverable original files. Repeating a build
from identical inputs gives the same files and receipt, independent of the output directory.
The committed `baseline-receipt.json` is the reviewed baseline build receipt.
A changed input requires a new stage; an existing different stage is preserved.

The registry references the existing research masters and their tags; it does not duplicate
or rewrite research. Tech categories and names' language/region/alternatives remain in those
masters. Only runtime fields reach `Lexicons/`. The original batch merger remains a historical
research tool; this delivery build does not need its untracked batches, external stack or
word-frequency dependencies.

## Why the explicit tech decisions exist

The tech master retains original research variants. The approved runtime also contains later
reviewed exclusions and context gates that the historical merger's committed inputs cannot
fully reconstruct. `tech-runtime.decisions.json` captures **3,003 existing per-word safety
choices** from approved commit `0bd9fb7`, whose runtime matched installed beta5 byte-for-byte.
This is a migration of compiled safety decisions, not invented pronunciation research. Decisions
may change only spoken variants, variant context gates or evidence flags; they cannot override
pronunciation. The source and approved runtime hashes are pinned. JSON/Jason remains context-gated,
and `$HOME` does not acquire the rejected ordinary phrase “dollar home.”

Changing approved research or a reading requires reconciling its evidence/decisions and obtaining
a reviewed new approval hash before building. Do not simply edit the hash to make a failure pass.
For a new approved tech safety choice, compare the old projected fields with the reviewed runtime,
record only the changed safety fields in `set`/`remove`, and retain a specific reason. The pinned
runtime hash makes unnoticed filtering or serialization changes fail closed.

## Names scope and existing owner decisions

The stable `cbd4e29` names source preserves Payam's PAH-yuhm choice, Rayan's corresponding GB
reading, Sui's owner hold, original research readings and before/after evidence. The delivery
compiler uses that approved master directly. It never invokes the batch research/assembly tool,
rejudges a name, or extends the corpus. Names keep exact casing, accept possessives only, and
remain pronunciation-only. The FIN-906 matching change leaves all approved readings intact;
it prevents short names from taking the initial letters of ordinary words such as "This".

The first 5,000 ranked candidates currently have **4,650 research records and 350 without a
research record**. Their 2,781 shipped corrections, 1,480 already-correct records, 13 held,
53 unresolved, 319 protected words and 4 non-names are distinct counts. The existing approved
Persian `p0001` batch also has 76 records outside this ranking, of which 72 corrections already
ship; these remain preserved and are reported separately. They do not count toward first-5,000
coverage. No new listening exercise has been performed or claimed.

Irish names are an existing unchanged peer pack. Its bytes are preserved and validated alongside
the generated tech/names files. It is not rebuilt from invented research. Canceled specialist
packs, messaging research, and the remaining names wave are not added by this registry.

## Apply and recovery

```
python3 -B -I lexicon-src/tools/build_runtime.py apply --out build/lexicon-runtime
python3 -B -I lexicon-src/tools/build_runtime.py recover --out build/lexicon-runtime
```

`apply` only replaces generated repository pack files after every staged pack, conflict,
input hash, before snapshot and current target has passed validation. It buffers verified
bytes, writes a prepared transaction journal, atomically replaces each file and records success.
It never installs an app or publishes a release. A failure restores eligible original files while
preserving subsequent external edits; `transaction.json` records any remaining manual reconciliation. If the
process disappears between files, run `recover` using the same stage. Recovery refuses to erase
a later edit whose hash matches neither the original nor the generated file. Preserve that edit
and reconcile it manually. Keep the stage until the acceptance/release gates are satisfied.

Apply and recovery use one fail-fast exclusive filesystem lock per checkout:
`build/.lexicon-runtime.lock`. Every cooperating publisher must enter through these commands.
The lock file remains in place; never delete it to bypass a running publisher. The operating
system releases the lock when the holder exits. A second apply/recover fails immediately and
can be retried after the first finishes. Different output-stage directories still share the
same repository lock.

Before every target replacement, the builder rechecks input hashes, the complete pack inventory,
and the expected state of runtime targets, then checks the relevant target again immediately
before `os.replace`. Rollback/recovery checks each relevant target before replacing it and
preserves a later external edit rather than overwriting it. Eligible files can be restored while
changed files are left intact; the journal becomes `recovery_required` and lists restored files
and preserved/pending files. If inputs or pack inventory change partway through, automatic
replacement stops, including recovery. Preserve the stage and reconcile the source/inventory
with its recorded hashes before retrying, or recover the recorded original bytes manually
after reviewing the intervening changes.

This assumes a **single cooperating publisher** and no concurrent external edits to source or
runtime files. Hash rechecks detect edits at their check points; the filesystem has no atomic
compare-and-swap for file contents, so an editor that ignores the lock can still write between
the final check and `os.replace`. Likewise, a reader can observe a mix of pack versions between
per-file replacements. This tool does not lock application readers or replace the entire bundle
atomically. Use it in an isolated, quiescent checkout before packaging the app, and preserve
unexpected edits for reconciliation. The tests exercise competing real processes and edits
in the apply/rollback windows, without claiming protection against noncooperating writers.

## Private original evidence preservation

```
python3 -B -I lexicon-src/tools/archive_names_evidence.py \
  --cache "$HOME/Library/Caches/aloud-names" \
  --out /a/private/durable/directory/outside/the/repository
```

This preserves only existing master-listed checked/raw batches, their existing review/audio
files, prior listening artifacts, and the original dataset files recorded by `sources.lock.json`.
The input dataset hashes must match the source lock. Original files are never moved or modified.
Completed copied files are hash-verified; interrupted runs resume without replacing differing
files. The directory is private (0700) and files are 0600. `evidence-manifest.json` appears only
when all files have been copied and verified. Treat the archive as private recovery material;
redistribution requires checking individual source licences and private listening content.
The archived batch/reference data can be restored to a separate research folder when necessary;
ordinary runtime builds need only the committed approved masters and decisions.

## Remaining release gates

This pipeline proves integrity and approved-byte reproduction. It does not establish subjective
listening quality, real Mac app matching/latency, personal override precedence in the running app,
notarization, Sparkle signing, public deployment or successful customer updating. Verify those
with the integrated application build and attach its commit/build/release evidence separately.
