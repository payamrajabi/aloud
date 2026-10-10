"""Assemble the names pack (FIN-906, phase 4) from the researched batches.

Usage (python3 3.9+, standard library only; from the repository root, after `swift build -c release`):
  python3 -I lexicon-src/names/tools/assemble.py --baseline-out FILE
      Records how the app reads every researched name today (alone and in "I met NAME
      yesterday.", US and GB). Run it before Lexicons/names.json exists.
  python3 -I lexicon-src/names/tools/assemble.py [--baseline FILE] [--research DIR] [--binary PATH]
      Builds the pack. Without --baseline, the "before" readings come from the existing
      names.source.json.

Reads every checked batch in the research folder (`out/n*.checked.json`, then the special
batches `out/p*.checked.json`, which win over an n-batch for the same name: p0001 holds the
Persian readings Payam asked for) and writes:
  - Lexicons/names.json: one entry per `corrected` name that passes the checks below, as
    {"word", "match": "name", "us", "gb", "dictation": "never"}. Pack id "names",
    always on, nothing pack_only, no dictation rewrites.
  - lexicon-src/names/names.source.json: every researched name with its evidence,
    disposition, alternatives, batch, today's reading ("before") and the pack's ("after"),
    whether it shipped and why not; and the log of dropped names.
  - lexicon-src/names/ledger.tsv: the disposition column of every researched row.
  - lexicon-src/names/coverage.json: the "research" block (totals, by origin, language and
    rank tier, the Persian batch on its own) and by_disposition.

A corrected name is held back (logged in names.source.json "dropped") when:
  - Core reads the spelling as something else after the lexicon has marked its terms: a month
    or weekday abbreviation ("Jun 5", "Thu 3pm");
  - its everyday use in English text is a place or brand read another way (ELSEWHERE: Port
    St. Lucie);
  - it is a capitalised ordinary word: a common sentence opener (OPENERS), or its lower-case
    spelling is a word in the misaki gold dictionary, unless that word reads the same as the
    name or is listed in WORD_KEEP with the reason the name is what readers meet. Names are
    matched case-sensitively, so a word kept here would change every sentence it starts;
  - the app already reads it that way, alone and in a sentence (an entry would change nothing).
Afterwards every shipped name is read again: one that doesn't read as written is reported
(a tech-list entry with the same spelling wins it, see decisions/conflicts.json)."""
import argparse, glob, json, os, re, sys
from collections import Counter, defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
NAMES = os.path.dirname(HERE)
ROOT = os.path.dirname(os.path.dirname(NAMES))
sys.path.insert(0, HERE)
from audit import phonemize, name_part, sentence_sources, source_label, CARRIER  # noqa: E402

RESEARCH = os.path.expanduser("~/Library/Caches/aloud-names/research/out")
PACK = os.path.join(ROOT, "Lexicons", "names.json")
SOURCE = os.path.join(NAMES, "names.source.json")

# Abbreviations Core reads after the custom lexicon (TextNormalizer: dates and times). A name
# entry would mark them first and "Jun 5" would lose its date.
CORE_ABBREVIATIONS = {
    "Jan", "Feb", "Mar", "Apr", "Jun", "Jul", "Aug", "Sep", "Sept", "Oct", "Nov", "Dec",
    "Mon", "Tue", "Tues", "Wed", "Thu", "Thur", "Thurs", "Fri", "Sat", "Sun",
}

