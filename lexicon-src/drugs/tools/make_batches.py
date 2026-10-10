"""Record today's readings and cut the drug-name candidates into research batches (FIN-893).

Usage (from the repository root, after rank.py and harvest.py, before Lexicons/drugs.json exists):
  swift build -c release
  python3 -I lexicon-src/drugs/tools/make_batches.py [--binary .build/release/ReadAloud]
      [--wordfreq ~/Library/Caches/aloud-drugs/wordfreq/large_en.msgpack.gz] [--size 50]

For every candidate it asks the app how it reads the word today (`ReadAloud --phonemize
--explain`, US and `--gb`) and what read it (gold or CMUdict dictionary, the neural guesser, a
custom list), and records what else the spelling is: an ordinary English word (wordfreq Zipf
and the system word list), a given name (lexicon-src/names/manifest.tsv), an entry in another
shipped list. That goes to lexicon-src/drugs/baseline.tsv, and with the evidence from
evidence.json into batches/in/dNNNN.json (generics and salts first, then brands and devices,
each in rank order). Re-running keeps baseline.tsv's readings unless --rebaseline is given,
so the readings stay those from before the pack. Plain python3, standard library only."""
import argparse, csv, json, os, re, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
DRUGS = os.path.dirname(HERE)
ROOT = os.path.dirname(os.path.dirname(DRUGS))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(ROOT, "lexicon-src", "names", "tools"))
from harvest import display  # noqa: E402
from audit import load_zipf  # noqa: E402  (names pack: wordfreq reader, standard library only)


def phonemize(binary, words, british):
    args = [binary, "--phonemize", "--explain"] + (["--gb"] if british else [])
    with tempfile.TemporaryDirectory() as tmp:
        src, dst = os.path.join(tmp, "in.txt"), os.path.join(tmp, "out.txt")
        with open(src, "w", encoding="utf-8") as f:
            f.write("".join(w + "\n" for w in words))
        with open(src, "rb") as fin, open(dst, "wb") as fout:
            subprocess.run(args, stdin=fin, stdout=fout, stderr=subprocess.DEVNULL, check=True)
        out = {}
        for raw in open(dst, encoding="utf-8"):
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


