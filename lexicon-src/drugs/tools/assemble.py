"""Assemble the drugs pack from the checked research batches (FIN-893).

Usage (from the repository root, after every batch passes check_drugs.py):
  python3 -I lexicon-src/drugs/tools/assemble.py [--binary .build/release/ReadAloud] [--no-verify]

Writes:
  Lexicons/drugs.json                  the shipped pack (pack id "drugs"): every `corrected`
                                       reading that passes the guards below, general entries
                                       (they read correctly for everyone), pronunciation only
                                       ("dictation": "never"), sorted by spelling.
  lexicon-src/drugs/drugs.source.json  every researched row: evidence, disposition, confidence,
                                       today's reading, the shipped reading, and why a row was
                                       held back.
  lexicon-src/drugs/ledger.tsv         one line per candidate with its outcome.
  lexicon-src/drugs/coverage.json      the counts.

Guards (a corrected row is held back, with the reason logged, when):
  - its spelling matches text in any casing and the lower-case word is an ordinary English word
    (in the system word list and Zipf 3.0 or more in wordfreq), unless the research note says why
    it is safe and the entry is case-sensitive;
  - it is a top-5,000 given name and the names pack or today's reading says it differently;
  - another shipped list has the spelling with a different reading (a clash for
    decisions/conflicts.json; settled by hand, never silently);
  - its confidence is low and today's reading is only partly wrong (a low-confidence reading
    ships only to replace a reading that is clearly wrong).
With verification on, it then asks the app (which reads Lexicons/ live) to say every shipped
spelling alone and in a sentence, and fails if any comes out other than the pack's reading.
Plain python3, standard library only."""
import argparse, csv, glob, json, os, subprocess, sys, tempfile
from collections import Counter, defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
DRUGS = os.path.dirname(HERE)
ROOT = os.path.dirname(os.path.dirname(DRUGS))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(ROOT, "lexicon-src", "names", "tools"))
from make_batches import phonemize, shipped_lists  # noqa: E402
from audit import load_zipf  # noqa: E402
from common import norm  # noqa: E402

# Decisions written by hand after review: spelling (lower case) -> (action, reason).
# action "ship" overrides a guard; "hold" keeps a reading out.
DECISIONS_PATH = os.path.join(DRUGS, "decisions.json")


