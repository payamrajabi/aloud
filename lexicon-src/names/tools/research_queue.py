"""Phase 3 research queue for the names pack (FIN-906). Brief: ../NAMES-GUIDE.md.

Usage (from the repository root; plain python3 3.9+, standard library only):
  python3 -I lexicon-src/names/tools/research_queue.py [--research ~/Library/Caches/aloud-names/research]
      [--size 150] [--force] [--tools-only]

Orders every ledger row that needs research by rank and cuts it into batches of --size:
- buckets guesser-reading, dictionary-reading-needs-check, lexicon-term-reading (research),
  covered-by-lexicon (verify only), collision-word (protect-word triage) and
  dictionary-reading-likely-right (light verification);
- multiword names whose parts (split at spaces and hyphens) are all single-word names elsewhere in
  the ledger, spelled exactly the same, are left out: their parts cover them;
- unsupported-script rows get a transliteration note only, in their own batches after all others.
Tranche 1 is ranks 1 to 10,000, tranche 2 the rest; a batch never mixes tranches or kinds.

Writes, under the research folder (a durable place outside any git worktree):
  in/n0001.json ...   {"batch", "tranche", "kind", "ranks", "count", "names": [...]}
  queue.json          every batch: id, tranche, kind, rank range, count, buckets; and the totals
  tools/              check_names.py, common.py, vocab.json, NAMES-GUIDE.md, example-batch.json
and ../queue-summary.json (totals and batch ids, no names) in the repository.

It refuses to rewrite in/ once out/ holds results (batch ids would shift under finished work)
unless --force; --tools-only refreshes tools/ alone."""
import argparse, csv, hashlib, json, os, re, shutil, sys
from collections import Counter, OrderedDict

HERE = os.path.dirname(os.path.abspath(__file__))
NAMES = os.path.dirname(HERE)
LEX = os.path.dirname(NAMES)
TRANCHE1 = 10000
TASK = OrderedDict([
    ("guesser-reading", "research"),
    ("dictionary-reading-needs-check", "research"),
    ("lexicon-term-reading", "research"),
    ("covered-by-lexicon", "verify"),
    ("collision-word", "protect-word triage"),
    ("dictionary-reading-likely-right", "light verification"),
    ("unsupported-script", "transliteration note"),
])
TOOLS = [(os.path.join(HERE, "check_names.py"), "check_names.py"),
         (os.path.join(LEX, "tools", "common.py"), "common.py"),
         (os.path.join(LEX, "tools", "vocab.json"), "vocab.json"),
         (os.path.join(NAMES, "NAMES-GUIDE.md"), "NAMES-GUIDE.md"),
         (os.path.join(HERE, "example-batch.json"), "example-batch.json")]


def read_tsv(path):
    with open(path, encoding="utf-8", newline="") as f:
        return list(csv.DictReader(f, delimiter="\t", quoting=csv.QUOTE_NONE))


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def install_tools(research):
    tools = os.path.join(research, "tools")
    os.makedirs(tools, exist_ok=True)
    for src, name in TOOLS:
        shutil.copyfile(src, os.path.join(tools, name))
    return tools


def build(ledger, manifest):
    man = {m["rank"]: m for m in manifest}
    single = {r["name"] for r in ledger if not r["multiword"]}
    rows, excluded = [], Counter()
    for r in ledger:
        if r["multiword"]:
            parts = [p for p in re.split(r"[ \-]+", r["name"]) if p]
            if parts and all(p in single for p in parts):
                excluded[r["bucket"]] += 1
                continue
        m = man.get(r["rank"], {})
        row = OrderedDict([
            ("rank", int(r["rank"])), ("name", r["name"]), ("bucket", r["bucket"]), ("task", TASK[r["bucket"]]),
            ("today_us", r["us"]), ("today_gb", r["gb"]), ("today_source", r["source"]),
        ])
        if r["sentence_differs"]:
            row["today_us_in_sentence"] = r["us_sentence"]   # inside "I met NAME yesterday."
        row.update([
            ("usage", r["usage"]), ("anglo_share", float(m.get("anglo_share") or 0)),
            ("countries", m.get("countries", "")), ("origin", m.get("origin", "")),
            ("native", m.get("native", "")), ("evidence", m.get("evidence", "")),
            ("collision", r["collision"]), ("word_freq", r["word_freq"]), ("lexicon", r["lexicon"]),
            ("script", r["script"]), ("multiword", bool(r["multiword"])),
        ])
        rows.append(row)
    return rows, excluded