# Words that commonly start an English sentence (and so turn up capitalised in any text).
OPENERS = set("""
A About Above Across After Again Against Ah All Almost Alone Along Already Also Although Always Am
Among An And Another Any Anyone Anything Anyway Are Around As Ask At Away Aw Back Be Because Been
Before Behind Below Beside Besides Best Better Between Beyond Both Bring But Buy By Call Can Check
Click Close Come Consider Could Dear Despite Did Do Does Done Down During Each Early Either Else Even
Ever Every Everyone Everything Except Few Finally Find First Five For Four From Get Give Go Good
Got Had Half Has Have He Hello Hence Her Here Hers Hey Hi Him His Hmm Hold How However Huh I If
Imagine In Indeed Inside Instead Into Is It Its Just Keep Last Late Later Leave Less Let Like Look
Make Many Maybe May Me Meanwhile Might Mind More Most Much Must My Near Neither Never Next Nine No
Nobody None Nope Nor Not Note Nothing Now Of Off Oh Ok Okay On Once One Only Onto Oops Open Or
Other Otherwise Our Out Outside Over Past Per Perhaps Pick Please Press Probably Put Quite Rather
Read Really Remember Run Said Save Say Says Second See Send Set Seven Shall She Should Since Six So
Some Someone Something Sometimes Soon Sorry Start Still Stop Such Take Tell Ten Than Thanks That
The Their Them Then There Therefore These They Third This Those Though Three Through Thus To Today
Together Tomorrow Tonight Too Toward Towards Try Turn Two Type Uh Um Under Unless Unlike Until Up
Upon Us Use Very Via Wait Was Watch We Well Were What When Where Whether Which While Who Whose Why
Will With Within Without Wow Would Yeah Yep Yes Yesterday Yet You Your Yours
""".split())

# Lower-case words in the gold dictionary whose capitalised form, in running text, is the
# name. The word is technical, archaic, foreign or a name gold lists in lower case, so a
# capitalised sentence-initial use is rare, while the name is what readers meet. Every other
# gold word drops the name (unless the word reads the same, which can't change anything).
WORD_KEEP = {
    "Maria": "lunar 'maria' (plural of mare) is technical; the capitalised word is the name",
    "Peng": "British slang 'peng' is informal and lower-case",
    "Hui": "Māori 'hui' (a gathering) is New Zealand English, written lower-case",
    "Diana": "gold lists the name in lower case; no ordinary word",
    "Sardar": "a title and name; no ordinary English word",
    "Yi": "gold lists the Chinese name in lower case; no ordinary word",
    "Shahid": "gold lists the name in lower case; no ordinary word",
    "Yulan": "'yulan' (a magnolia) is a rare botanical word",
    "Xi": "the Greek letter is written 'xi' or ξ; capitalised Xi is the name (Xi Jinping)",
    "Darshan": "'darshan' is a Hindu religious term, written lower-case",
    "Barry": "'barry' is a heraldry term, rare",
    "Ananda": "'ananda' is a Sanskrit term, written lower-case",
    "Jiao": "gold lists the Chinese name in lower case; no ordinary word",
    "Madeleine": "the cake is written lower-case mid-sentence; English 'mad-LEN' is close to the name's reading",
    "Xu": "gold lists the Chinese name in lower case; no ordinary word",
    "Gui": "lower-case 'gui' and 'GUI' stay with the tech list's GUI; only the casing 'Gui' is the name",
    "Amrit": "'amrit' is a Sikh religious term, written lower-case",
    "Nadir": "'nadir' (the lowest point) is used mid-sentence ('the nadir of'); sentence-initial use is rare",
    "Xenia": "'xenia' is a rare botanical term",
    "Rami": "'rami' (plural of ramus) is an anatomical term",
    "Jawed": "'jawed' (past tense of jaw) is rare",
    "Dele": "'dele' is a proofreading mark",
    "Beth": "'beth' (the Hebrew letter) is rare",
    "Abed": "'abed' (in bed) is archaic",
    "Colleen": "'colleen' (an Irish girl) is rare and old-fashioned",
    "Lamia": "'lamia' (a mythical monster) is rare",
    "Shen": "'shen' is a Chinese philosophical term, written lower-case",
    "Roque": "'roque' (a croquet variant) is rare",
    "Unni": "gold lists the name in lower case; no ordinary word",
    "Pia": "'pia' (pia mater) is an anatomical term, written lower-case",
    "Tope": "'tope' (to drink; a shark) is rare",
    "Georgette": "'georgette' (a fabric) is written lower-case",
    "Bola": "'bola' (a throwing weapon) is rare",
    "Rowan": "the tree is said both ROH-an and ROW-an (Merriam-Webster), so the name's reading suits it",
    "Gerd": "the illness is written GERD, in capitals",
    "Florin": "'florin' (an old coin) is rare",
    "Kris": "'kris' (a dagger) is rare",
    "Homa": "'homa' (a Vedic fire ritual) is rare",
}
# Gold words that do start ordinary sentences, with the reason (the rest get a generic one).
WORD_DROP = {
    "Fanny": "'fanny' (fanny pack) is an everyday word: 'Fanny packs are back' would read fah-NEE",
    "Axel": "the skating jump is written 'Axel' in capitals ('a triple Axel')",
    "Dino": "'dino' is everyday informal English ('Dino facts for kids')",
    "Tamer": "'tamer' (comparative of tame; a lion tamer) is an ordinary word",
    "Lino": "'lino' (linoleum, lino prints) is everyday British English",
    "Ze": "'ze' is a pronoun, which starts sentences",
    "Bento": "'bento' (a bento box) is an everyday word",
    "Muni": "'muni' (muni bonds; San Francisco's Muni) starts sentences in finance and Bay Area news, read MYOO-nee",
    "Dolma": "'dolma' (the stuffed dish) is an everyday word in food writing",
}