def load_batches():
    rows, inputs = [], {}
    for p in sorted(glob.glob(os.path.join(DRUGS, "batches", "in", "d*.json"))):
        for r in json.load(open(p, encoding="utf-8"))["rows"]:
            inputs[(r["word"], r["kind"])] = (os.path.basename(p)[:-5], r)
    for p in sorted(glob.glob(os.path.join(DRUGS, "batches", "out", "d????.checked.json"))):
        bid = os.path.basename(p)[:5]
        for e in json.load(open(p, encoding="utf-8")):
            e["batch"] = bid
            rows.append(e)
    return rows, inputs


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--binary", default=os.path.join(ROOT, ".build", "release", "ReadAloud"))
    ap.add_argument("--wordfreq", default=os.path.expanduser("~/Library/Caches/aloud-drugs/wordfreq/large_en.msgpack.gz"))
    ap.add_argument("--no-verify", action="store_true")
    args = ap.parse_args()

    rows, inputs = load_batches()
    decisions = json.load(open(DECISIONS_PATH, encoding="utf-8")) if os.path.exists(DECISIONS_PATH) else {}
    zipf = load_zipf(args.wordfreq) if os.path.exists(args.wordfreq) else {}
    dict_words = {l.strip() for l in open("/usr/share/dict/words", encoding="utf-8", errors="replace")} \
        if os.path.exists("/usr/share/dict/words") else set()
    lists = shipped_lists()

    researched = {}
    for e in rows:
        researched[(e["word"], e["kind"])] = e
    shipped, held, source = {}, [], []
    for key, (bid, inp) in sorted(inputs.items(), key=lambda kv: kv[1][1]["rank"]):
        e = researched.get(key)
        rec = {"rank": inp["rank"], "word": inp["word"], "kind": inp["kind"], "batch": bid,
               "today_us": inp["today_us"], "today_gb": inp["today_gb"], "today_source": inp["today_source"],
               "score": inp["score"], "examples": inp["examples"]}
        if e is None:
            rec["disposition"] = "not-researched"
            source.append(rec)
            continue
        for k in ("spelling", "match", "disposition", "us", "gb", "respelling", "evidence", "confidence",
                  "alternatives", "notes", "verdict_us", "verdict_gb"):
            if e.get(k) not in (None, "", []):
                rec[k] = e[k]
        rec["shipped"] = False
        if e.get("disposition") == "corrected":
            sp = e["spelling"].strip()
            low = sp.lower()
            match = e.get("match") or "case-insensitive"
            reasons = []
            word_common = low in dict_words and (zipf.get(low) or 0) >= 3.0
            if word_common and match == "case-insensitive":
                reasons.append(f"ordinary English word '{low}' (Zipf {zipf.get(low)}) and the entry matches any casing")
            gn = inp.get("given_name")
            if gn and gn["rank"] <= 5000:
                names_entry = [o for o in lists.get(low, []) if o["pack"] == "names"]
                name_reading = names_entry[0]["us"] if names_entry else None
                if name_reading and norm(name_reading, False) != norm(e["us"], False):
                    reasons.append(f"given name {gn['name']} (rank {gn['rank']}) read /{name_reading}/ by the names pack")
                elif not name_reading and match == "case-insensitive" and sp[:1].isupper():
                    reasons.append(f"given name {gn['name']} (rank {gn['rank']}): the capitalised name would take the drug reading")
            for o in lists.get(low, []):
                if o["pack"] == "names":
                    continue
                overlap = not (o["match"] in ("case-sensitive", "exact") and match == "case-sensitive" and o["word"] != sp)
                if overlap and o.get("us") and o["us"] != e["us"]:
                    reasons.append(f"{o['pack']} reads {o['word']} as /{o['us']}/")
                elif overlap and o.get("us") == e["us"]:
                    reasons.append(f"{o['pack']} already reads {o['word']} the same way (covered)")
            if e.get("confidence") == "low" and e.get("verdict_us") != "wrong":
                reasons.append("low confidence, and today's reading is only partly off")
            d = decisions.get(low)
            if d and d.get("action") == "ship":
                reasons = []
                rec["decision"] = d["reason"]
            elif d and d.get("action") == "hold":
                reasons.append("decision: " + d["reason"])
            if reasons:
                rec["held"] = reasons
                held.append(rec)
            elif low in shipped and shipped[low]["us"] != e["us"]:
                rec["held"] = [f"a second reading for '{sp}' (first: {shipped[low]['word']} /{shipped[low]['us']}/)"]
                held.append(rec)
            else:
                entry = {"word": sp, "match": match, "us": e["us"]}
                if e.get("gb_effective") and e["gb_effective"] != e["us"] or e.get("gb"):
                    entry["gb"] = e.get("gb") or e["gb_effective"]
                entry["dictation"] = "never"
                shipped[low] = entry
                rec["shipped"] = True
        source.append(rec)

    pack = sorted(shipped.values(), key=lambda x: (x["word"].lower(), x["word"]))
    with open(os.path.join(ROOT, "Lexicons", "drugs.json"), "w", encoding="utf-8") as f:
        f.write("[\n" + ",\n".join(json.dumps(x, ensure_ascii=False) for x in pack) + "\n]\n")

    disp = Counter(r.get("disposition") for r in source)
    by_kind = defaultdict(Counter)
    conf = Counter()
    for r in source:
        by_kind[r["kind"]][r.get("disposition")] += 1
        if r.get("shipped"):
            by_kind[r["kind"]]["shipped"] += 1
            conf[r.get("confidence")] += 1
    coverage = {"candidates": len(source), "dispositions": dict(disp), "shipped": len(pack),
                "shipped_by_confidence": dict(conf), "held_back": len(held),
                "by_kind": {k: dict(v) for k, v in sorted(by_kind.items())}}
    with open(os.path.join(DRUGS, "coverage.json"), "w", encoding="utf-8") as f:
        json.dump(coverage, f, indent=1, sort_keys=True)
        f.write("\n")
    with open(os.path.join(DRUGS, "drugs.source.json"), "w", encoding="utf-8") as f:
        json.dump({"about": "Every drug-name candidate researched for Lexicons/drugs.json (FIN-893): evidence, "
                            "disposition, confidence, the reading before the pack (today_*) and the shipped one. "
                            "Rows with 'held' were researched but kept out of the pack, with the reasons.",
                   "coverage": coverage, "rows": source}, f, ensure_ascii=False, indent=1)
        f.write("\n")
    with open(os.path.join(DRUGS, "ledger.tsv"), "w", encoding="utf-8") as f:
        f.write("rank\tword\tkind\tdisposition\tconfidence\tshipped\tspelling\ttoday_us\tus\tgb\tverdict_us\theld\tsources\n")
        for r in source:
            srcs = "; ".join(x.get("source", "") for x in r.get("evidence", []) if isinstance(x, dict))
            f.write("\t".join(str(v) for v in [r["rank"], r["word"], r["kind"], r.get("disposition", ""),
                                                r.get("confidence", ""), "yes" if r.get("shipped") else "",
                                                r.get("spelling", ""), r["today_us"], r.get("us", ""), r.get("gb", ""),
                                                r.get("verdict_us", ""), " | ".join(r.get("held", [])), srcs]) + "\n")
    print(f"Lexicons/drugs.json: {len(pack)} entries; held back {len(held)}; dispositions {dict(disp)}; "
          f"shipped by confidence {dict(conf)}")
    for r in held:
        print(f"  held {r['word']} ({r['kind']}): {' | '.join(r['held'])}")

    if args.no_verify:
        return
    # The app reads Lexicons/ live: every shipped spelling must now come out as the pack says.
    words = [x["word"] for x in pack]
    bad = []
    for british in (False, True):
        alone = phonemize(args.binary, words, british)
        sent = phonemize(args.binary, [f"Take {w} daily." for w in words], british)
        for x in pack:
            want = (x.get("gb") or x["us"]) if british else x["us"]
            got = alone.get(x["word"], ("", ""))[0]
            got_s = sent.get(f"Take {x['word']} daily.", ("", ""))[0]
            if got.strip() != want or want not in got_s:
                bad.append(f"{'GB' if british else 'US'} {x['word']}: want /{want}/, alone /{got}/, in a sentence /{got_s}/")
    print(f"verify: {len(words)} spellings x US/GB, alone and in a sentence: {len(bad)} problems")
    for b in bad[:60]:
        print("  " + b)
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