def shipped_lists():
    """lower-cased word -> [(pack, word, match, us)] for every shipped list except drugs.json."""
    out = {}
    lex = os.path.join(ROOT, "Lexicons")
    for f in sorted(os.listdir(lex)):
        if not f.endswith(".json") or f == "drugs.json":
            continue
        pack = f[:-5][:-8] if f.endswith("-lexicon.json") else f[:-5]
        data = json.load(open(os.path.join(lex, f), encoding="utf-8"))
        data = data if isinstance(data, list) else data.get("entries", [])
        for e in data:
            if isinstance(e, dict) and e.get("word"):
                out.setdefault(e["word"].lower(), []).append(
                    {"pack": pack, "word": e["word"], "match": e.get("match", "case-sensitive"), "us": e.get("us", "")})
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--binary", default=os.path.join(ROOT, ".build", "release", "ReadAloud"))
    ap.add_argument("--wordfreq", default=os.path.expanduser("~/Library/Caches/aloud-drugs/wordfreq/large_en.msgpack.gz"))
    ap.add_argument("--size", type=int, default=50)
    ap.add_argument("--rebaseline", action="store_true")
    args = ap.parse_args()
    if os.path.exists(os.path.join(ROOT, "Lexicons", "drugs.json")) and args.rebaseline:
        sys.exit("Lexicons/drugs.json exists: today's readings would include the pack. Move it away first.")

    cands = list(csv.DictReader(open(os.path.join(DRUGS, "candidates.tsv"), encoding="utf-8"), delimiter="\t"))
    evidence = json.load(open(os.path.join(DRUGS, "evidence.json"), encoding="utf-8"))
    base_path = os.path.join(DRUGS, "baseline.tsv")
    old = {}
    if os.path.exists(base_path) and not args.rebaseline:
        for r in csv.DictReader(open(base_path, encoding="utf-8"), delimiter="\t"):
            old[(r["word"], r["kind"])] = r

    for r in cands:
        r["display"] = display(r)
    need = sorted({r["display"] for r in cands if (r["word"], r["kind"]) not in old})
    us = phonemize(args.binary, need, False) if need else {}
    gb = phonemize(args.binary, need, True) if need else {}

    zipf = load_zipf(args.wordfreq) if os.path.exists(args.wordfreq) else {}
    dict_words = set()
    if os.path.exists("/usr/share/dict/words"):
        dict_words = {l.strip() for l in open("/usr/share/dict/words", encoding="utf-8", errors="replace") if l.strip()}
    names = {}
    for r in csv.DictReader(open(os.path.join(ROOT, "lexicon-src", "names", "manifest.tsv"), encoding="utf-8"), delimiter="\t"):
        names.setdefault(r["name"].lower(), (int(r["rank"]), r["name"], int(float(r["est_people"] or 0))))
    lists = shipped_lists()

    rows = []
    for r in cands:
        k = (r["word"], r["kind"])
        if k in old:
            b = old[k]
        else:
            tu, su = us.get(r["display"], ("", ""))
            tg, sg = gb.get(r["display"], ("", ""))
            b = {"today_us": tu, "today_gb": tg, "today_source": source_label(su)}
        w = r["word"]
        z = zipf.get(w.lower())
        nm = names.get(w.lower())
        row = {
            "rank": int(r["rank"]), "word": w, "kind": r["kind"], "display": r["display"],
            "today_us": b["today_us"], "today_gb": b["today_gb"], "today_source": b["today_source"],
            "zipf": round(z, 2) if z is not None else None,
            "dictionary_word": w.lower() in dict_words or w.lower().replace("-", "") in dict_words,
            "given_name": {"rank": nm[0], "name": nm[1], "est_people": nm[2]} if nm and nm[0] <= 20000 else None,
            "other_lists": lists.get(w.lower(), []),
            "score": int(r["score"]), "examples": r["examples"], "generic_of": r["generic_of"], "why": r["why"],
            "evidence": evidence.get(f"{r['kind']}:{w}", {}),
        }
        rows.append(row)

    with open(base_path, "w", encoding="utf-8") as f:
        f.write("rank\tword\tkind\tdisplay\ttoday_us\ttoday_gb\ttoday_source\tzipf\tdictionary_word\tgiven_name_rank\tother_lists\n")
        for row in rows:
            f.write("\t".join([str(row["rank"]), row["word"], row["kind"], row["display"], row["today_us"], row["today_gb"],
                               row["today_source"], "" if row["zipf"] is None else str(row["zipf"]),
                               "yes" if row["dictionary_word"] else "",
                               str(row["given_name"]["rank"]) if row["given_name"] else "",
                               ",".join(sorted({x["pack"] for x in row["other_lists"]}))]) + "\n")

    groups = [[x for x in rows if x["kind"] in ("generic", "salt")], [x for x in rows if x["kind"] in ("brand", "device")]]
    out_dir = os.path.join(DRUGS, "batches", "in")
    os.makedirs(out_dir, exist_ok=True)
    n = 0
    queue = []
    for g in groups:
        g.sort(key=lambda x: x["rank"])
        for i in range(0, len(g), args.size):
            n += 1
            bid = f"d{n:04d}"
            with open(os.path.join(out_dir, bid + ".json"), "w", encoding="utf-8") as f:
                json.dump({"batch": bid, "rows": g[i:i + args.size]}, f, ensure_ascii=False, indent=1)
                f.write("\n")
            queue.append({"batch": bid, "kinds": sorted({x["kind"] for x in g[i:i + args.size]}), "rows": len(g[i:i + args.size]),
                          "ranks": [g[i]["rank"], g[min(i + args.size, len(g)) - 1]["rank"]]})
    with open(os.path.join(DRUGS, "batches", "queue.json"), "w", encoding="utf-8") as f:
        json.dump(queue, f, indent=1)
        f.write("\n")
    srcs = {}
    for row in rows:
        srcs[row["today_source"]] = srcs.get(row["today_source"], 0) + 1
    print(f"{len(rows)} candidates in {n} batches; today's reading from: {srcs}")


if __name__ == "__main__":
    main()
