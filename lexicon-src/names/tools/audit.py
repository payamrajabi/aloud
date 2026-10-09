"""Baseline audit and triage of the candidate names (FIN-906, phase 2).

Usage (from the repository root, after `swift build -c release`):
  python3 -I lexicon-src/names/tools/audit.py [--manifest lexicon-src/names/manifest.tsv]
      [--binary .build/release/ReadAloud] [--wordfreq PATH/large_en.msgpack.gz]
      [--sample 30 --seed 906]

For every name in the manifest it records how Aloud reads it today, US and GB, alone and in
the carrier sentence "I met NAME yesterday." (casing and position can change a reading),
with the source that read it (`--phonemize --explain`): the custom lexicon, the misaki gold
dictionary, CMUdict or the mini-bart guesser. Then it flags names that are also ordinary
English words and sorts every name into one triage bucket (see ../README.md).

Writes ../ledger.tsv (one row per candidate), ../coverage.json (totals, and the spot-check
accuracy from ../spotcheck.tsv), and, with --sample, draws a fresh spot-check sample into
../spotcheck.tsv (verdicts left blank for a person to fill in; existing verdicts are kept).

`--wordfreq` points at wordfreq's English data (wordfreq 3.1.1, CC BY-SA 4.0, by Robyn
Speer); it only grades collision words as common / uncommon / rare, and no frequency figures
are written out. Without it every collision is graded "unknown". Plain python3, standard
library only."""
import argparse, gzip, json, os, random, re, struct, subprocess, sys, tempfile, threading, unicodedata
from collections import Counter, defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
NAMES = os.path.dirname(HERE)
ROOT = os.path.dirname(os.path.dirname(NAMES))
CARRIER = "I met {} yesterday."
BUCKETS = ["covered-by-lexicon", "lexicon-term-reading", "unsupported-script", "collision-word", "guesser-reading",
           "dictionary-reading-needs-check", "dictionary-reading-likely-right"]
# What each bucket's assumption predicts a checked reading to be.
EXPECT = {"covered-by-lexicon": "right", "lexicon-term-reading": "wrong", "unsupported-script": "wrong",
          "collision-word": "right", "guesser-reading": "wrong", "dictionary-reading-needs-check": "wrong",
          "dictionary-reading-likely-right": "right"}
# A tech-list entry reads a name on purpose when it is a person, or a product said like the name.
NAME_LIKE = re.compile(r"like the (given |first )?name|named (after|like)|the given name|ordinary (word/)?name|same as the name",
                       re.I)
ASSUMPTION = {
    "covered-by-lexicon": "today's reading is right (a person chose it, for this name)",
    "lexicon-term-reading": "a tech term's reading, made for the term, not the name: needs a check",
    "unsupported-script": "the voice says nothing for it today",
    "collision-word": "today's reading is the ordinary word's, and the name sounds like the word (so the fix is protection, not correction)",
    "guesser-reading": "a guess: needs research",
    "dictionary-reading-needs-check": "a dictionary reading that may be anglicised: needs a check",
    "dictionary-reading-likely-right": "an English-usage name read from a dictionary: likely right",
}


# ---------- reading today ----------

def phonemize(binary, lines, british):
    """Runs `binary --phonemize --explain` once over all lines (through temporary files, not
    pipes); returns {line: (phonemes, sources)}."""
    args = [binary, "--phonemize", "--explain"] + (["--gb"] if british else [])
    with tempfile.TemporaryDirectory() as tmp:
        src, dst = os.path.join(tmp, "in.txt"), os.path.join(tmp, "out.txt")
        with open(src, "w", encoding="utf-8") as f:
            f.write("".join(line + "\n" for line in lines))
        with open(src, "rb") as fin, open(dst, "wb") as fout:
            subprocess.run(args, stdin=fin, stdout=fout, stderr=subprocess.DEVNULL, cwd=ROOT, check=True)
        out = {}
        with open(dst, encoding="utf-8") as f:
            for raw in f:
                parts = raw.rstrip("\n").split("\t")
                if len(parts) >= 2:
                    out[parts[0]] = (parts[1], parts[2] if len(parts) > 2 else "")
    missing = sum(1 for line in lines if line not in out)
    if missing:
        raise SystemExit(f"{missing} lines came back without a reading ({'GB' if british else 'US'})")
    return out