def load_research(folder):
    """{name: entry} from the checked batches; p-batches (special research) win."""
    files = sorted(glob.glob(os.path.join(folder, "n*.checked.json"))) + \
        sorted(glob.glob(os.path.join(folder, "p*.checked.json")))
    if not files:
        sys.exit(f"no checked batches in {folder}")
    entries, batches, overrides = {}, {}, []
    for f in files:
        batch = os.path.basename(f).split(".")[0]
        rows = json.load(open(f, encoding="utf-8"))
        batches[batch] = len(rows)
        for e in rows:
            e = dict(e)
            e["batch"] = batch
            old = entries.get(e["name"])
            if old is not None:
                if not batch.startswith("p"):
                    sys.exit(f"{e['name']} is in {old['batch']} and {batch}")
                changed = [k for k in ("disposition", "us", "gb") if (old.get(k) or "") != (e.get(k) or "")]
                overrides.append({"name": e["name"], "kept": batch, "over": old["batch"],
                                  "differs": changed,
                                  "before": {k: old.get(k) for k in ("disposition", "us", "gb")},
                                  "after": {k: e.get(k) for k in ("disposition", "us", "gb")}})
                if not e.get("rank") and old.get("rank"):
                    e["rank"] = old["rank"]
            entries[e["name"]] = e
    return entries, batches, overrides


def readings(binary, names):
    """{name: {us, gb, source, us_sentence, gb_sentence}} as the app reads them now."""
    lines = list(names) + [CARRIER.format(n) for n in names]
    us, gb = phonemize(binary, lines, False), phonemize(binary, lines, True)
    out = {}
    for n in names:
        s = CARRIER.format(n)
        out[n] = {"us": us[n][0], "gb": gb[n][0], "source": source_label(us[n][1]),
                  "us_sentence": name_part(us[s][0]), "gb_sentence": name_part(gb[s][0]),
                  "source_sentence": source_label(sentence_sources(us[s][1]))}
    return out


def loose(ps):
    return ps.replace("ˈ", "").replace("ˌ", "")


def gold_words():
    gold = json.load(open(os.path.join(ROOT, "Vendor", "g2p", "us_gold.json"), encoding="utf-8"))
    return {k: v for k, v in gold.items() if k == k.lower()}


def tech_hits(name, tech):
    """Tech-list entries that can match the capitalised name."""
    return [t for t in tech.get(name.lower(), []) if t.get("match") == "case-insensitive" or t["word"] == name]


