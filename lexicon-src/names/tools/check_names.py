"""Check a names research batch (FIN-906, phase 3). Brief: ../NAMES-GUIDE.md.

Usage (python3 3.9+, standard library only; run with -I):
  python3 -I tools/check_names.py out/n0001.json [--audio N] [--table]
      [--input in/n0001.json] [--binary PATH/ReadAloud]

The batch is a JSON array of entries:
  {"rank", "name", "language", "region", "disposition", "ipa", "us", "gb", "respelling",
   "source", "url", "confidence", "alternatives": [{"ipa", "us", "gb", "context"}], "notes",
   "transliteration"}
disposition: corrected | already-correct | unresolved | protect-word | not-a-name.

For every name it asks the app how it reads the name today (`ReadAloud --phonemize --explain`,
US and `--gb`), validates the phonemes (misaki symbols, stress, a GB form where British differs)
and compares yours with today's (`auto_verdict`). Writes <batch>.checked.json and exits 1 on
any ERROR. WARN lines are worth reading but don't fail the batch.

The matching input batch (`in/<id>.json`, found next to `out/` automatically, or --input) is
used to check that every name in it has exactly one entry, spelled exactly as given.

--audio N renders today's reading and yours for the first N corrected names with the app's own
voice ("Say NAME again.") into <batch>.audio/, and transcribes both with the app's dictation
model. That is a sanity signal only (garbled phonemes, a missing syllable): an English
dictation model hearing the name is never evidence that the reading is right.
--table prints one line per name: today's reading, yours and the verdict."""
import argparse, fcntl, json, os, re, subprocess, sys, tempfile, time
from collections import Counter

HERE = os.path.dirname(os.path.abspath(__file__))
# common.py sits next to this file in the research folder, or in lexicon-src/tools in the repo.
for _d in (HERE, os.path.join(os.path.dirname(os.path.dirname(HERE)), "tools")):
    if os.path.exists(os.path.join(_d, "common.py")):
        sys.path.insert(0, _d)
        break
from common import bad_symbols, auto_verdict, US_ONLY, VOWELS  # noqa: E402  (no misaki needed)

DEFAULT_BINARY = os.environ.get(
    "ALOUD_BINARY",
    "/Users/claremccormack/Sites/readaloud/.claude/worktrees/agent-a05f74969f302ee81/.build/release/ReadAloud")
DISPOSITIONS = ("corrected", "already-correct", "unresolved", "protect-word", "not-a-name")
CONFIDENCE = ("high", "medium", "low")
SAY, AGAIN = "sˈA", "əɡˈɛn"
STRESS = "ˈˌ"
# Vowels British usually writes differently from American (length, the LOT vowel).
GB_DIFFERS = set("ɑiuɔɜ")
AUDIO_SLOTS = 4
AUDIO_LOCKS = os.path.expanduser("~/Library/Caches/aloud-names/.audio_slots")


def blank(v):
    return v is None or (isinstance(v, str) and not v.strip()) or v == [] or v == {}


# ---------- the app ----------

def phonemize(binary, names, british):
    """{name: (phonemes, sources)} from the app, through temporary files."""
    args = [binary, "--phonemize", "--explain"] + (["--gb"] if british else [])
    with tempfile.TemporaryDirectory() as tmp:
        src, dst = os.path.join(tmp, "in.txt"), os.path.join(tmp, "out.txt")
        with open(src, "w", encoding="utf-8") as f:
            f.write("".join(n + "\n" for n in names))
        with open(src, "rb") as fin, open(dst, "wb") as fout:
            subprocess.run(args, stdin=fin, stdout=fout, stderr=subprocess.DEVNULL, check=True)
        out = {}
        with open(dst, encoding="utf-8") as f:
            for raw in f:
                parts = raw.rstrip("\n").split("\t")
                if len(parts) >= 2:
                    out[parts[0]] = (parts[1], parts[2] if len(parts) > 2 else "")
    return out


def source_label(sources):
    kinds = []
    for w in sources.split(" "):
        if "=" in w:
            k = w.rsplit("=", 1)[1]
            if k != "rule" and k not in kinds:
                kinds.append(k)
    return "+".join(kinds) or "none"


class Slot:
    """Machine-wide queue: at most AUDIO_SLOTS renders run at once (many agents share the Mac)."""
    def __enter__(self):
        os.makedirs(AUDIO_LOCKS, exist_ok=True)
        waited = False
        while True:
            for i in range(AUDIO_SLOTS):
                fh = open(os.path.join(AUDIO_LOCKS, f"slot{i}"), "w")
                try:
                    fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    self.fh = fh
                    return self
                except OSError:
                    fh.close()
            if not waited:
                print(f"waiting for a free audio slot (machine-wide queue of {AUDIO_SLOTS})...", flush=True)
                waited = True
            time.sleep(3)

    def __exit__(self, *exc):
        self.fh.close()