def name_part(sentence_ps):
    """The name's phonemes inside the carrier's: between "met" and "yesterday"."""
    m = re.match(r"^\S*I m\S*t (.*) j\S*st\S*\.$", sentence_ps)
    return m.group(1) if m else sentence_ps


def sentence_sources(sources):
    words = sources.split(" ")
    # "I=gold met=gold <name words> yesterday=gold .=rule"
    if len(words) >= 4 and words[0].startswith("I=") and words[1].startswith("met="):
        words = words[2:]
        while words and (words[-1].startswith(".=") or words[-1].startswith("yesterday=")):
            words.pop()
    return " ".join(words)


def source_label(sources):
    kinds = []
    for w in sources.split(" "):
        if "=" in w:
            k = w.rsplit("=", 1)[1]
            if k != "rule" and k not in kinds:
                kinds.append(k)
    return "+".join(kinds) or "none"


# ---------- word lists ----------

def msgpack(data):
    """A tiny msgpack decoder: enough for wordfreq's data (arrays, maps, strings, ints)."""
    pos = 0
    def take(n):
        nonlocal pos
        b = data[pos:pos + n]
        pos += n
        return b
    def read():
        t = take(1)[0]
        if t <= 0x7f: return t
        if 0x80 <= t <= 0x8f: return {read(): read() for _ in range(t & 0x0f)}
        if 0x90 <= t <= 0x9f: return [read() for _ in range(t & 0x0f)]
        if 0xa0 <= t <= 0xbf: return take(t & 0x1f).decode("utf-8")
        if t == 0xc0: return None
        if t in (0xc2, 0xc3): return t == 0xc3
        if t in (0xc4, 0xc5, 0xc6): return take(struct.unpack(">" + "BHI"[t - 0xc4], take(1 << (t - 0xc4)))[0])
        if t in (0xcc, 0xcd, 0xce, 0xcf): return struct.unpack(">" + "BHIQ"[t - 0xcc], take(1 << (t - 0xcc)))[0]
        if t in (0xd0, 0xd1, 0xd2, 0xd3): return struct.unpack(">" + "bhiq"[t - 0xd0], take(1 << (t - 0xd0)))[0]
        if t in (0xd9, 0xda, 0xdb): return take(struct.unpack(">" + "BHI"[t - 0xd9], take(1 << (t - 0xd9)))[0]).decode("utf-8")
        if t in (0xdc, 0xdd): return [read() for _ in range(struct.unpack(">" + "HI"[t - 0xdc], take(2 << (t - 0xdc)))[0])]
        if t in (0xde, 0xdf): return {read(): read() for _ in range(struct.unpack(">" + "HI"[t - 0xde], take(2 << (t - 0xde)))[0])}
        if t >= 0xe0: return t - 0x100
        raise ValueError(f"msgpack type {t:#x} not supported")
    return read()


def load_zipf(path):
    """wordfreq's cBpack: [header, words at 0 cB, words at -1 cB, ...]; Zipf = 9 + cB/100."""
    if not path:
        return None
    packed = msgpack(gzip.open(path).read())
    zipf = {}
    for i, words in enumerate(packed[1:]):
        for w in words:
            zipf.setdefault(w, 9 - i / 100)
    return zipf


def tier(z):
    if z is None:
        return "unknown"
    return "common" if z >= 4.0 else "uncommon" if z >= 3.0 else "rare"


def load_lexicons():
    """lower-cased word -> [(file id, word, match, reads the name on purpose)]."""
    notes = {}
    src = os.path.join(ROOT, "lexicon-src", "tech-lexicon-10k.source.json")
    if os.path.exists(src):
        for e in json.load(open(src, encoding="utf-8")):
            notes[e["word"]] = e.get("category") == "person" or bool(NAME_LIKE.search(e.get("source", "")))
    entries = defaultdict(list)
    lexdir = os.path.join(ROOT, "Lexicons")
    for f in sorted(os.listdir(lexdir)):
        if f.endswith(".json"):
            data = json.load(open(os.path.join(lexdir, f), encoding="utf-8"))
            if isinstance(data, dict):
                data = data.get("entries", data.get("words", []))
            pid = f[:-5][:-8] if f.endswith("-lexicon.json") else f[:-5]
            for e in data:
                if isinstance(e, dict) and "word" in e:
                    name_like = pid != "tech" or notes.get(e["word"], False)
                    entries[e["word"].lower()].append((pid, e["word"], e.get("match", "case-insensitive"), name_like))
    return entries