# Spellings whose everyday use in English text is a place or brand read another way, which a
# case-sensitive entry would change everywhere (the guide's Jesus and Israel rule).
ELSEWHERE = {
    "Lucie": "St. Lucie (the Florida city, county and river) is LOO-see, as English bearers say it (Lucie Arnaz); "
             "the French loo-SEE would change the place (Tests/g2p/regression.json pins Port St. Lucie)",
}


def hold_back(e, gold, before):
    """Why a corrected name stays out of the pack, or None."""
    n = e["name"]
    if n in CORE_ABBREVIATIONS:
        return "core-abbreviation", "Core reads it as a month or weekday abbreviation ('Jun 5', 'Thu 3pm') after the lexicon runs"
    if n in ELSEWHERE:
        return "place-or-brand", ELSEWHERE[n]
    if n in OPENERS:
        return "ordinary-word", "a common sentence opener"
    low = n.lower()
    if low in gold and low != n:
        word = gold[low]
        if n in WORD_DROP:
            return "ordinary-word", WORD_DROP[n]
        if n in WORD_KEEP:
            e["word_check"] = f"gold has '{low}'; kept: {WORD_KEEP[n]}"
        elif isinstance(word, str) and loose(word) == loose(e["us"]):
            e["word_check"] = f"gold has '{low}' read {word}, the same as the name: kept"
        else:
            return "ordinary-word", f"'{low}' is an ordinary word in the gold dictionary ({word if isinstance(word, str) else 'by part of speech'})"
    b = before.get(n)
    if b and b["us"] == e["us"] and b["gb"] == e["gb_effective"] \
            and b["us_sentence"] == e["us"] and b["gb_sentence"] == e["gb_effective"]:
        return "unchanged", "the app already reads it this way, alone and in a sentence"
    return None