def batches(rows, size):
    groups = OrderedDict()
    for kind in ("research", "transliteration"):
        for tranche in (1, 2):
            groups[(kind, tranche)] = []
    for r in sorted(rows, key=lambda r: r["rank"]):
        kind = "transliteration" if r["bucket"] == "unsupported-script" else "research"
        groups[(kind, 1 if r["rank"] <= TRANCHE1 else 2)].append(r)
    out, n = [], 0
    for (kind, tranche), group in groups.items():
        for i in range(0, len(group), size):
            n += 1
            chunk = group[i:i + size]
            out.append(OrderedDict([
                ("batch", f"n{n:04d}"), ("tranche", tranche), ("kind", kind),
                ("ranks", [chunk[0]["rank"], chunk[-1]["rank"]]), ("count", len(chunk)),
                ("buckets", dict(Counter(r["bucket"] for r in chunk))), ("names", chunk),
            ]))
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--research", default=os.path.expanduser("~/Library/Caches/aloud-names/research"))
    ap.add_argument("--size", type=int, default=150)
    ap.add_argument("--force", action="store_true", help="rewrite in/ even though out/ has results")
    ap.add_argument("--tools-only", action="store_true", help="only refresh <research>/tools/")
    args = ap.parse_args()
    research = os.path.abspath(os.path.expanduser(args.research))
    repo = os.path.dirname(LEX)
    if os.path.commonpath([research, repo]) == repo:
        sys.exit("keep the research folder outside the repository")

    tools = install_tools(research)
    print(f"tools -> {tools}")
    if args.tools_only:
        return
    outdir = os.path.join(research, "out")
    if os.path.isdir(outdir) and any(f.endswith(".json") for f in os.listdir(outdir)) and not args.force:
        sys.exit(f"{outdir} already holds results; rewriting in/ would shift batch ids (use --force)")

    ledger_path, manifest_path = os.path.join(NAMES, "ledger.tsv"), os.path.join(NAMES, "manifest.tsv")
    rows, excluded = build(read_tsv(ledger_path), read_tsv(manifest_path))
    bs = batches(rows, args.size)

    indir = os.path.join(research, "in")
    os.makedirs(indir, exist_ok=True)
    for f in os.listdir(indir):
        if re.fullmatch(r"n\d{4}\.json", f):
            os.remove(os.path.join(indir, f))
    for b in bs:
        with open(os.path.join(indir, b["batch"] + ".json"), "w", encoding="utf-8") as f:
            json.dump(b, f, ensure_ascii=False, indent=1)
            f.write("\n")

    by_tb = {str(t): dict(Counter(r["bucket"] for r in rows if (r["rank"] <= TRANCHE1) == (t == 1))) for t in (1, 2)}
    by_tb = {t: OrderedDict((k, v[k]) for k in TASK if k in v) for t, v in by_tb.items()}
    ranges = OrderedDict()
    for b in bs:
        key = f"tranche {b['tranche']} {b['kind']}"
        lo, hi, cnt = ranges.get(key, (b["batch"], b["batch"], 0))
        ranges[key] = (lo, b["batch"], cnt + 1)
    totals = OrderedDict([
        ("names", len(rows)),
        ("by_tranche", {t: sum(v.values()) for t, v in by_tb.items()}),
        ("by_tranche_bucket", by_tb),
        ("by_kind", dict(Counter(("transliteration" if r["bucket"] == "unsupported-script" else "research") for r in rows))),
        ("excluded_multiword_covered_by_parts", OrderedDict([("total", sum(excluded.values()))] +
                                                            [(k, excluded[k]) for k in TASK if excluded[k]])),
        ("batches", len(bs)),
        ("batch_ids", OrderedDict((k, {"first": lo, "last": hi, "batches": n}) for k, (lo, hi, n) in ranges.items())),
    ])
    queue = OrderedDict([
        ("size", args.size), ("tranche1_ranks", [1, TRANCHE1]),
        ("ledger_sha256", sha256(ledger_path)), ("manifest_sha256", sha256(manifest_path)),
        ("totals", totals),
        ("batches", [OrderedDict((k, b[k]) for k in ("batch", "tranche", "kind", "ranks", "count", "buckets")) for b in bs]),
    ])
    with open(os.path.join(research, "queue.json"), "w", encoding="utf-8") as f:
        json.dump(queue, f, ensure_ascii=False, indent=1)
        f.write("\n")
    os.makedirs(outdir, exist_ok=True)
    summary = OrderedDict((k, queue[k]) for k in ("size", "tranche1_ranks", "ledger_sha256", "manifest_sha256", "totals"))
    summary["research_folder"] = "~/Library/Caches/aloud-names/research (in/, out/, tools/, queue.json)"
    with open(os.path.join(NAMES, "queue-summary.json"), "w", encoding="utf-8") as f:
        json.dump(summary, f, ensure_ascii=False, indent=1)
        f.write("\n")
    print(json.dumps(totals, ensure_ascii=False, indent=1))
    print(f"wrote {len(bs)} batches to {indir}, {os.path.join(research, 'queue.json')}, "
          f"{os.path.relpath(os.path.join(NAMES, 'queue-summary.json'))}")


if __name__ == "__main__":
    main()