def script_of(name):
    scripts = set()
    for ch in name:
        if ch.isalpha():
            n = unicodedata.name(ch, "")
            scripts.add(n.split(" ")[0] if n else "UNKNOWN")
    return "/".join(sorted(scripts)).lower() or "none"


# ---------- triage ----------

def bucket(row):
    if row["lexicon"]:
        return "lexicon-term-reading" if all(x.endswith(":term") for x in row["lexicon"].split(",")) else "covered-by-lexicon"
    if row["script"] != "latin" or row["source"] == "none" or "❓" in row["us"]:
        return "unsupported-script"
    if row["collision"] == "word":
        return "collision-word"
    if "guesser" in row["source"]:
        return "guesser-reading"
    if row["english_usage"]:
        return "dictionary-reading-likely-right"
    return "dictionary-reading-needs-check"


def read_ledger(manifest):
    by_rank = {m["rank"]: m for m in manifest}
    rows = []
    with open(os.path.join(NAMES, "ledger.tsv"), encoding="utf-8") as f:
        header = f.readline().rstrip("\n").split("\t")
        for line in f:
            r = dict(zip(header, line.rstrip("\n").split("\t")))
            m = by_rank.get(r["rank"], {})
            r["countries"], r["origin"] = m.get("countries", ""), m.get("origin", "")
            for c, alone in (("us_sentence", "us"), ("gb_sentence", "gb"), ("source_sentence", "source")):
                r[c] = r[c] or r[alone]
            rows.append(r)
    return rows


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--manifest", default=os.path.join(NAMES, "manifest.tsv"))
    ap.add_argument("--binary", default=os.path.join(ROOT, ".build", "release", "ReadAloud"))
    ap.add_argument("--gold", default=os.path.join(ROOT, "Vendor", "g2p", "us_gold.json"))
    ap.add_argument("--web2", default="/usr/share/dict/web2")
    ap.add_argument("--wordfreq", default="")
    ap.add_argument("--sample", type=int, default=0)
    ap.add_argument("--seed", type=int, default=906)
    ap.add_argument("--coverage-only", action="store_true",
                    help="skip the readings: rebuild coverage.json from ledger.tsv and the verdicts in spotcheck.tsv")
    args = ap.parse_args()

    manifest = []
    with open(args.manifest, encoding="utf-8") as f:
        header = f.readline().rstrip("\n").split("\t")
        for line in f:
            manifest.append(dict(zip(header, line.rstrip("\n").split("\t"))))
    if args.coverage_only:
        rows = read_ledger(manifest)
    else:
        names = [m["name"] for m in manifest]
        lines = names + [CARRIER.format(n) for n in names]
        print(f"phonemizing {len(lines):,} lines twice (US, GB)...", file=sys.stderr, flush=True)
        results = {}
        threads = [threading.Thread(target=lambda b: results.__setitem__(b, phonemize(args.binary, lines, b)), args=(b,))
                   for b in (False, True)]
        for t in threads: t.start()
        for t in threads: t.join()
        us, gb = results[False], results[True]

        gold_lower = {k for k in json.load(open(args.gold, encoding="utf-8")) if k == k.lower()}
        web2 = set()
        if os.path.exists(args.web2):
            web2 = {w.strip() for w in open(args.web2, encoding="utf-8", errors="replace") if w.strip() == w.strip().lower()}
        zipf = load_zipf(args.wordfreq)
        lexicons = load_lexicons()
        # Dispositions set by the research (tools/assemble.py) survive a re-run.
        researched = {}
        if os.path.exists(os.path.join(NAMES, "ledger.tsv")):
            researched = {(r["rank"], r["name"]): r["disposition"] for r in read_ledger(manifest)
                          if r["disposition"] not in ("covered", "unaudited")}

        rows = []
        for m in manifest:
            n = m["name"]
            s = CARRIER.format(n)
            u, g, us_, gs_ = us.get(n, ("", "")), gb.get(n, ("", "")), us.get(s, ("", "")), gb.get(s, ("", ""))
            low = n.lower()
            hits = [(pid, like) for pid, word, match, like in lexicons.get(low, [])
                    if match == "case-insensitive" or word == n]
            lex = sorted({pid + ("" if like else ":term") for pid, like in hits})
            in_gold, in_web2 = low in gold_lower, low in web2
            collision = "word" if in_gold and in_web2 else ("gold-only" if in_gold else "")
            src, src_s = source_label(u[1]), source_label(sentence_sources(us_[1]))
            row = {
                "rank": m["rank"], "name": n,
                "us": u[0], "gb": g[0], "us_sentence": name_part(us_[0]), "gb_sentence": name_part(gs_[0]),
                "source": src, "source_sentence": src_s,
                "lexicon": ",".join(lex) if (lex and ("lexicon" in src or "lexicon" in src_s)) else "",
                "collision": collision,
                "word_freq": tier(zipf.get(low) if zipf is not None else None) if collision else "",
                "script": script_of(n), "usage": m["usage"], "origin": m["origin"],
                "countries": m["countries"],
            }
            row["english_usage"] = m["usage"] == "english"
            row["multiword"] = "yes" if (" " in n or "-" in n) else ""
            row["bucket"] = bucket(row)
            row["disposition"] = researched.get((m["rank"], n)) or (
                "covered" if row["bucket"] == "covered-by-lexicon" else "unaudited")
            row["sentence_differs"] = "yes" if (row["us_sentence"] != row["us"] or row["gb_sentence"] != row["gb"]) else ""
            rows.append(row)

        cols = ["rank", "name", "us", "gb", "us_sentence", "gb_sentence", "sentence_differs", "source", "source_sentence",
                "lexicon", "collision", "word_freq", "script", "usage", "multiword", "bucket", "disposition"]
        with open(os.path.join(NAMES, "ledger.tsv"), "w", encoding="utf-8", newline="") as f:
            f.write("\t".join(cols) + "\n")
            for r in rows:
                # The sentence columns are left empty when they match the name on its own.
                same = {"us_sentence": r["us"], "gb_sentence": r["gb"], "source_sentence": r["source"]}
                f.write("\t".join("" if same.get(c) == r[c] else str(r[c]) for c in cols) + "\n")

    # Spot-check sample: 30 names per bucket, drawn with a fixed seed.
    spot_path = os.path.join(NAMES, "spotcheck.tsv")
    verdicts = {}
    if os.path.exists(spot_path):
        with open(spot_path, encoding="utf-8") as f:
            h = f.readline().rstrip("\n").split("\t")
            for line in f:
                r = dict(zip(h, line.rstrip("\n").split("\t")))
                verdicts[(r["bucket"], r["name"])] = (r.get("verdict", ""), r.get("note", ""))
    if args.sample:
        by_bucket = defaultdict(list)
        for r in rows:
            by_bucket[r["bucket"]].append(r)
        with open(spot_path, "w", encoding="utf-8", newline="") as f:
            f.write("bucket\trank\tname\tus\tgb\tus_sentence\tsource\torigin\tverdict\tnote\n")
            for b in BUCKETS:
                pool = by_bucket.get(b, [])
                rng = random.Random(f"{args.seed}:{b}")   # each bucket's draw independent of the others
                for r in sorted(rng.sample(pool, min(args.sample, len(pool))), key=lambda r: int(r["rank"])):
                    v, note = verdicts.get((b, r["name"]), ("", ""))
                    f.write(f"{b}\t{r['rank']}\t{r['name']}\t{r['us']}\t{r['gb']}\t{r['us_sentence']}\t"
                            f"{r['source']}\t{r['origin']}\t{v}\t{note}\n")
        verdicts = {}
        with open(spot_path, encoding="utf-8") as f:
            h = f.readline().rstrip("\n").split("\t")
            for line in f:
                r = dict(zip(h, line.rstrip("\n").split("\t")))
                verdicts[(r["bucket"], r["name"])] = (r.get("verdict", ""), r.get("note", ""))

    # Coverage.
    def region(r):
        c = r["countries"].split(",")[0] if r["countries"] else ""
        return c or "unknown"
    by_bucket = Counter(r["bucket"] for r in rows)
    top1k = Counter(r["bucket"] for r in rows if int(r["rank"]) <= 1000)
    top10k = Counter(r["bucket"] for r in rows if int(r["rank"]) <= 10000)
    spot = {}
    for b in BUCKETS:
        vs = [v for (bb, _), (v, _) in verdicts.items() if bb == b and v]
        c = Counter(vs)
        holds = c[EXPECT[b]]
        spot[b] = {"assumption": ASSUMPTION[b], "expect": EXPECT[b], "sampled": len(vs), "right": c["right"],
                   "wrong": c["wrong"], "unsure": c["unsure"],
                   "right_rate": round(c["right"] / len(vs), 2) if vs else None,
                   "wrong_rate": round(c["wrong"] / len(vs), 2) if vs else None,
                   "assumption_holds": round(holds / len(vs), 2) if vs else None}
    # Rough size of the correction work: each bucket's spot-check wrong rate times its size
    # (low), and with the unsure ones counted as wrong too (high). 30 names per bucket gives
    # about ±15 points on a rate, so these are orders of magnitude.
    estimate = {}
    for b in BUCKETS:
        sp = spot[b]
        if sp["sampled"]:
            n = by_bucket[b]
            estimate[b] = {"names": n, "wrong_low": round(n * sp["wrong"] / sp["sampled"]),
                           "wrong_high": round(n * (sp["wrong"] + sp["unsure"]) / sp["sampled"])}
    if estimate:
        estimate["total"] = {k: sum(e[k] for e in estimate.values()) for k in ("names", "wrong_low", "wrong_high")}
    coverage = {
        "candidates": len(rows),
        "by_bucket": {b: by_bucket[b] for b in BUCKETS},
        "by_bucket_top_1000": {b: top1k[b] for b in BUCKETS},
        "by_bucket_top_10000": {b: top10k[b] for b in BUCKETS},
        "by_bucket_multiword": {b: sum(1 for r in rows if r["bucket"] == b and r["multiword"]) for b in BUCKETS},
        "by_source": dict(sorted(Counter(r["source"] for r in rows).items(), key=lambda x: -x[1])),
        "by_collision": {k or "none": v for k, v in sorted(Counter(r["collision"] for r in rows).items())},
        "collision_word_frequency": dict(sorted(Counter(r["word_freq"] for r in rows if r["collision"] == "word").items())),
        "sentence_reading_differs": sum(1 for r in rows if r["sentence_differs"]),
        "by_script": dict(Counter(r["script"] for r in rows).most_common()),
        "by_first_country": {c: {"names": n, "buckets": dict(Counter(r["bucket"] for r in rows if region(r) == c))}
                             for c, n in Counter(region(r) for r in rows).most_common(40)},
        "by_origin": {o: {"names": n, "buckets": dict(Counter(r["bucket"] for r in rows if (r["origin"] or "unknown") == o))}
                      for o, n in Counter(r["origin"] or "unknown" for r in rows).most_common(40)},
        "by_disposition": dict(Counter(r["disposition"] for r in rows)),
        "spot_check": spot,
        "correction_estimate": estimate,
    }
    # The research block is assemble.py's.
    cov_path = os.path.join(NAMES, "coverage.json")
    if os.path.exists(cov_path):
        old = json.load(open(cov_path, encoding="utf-8"))
        if "research" in old:
            coverage["research"] = old["research"]
    with open(cov_path, "w", encoding="utf-8") as f:
        json.dump(coverage, f, indent=1, ensure_ascii=False)
        f.write("\n")
    print(json.dumps({k: coverage[k] for k in ("candidates", "by_bucket", "by_bucket_top_1000", "by_source", "by_collision",
                                               "sentence_reading_differs")}, indent=1, ensure_ascii=False), file=sys.stderr)


if __name__ == "__main__":
    main()