def render_and_transcribe(binary, ps, wav):
    r = subprocess.run([binary, "--render-phonemes", f"{SAY} {ps} {AGAIN}.", "--out", wav],
                       capture_output=True, text=True)
    if r.returncode or not os.path.exists(wav):
        return f"(render failed: {(r.stdout + r.stderr).strip()[:80]})"
    r = subprocess.run([binary, "--transcribe", wav], capture_output=True, text=True)
    m = re.search(r"real time\): (.*)$", r.stdout.strip())
    if not m:
        return f"(transcribe failed: {(r.stdout + r.stderr).strip()[:80]})"
    t = re.sub(r"^\s*say[\s,.]*", "", m.group(1), flags=re.I)
    return re.sub(r"[\s,.]*again[\s.!?]*$", "", t, flags=re.I).strip(" .,")


# ---------- notation ----------

def r_coloured(ps):
    """US r-colouring: ɹ right after a vowel and not before one (car, Carmen, Søren's US ɜɹ)."""
    s = ps.replace("ˈ", "").replace("ˌ", "")
    for i, c in enumerate(s):
        if c == "ɹ" and i and s[i - 1] in VOWELS and (i + 1 == len(s) or s[i + 1] not in VOWELS):
            return True
    return False


def move_stress(word):
    """Moves each stress mark to just before the next vowel (IPA puts it before the syllable)."""
    out, pending = [], ""
    for c in word:
        if c in STRESS:
            pending += c
            continue
        if pending and c in VOWELS:
            out.append(pending)
            pending = ""
        out.append(c)
    return "".join(out) + pending


def notation_problems(ps, british):
    """Errors in one phoneme string (US when british is False)."""
    side = "GB" if british else "US"
    out = []
    if ps.startswith("@"):
        return [f"{side} {ps!r}: shorthands (@...) aren't used for names; write the phonemes"]
    bad = bad_symbols(ps, british)
    if bad:
        out.append(f"{side} {ps!r} has symbols outside the misaki {side} set: {bad}")
    if british and set(ps) & US_ONLY:
        out.append(f"GB {ps!r} uses US-only symbols {sorted(set(ps) & US_ONLY)}")
    for word in ps.split():
        syllables = sum(c in VOWELS for c in word)
        primaries = word.count("ˈ")
        if primaries > 1:
            out.append(f"{side} {word!r} has {primaries} primary stresses; one per word")
        elif primaries == 0 and syllables > 1:
            out.append(f"{side} {word!r} has no primary stress ˈ")
        for i, c in enumerate(word):
            if c in STRESS and (i + 1 == len(word) or word[i + 1] not in VOWELS):
                out.append(f"{side} {word!r}: a stress mark must sit right before a vowel (misaki), "
                           f"not before the syllable's consonants: {move_stress(word)!r}?")
                break
    return out


def needs_gb(us):
    return bool(set(us) & US_ONLY) or r_coloured(us)


def check_reading(tag, us, gb, errs, warns, what="entry"):
    """Validates a us/gb pair; returns the GB the British voice would use."""
    for p in notation_problems(us, False):
        errs.append(f"{tag}: {what} {p}")
    if gb:
        for p in notation_problems(gb, True):
            errs.append(f"{tag}: {what} {p}")
        return gb
    if needs_gb(us):
        why = " ".join(sorted(set(us) & US_ONLY)) or "r-colouring after a vowel"
        errs.append(f"{tag}: {what} US {us!r} has US-only sounds ({why}) -> add a 'gb'")
        return None
    if set(us) & GB_DIFFERS:
        warns.append(f"{tag}: {what} has no 'gb': British voices will say {us!r} as written; "
                     f"British usually lengthens (iː uː ɑː ɔː ɜː) or uses ɒ here: add a 'gb' if so")
    return us


# ---------- main ----------

def find_input(batch_path, explicit):
    if explicit:
        return explicit
    d, base = os.path.split(os.path.abspath(batch_path))
    cand = os.path.join(os.path.dirname(d), "in", base)
    return cand if os.path.basename(d) == "out" and os.path.exists(cand) else None