def tier(rank):
    r = int(rank or 0)
    if r == 0:
        return "not in the ledger"
    return "1-1000" if r <= 1000 else "1001-2500" if r <= 2500 else "2501-5000" if r <= 5000 else "5001+"


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--research", default=RESEARCH)
    ap.add_argument("--binary", default=os.path.join(ROOT, ".build", "release", "ReadAloud"))
    ap.add_argument("--baseline", help="readings from --baseline-out (default: the before readings in names.source.json)")
    ap.add_argument("--baseline-out", help="record today's readings into this file and stop")
    args = ap.parse_args()

    research, batches, overrides = load_research(args.research)
    names = sorted(research, key=lambda n: (int(research[n].get("rank") or 0) == 0, int(research[n].get("rank") or 0), n))

    if args.baseline_out:
        if os.path.exists(PACK):
            sys.exit(f"{PACK} exists: the baseline has to be read without the names pack")
        json.dump(readings(args.binary, names), open(args.baseline_out, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
        print(f"{len(names)} names read into {args.baseline_out}")
        return

    if args.baseline:
        before = json.load(open(args.baseline, encoding="utf-8"))
    elif os.path.exists(SOURCE):
        before = {e["name"]: e["before"] for e in json.load(open(SOURCE, encoding="utf-8"))["entries"] if e.get("before")}
    else:
        sys.exit("no baseline: run --baseline-out before adding Lexicons/names.json")
    missing = [n for n in names if n not in before]
    if missing:
        sys.exit(f"{len(missing)} names have no baseline reading ({', '.join(missing[:5])}...)")

    gold = gold_words()
    tech = defaultdict(list)
    for t in json.load(open(os.path.join(ROOT, "Lexicons", "tech-lexicon.json"), encoding="utf-8")):
        tech[t["word"].lower()].append(t)

    # Decide.
    pack, dropped = [], []
    for n in names:
        e = research[n]
        e["gb_effective"] = e.get("gb_effective") or e.get("gb") or e.get("us") or ""
        e["shipped"] = False
        if e["disposition"] != "corrected":
            continue
        why = hold_back(e, gold, before)
        if why:
            e["drop_reason"], e["drop_detail"] = why
            dropped.append({"rank": e.get("rank"), "name": n, "batch": e["batch"], "reason": why[0], "detail": why[1],
                            "us": e["us"], "gb": e["gb_effective"]})
            continue
        e["shipped"] = True
        hits = tech_hits(n, tech)
        if hits:
            e["tech_clash"] = [{"word": t["word"], "match": t.get("match"), "us": t["us"]} for t in hits]
        pack.append({"word": n, "match": "name", "us": e["us"], "gb": e["gb_effective"], "dictation": "never"})

    with open(PACK, "w", encoding="utf-8") as f:
        f.write("[\n" + ",\n".join(json.dumps(p, ensure_ascii=False, separators=(",", ":")) for p in pack) + "\n]\n")

    # Read every researched name again with the pack in place.
    after = readings(args.binary, names)
    not_as_written = []
    for n in names:
        e = research[n]
        if e["shipped"]:
            a = after[n]
            if (a["us"], a["gb"], a["us_sentence"], a["gb_sentence"]) != (e["us"], e["gb_effective"], e["us"], e["gb_effective"]):
                not_as_written.append(n)
                e["reads_as_written"] = False
            else:
                e["reads_as_written"] = True

    # Source file.
    keep = ["rank", "name", "batch", "disposition", "shipped", "drop_reason", "drop_detail", "reads_as_written",
            "language", "region", "ipa", "us", "gb", "respelling", "source", "url", "confidence", "alternatives", "notes",
            "transliteration", "word_check", "tech_clash", "verdict_us", "verdict_us_detail", "verdict_gb", "verdict_gb_detail"]
    entries = []
    for n in names:
        e = research[n]
        row = {k: e[k] for k in keep if k in e and e[k] not in (None, "")}
        row["before"] = before[n]
        row["after"] = after[n]
        entries.append(row)
    doc = {
        "about": "FIN-906 names pack: every researched name, with its evidence and disposition, today's reading "
                 "('before', the app without the pack) and the pack's ('after'); 'shipped' says whether it is in "
                 "Lexicons/names.json, 'drop_reason' why not. Built by lexicon-src/names/tools/assemble.py from the "
                 "checked research batches; p-batches win over n-batches for the same name.",
        "batches": batches,
        "special_batch_overrides": overrides,
        "dropped": dropped,
        # Merge decisions written by hand (tech-list entries removed in the names pack's
        # favour); kept from the previous file.
        "decisions": {},
        "entries": entries,
    }
    if os.path.exists(SOURCE):
        doc["decisions"] = json.load(open(SOURCE, encoding="utf-8")).get("decisions", {})
    with open(SOURCE, "w", encoding="utf-8") as f:
        f.write("{\n")
        for k in ("about", "batches", "special_batch_overrides", "dropped", "decisions"):
            f.write(f"{json.dumps(k)}: {json.dumps(doc[k], ensure_ascii=False)},\n")
        f.write('"entries": [\n' + ",\n".join(json.dumps(r, ensure_ascii=False) for r in entries) + "\n]\n}\n")

    # Ledger.
    path = os.path.join(NAMES, "ledger.tsv")
    with open(path, encoding="utf-8") as f:
        header = f.readline().rstrip("\n").split("\t")
        lines = [line.rstrip("\n").split("\t") for line in f]
    col = header.index("disposition")
    by_rank = {int(e.get("rank") or 0): e for e in research.values() if int(e.get("rank") or 0)}
    ledger_rows = {}
    for parts in lines:
        e = by_rank.get(int(parts[0]))
        if e is None:
            continue
        if parts[1] != e["name"]:
            sys.exit(f"ledger rank {parts[0]} is {parts[1]}, the research says {e['name']}")
        parts[col] = ("corrected" if e["shipped"] else "corrected-held-back") if e["disposition"] == "corrected" else e["disposition"]
        ledger_rows[e["name"]] = parts
    with open(path, "w", encoding="utf-8", newline="") as f:
        f.write("\t".join(header) + "\n")
        for parts in lines:
            f.write("\t".join(parts) + "\n")

    # Coverage.
    manifest = {}
    with open(os.path.join(NAMES, "manifest.tsv"), encoding="utf-8") as f:
        h = f.readline().rstrip("\n").split("\t")
        for line in f:
            r = dict(zip(h, line.rstrip("\n").split("\t")))
            manifest[r["name"]] = r

    def status(e):
        if e["disposition"] == "corrected":
            return "corrected and shipped" if e["shipped"] else "corrected, held back"
        return {"already-correct": "already correct"}.get(e["disposition"], e["disposition"])

    def totals(rows):
        c = Counter(status(e) for e in rows)
        out = {"audited": len(rows)}
        for k in ("already correct", "corrected and shipped", "corrected, held back", "unresolved", "protect-word", "not-a-name"):
            out[k] = c[k]
        out["reads as intended now"] = c["already correct"] + c["corrected and shipped"] - \
            sum(1 for e in rows if e["shipped"] and not e.get("reads_as_written", True))
        return out

    rows = [research[n] for n in names]
    researched_ranks = {int(e.get("rank") or 0) for e in rows}
    ledger_total = len(lines)
    by_bucket_left = Counter()
    for parts in lines:
        if int(parts[0]) not in researched_ranks:
            by_bucket_left[parts[header.index("bucket")]] += 1

    def breakdown(key, top=40):
        groups = defaultdict(list)
        for e in rows:
            groups[key(e) or "unknown"].append(e)
        ordered = sorted(groups.items(), key=lambda kv: -len(kv[1]))[:top]
        return {k: totals(v) for k, v in ordered}

    persian = [e for e in rows if e["batch"].startswith("p")]
    research_block = {
        "about": "Phase 4 (assembly): the researched names (n-batches for the top ranks, p0001 for Persian names) "
                 "and what the pack does with them. 'Handled' means read as intended now (already correct, or "
                 "corrected and shipped), or decided on purpose (protect-word, not-a-name). Names not yet researched "
                 "and names in other scripts (unsupported) are not handled.",
        "batches": sorted(batches),
        "totals": totals(rows),
        "handled": sum(1 for e in rows if status(e) in ("already correct", "corrected and shipped", "protect-word", "not-a-name")),
        "ledger_rows": ledger_total,
        "researched_not_in_ledger": sum(1 for e in rows if not int(e.get("rank") or 0)),
        "not yet researched": ledger_total - len([r for r in researched_ranks if r]),
        "not yet researched, by bucket": dict(by_bucket_left.most_common()),
        "held back, by reason": dict(Counter(d["reason"] for d in dropped)),
        "shipped but not read as written": not_as_written,
        "by_rank_tier": {t: totals([e for e in rows if tier(e.get("rank")) == t])
                         for t in ("1-1000", "1001-2500", "2501-5000", "5001+", "not in the ledger")},
        "by_origin": breakdown(lambda e: manifest.get(e["name"], {}).get("origin")),
        "by_language": breakdown(lambda e: (e.get("language") or "").split(" (")[0].strip()),
        "persian_batch": {
            "batch": "p0001",
            "totals": totals(persian),
            "also_in_an_n_batch": len(overrides),
            "readings_p0001_changed": [o["name"] for o in overrides if o["differs"]],
            "not_in_the_ledger": sorted(e["name"] for e in persian if not int(e.get("rank") or 0)),
        },
    }
    cov_path = os.path.join(NAMES, "coverage.json")
    coverage = json.load(open(cov_path, encoding="utf-8"))
    coverage["by_disposition"] = dict(Counter(line[col] for line in lines))
    coverage["research"] = research_block
    with open(cov_path, "w", encoding="utf-8") as f:
        json.dump(coverage, f, indent=1, ensure_ascii=False)
        f.write("\n")

    print(json.dumps({"shipped": len(pack), "held back": dict(Counter(d["reason"] for d in dropped)),
                      "totals": research_block["totals"], "not read as written": not_as_written}, ensure_ascii=False, indent=1))


if __name__ == "__main__":
    main()