def load_input(path):
    data = json.load(open(path, encoding="utf-8"))
    rows = data["names"] if isinstance(data, dict) else data
    return {r["name"]: r for r in rows}


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("batch")
    ap.add_argument("--input", help="the input batch (default: ../in/<same name> when the batch is in out/)")
    ap.add_argument("--binary", default=DEFAULT_BINARY, help="ReadAloud binary (or set ALOUD_BINARY)")
    ap.add_argument("--audio", type=int, default=0, metavar="N", help="render and transcribe the first N corrected names")
    ap.add_argument("--table", action="store_true", help="print one line per name")
    args = ap.parse_args()

    if not os.access(args.binary, os.X_OK):
        sys.exit(f"ReadAloud binary not found at {args.binary} (use --binary or ALOUD_BINARY)")
    try:
        entries = json.load(open(args.batch, encoding="utf-8"))
    except (OSError, ValueError) as ex:
        sys.exit(f"ERROR cannot read {args.batch}: {ex}")
    if not isinstance(entries, list):
        sys.exit("ERROR the batch must be a JSON array of entries")

    inp_path = find_input(args.batch, args.input)
    inp = load_input(inp_path) if inp_path else None

    names = [e.get("name") for e in entries if isinstance(e, dict) and isinstance(e.get("name"), str) and e.get("name").strip()]
    today_us = phonemize(args.binary, names, False) if names else {}
    today_gb = phonemize(args.binary, names, True) if names else {}

    errs, warns, out, seen = [], [], [], {}
    for i, e in enumerate(entries):
        if not isinstance(e, dict):
            errs.append(f"[{i}]: not an object")
            continue
        name = e.get("name") if isinstance(e.get("name"), str) else ""
        tag = f"[{i}] {name!r}"
        if not name.strip():
            errs.append(f"{tag}: missing name")
            continue
        if name in seen:
            errs.append(f"{tag}: duplicate of entry [{seen[name]}]")
        seen[name] = i
        if not isinstance(e.get("rank"), int):
            errs.append(f"{tag}: rank must be a number")
        row = inp.get(name) if inp is not None else None
        if inp is not None:
            if row is None:
                errs.append(f"{tag}: not in the input batch (spell it exactly as given; variants are separate names)")
            elif row.get("rank") != e.get("rank"):
                errs.append(f"{tag}: rank {e.get('rank')} but the input batch has {row.get('rank')}")

        disp = e.get("disposition")
        if disp not in DISPOSITIONS:
            errs.append(f"{tag}: disposition must be one of {'|'.join(DISPOSITIONS)}")
        conf = e.get("confidence")
        if not blank(conf) and conf not in CONFIDENCE:
            errs.append(f"{tag}: confidence must be high|medium|low")
        required = {"corrected": ["ipa", "us", "language", "source", "confidence"],
                    "already-correct": ["language", "source", "confidence"],
                    "unresolved": ["notes"], "not-a-name": ["notes"]}.get(disp, [])
        for k in required:
            if blank(e.get(k)):
                errs.append(f"{tag}: {disp} needs '{k}'")
        if disp == "corrected":
            for k in ("respelling", "url"):
                if blank(e.get(k)):
                    warns.append(f"{tag}: no '{k}'")
        if disp in ("corrected", "already-correct") and isinstance(e.get("ipa"), str) and re.search(r"[AIOQWYT]", e["ipa"]):
            warns.append(f"{tag}: ipa {e['ipa']!r} has capital letters: misaki symbols? 'ipa' is the source's IPA")
        if row is not None and row.get("bucket") == "unsupported-script" and disp != "not-a-name" \
                and blank(e.get("transliteration")):
            errs.append(f"{tag}: unsupported-script name needs 'transliteration' (the usual Latin spelling)")

        t_us, t_src = today_us.get(name, ("", ""))
        t_gb, t_src_gb = today_gb.get(name, ("", ""))
        if name not in today_us:
            errs.append(f"{tag}: the app returned no reading")
        r = dict(e)
        r.update(today_us=t_us, today_gb=t_gb, today_source=t_src, today_source_gb=t_src_gb,
                 today_label=source_label(t_src))

        us = e.get("us") if isinstance(e.get("us"), str) else ""
        gb = e.get("gb") if isinstance(e.get("gb"), str) else ""
        us, gb = us.strip(), gb.strip()
        if gb and not us:
            errs.append(f"{tag}: has 'gb' but no 'us'")
        if disp == "already-correct" and not us and not gb:
            # Today's reading is the intended one: nothing to write or check.
            r.update(us=t_us, gb=t_gb, gb_effective=t_gb, verdict_us="right", verdict_us_detail="today's reading",
                     verdict_gb="right", verdict_gb_detail="today's reading", changes_reading=False)
        elif us:
            gb_eff = check_reading(tag, us, gb, errs, warns)
            vu = auto_verdict(t_us, us)
            vg = auto_verdict(t_gb, gb_eff) if gb_eff else ("wrong", "no GB")
            r.update(us=us, gb=gb or "", gb_effective=gb_eff or "", verdict_us=vu[0], verdict_us_detail=vu[1],
                     verdict_gb=vg[0], verdict_gb_detail=vg[1])
            same = vu[0] == "right" and vg[0] == "right"
            r["changes_reading"] = not same
            if disp == "corrected" and same:
                warns.append(f"{tag}: already matches today's reading ({t_us} / {t_gb}): "
                             f"use already-correct instead")
            if disp == "already-correct" and not same:
                side = "US" if vu[0] != "right" else "GB"
                errs.append(f"{tag}: already-correct, but your {side} reading differs from today's "
                            f"({t_us} / {t_gb}, {vu[1] if side == 'US' else vg[1]}): use corrected, or leave us/gb empty")
        alts = e.get("alternatives", [])
        if alts in (None, ""):
            alts = []
        if not isinstance(alts, list):
            errs.append(f"{tag}: alternatives must be a list of objects")
            alts = []
        for j, a in enumerate(alts):
            if not isinstance(a, dict):
                errs.append(f"{tag}: alternative {j} must be an object")
                continue
            if blank(a.get("us")):
                errs.append(f"{tag}: alternative {j} needs 'us'")
            else:
                check_reading(tag, a["us"].strip(), (a.get("gb") or "").strip(), errs, warns, what=f"alternative {j}")
            if blank(a.get("context")):
                errs.append(f"{tag}: alternative {j} needs 'context' (who says it this way)")
        out.append(r)

    if inp is not None:
        missing = [f"{n} ({inp[n].get('rank')})" for n in inp if n not in seen]
        if missing:
            more = f" (+{len(missing) - 10} more)" if len(missing) > 10 else ""
            errs.append(f"{len(missing)} names in the input batch have no entry: {', '.join(missing[:10])}{more}")

    # ---------- audio (sanity signal only) ----------
    if args.audio > 0:
        adir = re.sub(r"\.json$", "", args.batch) + ".audio"
        os.makedirs(adir, exist_ok=True)
        todo = [r for r in out if r.get("disposition") == "corrected" and r.get("us")][:args.audio]
        print(f"audio: {len(todo)} names into {adir} (a sanity signal only, never evidence)")
        with Slot():
            for r in todo:
                safe = re.sub(r"[^\w-]", "_", r["name"])
                stem = os.path.join(adir, f"{r.get('rank', 0):06d}-{safe}")
                before = render_and_transcribe(args.binary, r["today_us"], stem + ".before.wav") \
                    if r["today_us"] and "❓" not in r["today_us"] else "(nothing today)"
                after = render_and_transcribe(args.binary, r["us"], stem + ".after.wav")
                r["asr_before"], r["asr_after"] = before, after
                print(f"  {r['name']}: before {r['today_us']} -> {before!r} | after {r['us']} -> {after!r}", flush=True)

    cp = re.sub(r"\.json$", "", args.batch) + ".checked.json"
    with open(cp, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, indent=1)
        f.write("\n")

    if args.table:
        for r in out:
            v = f"{r.get('verdict_us', '-')}/{r.get('verdict_gb', '-')}" if r.get("us") else "-"
            print(f"{r.get('rank', ''):>6} {r['name']:<20} {r.get('disposition', ''):<15} "
                  f"today {r['today_us']} / {r['today_gb']} ({r['today_label']})  ->  "
                  f"{r.get('us', '') or '-'} / {r.get('gb_effective', '') or '-'}  [{v}]")
    disp = Counter(r.get("disposition") for r in out)
    verd = Counter(r.get("verdict_us") for r in out if r.get("disposition") == "corrected" and r.get("verdict_us"))
    print(f"{len(entries)} entries, {len(errs)} errors, {len(warns)} warnings; "
          f"{dict(disp)}; corrected vs today (US): {dict(verd)}"
          + (f"; checked against {os.path.relpath(inp_path)}" if inp_path else "; no input batch to check against")
          + f"; wrote {cp}")
    for x in errs:
        print("ERROR", x)
    for x in warns:
        print("WARN ", x)
    sys.exit(1 if errs else 0)


if __name__ == "__main__":
    main()
