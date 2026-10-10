"""Check a drug-names research batch (FIN-893). Brief: ../DRUGS-GUIDE.md.

Usage (from the repository root; python3 3.9+, standard library only):
  python3 -I lexicon-src/drugs/tools/check_drugs.py lexicon-src/drugs/batches/out/d0001.json [--table]

The batch is a JSON array, one entry per input row (batches/in/<same name>):
  {"rank", "word", "kind", "spelling", "match", "disposition", "us", "gb", "respelling",
   "evidence": [{"source", "says", "url"}], "confidence", "alternatives": [{"us", "gb", "context"}],
   "notes"}
disposition: corrected | already-correct | covered | ordinary-word | not-a-drug | unresolved.

It validates the phonemes (misaki symbols, one primary stress per word, stress marks right
before a vowel, a GB form where British differs: the names pack's rules), compares each reading
with today's (recorded in the input row before the pack existed) and with the respellings the
harvest found: the syllable count, and which syllable carries the main stress (MedlinePlus
marks it with an apostrophe, a maker's label with capitals). A disagreement is a WARN to answer
in `notes`, not an error: dictionaries and labels sometimes disagree, and four-syllable names
often carry two stresses. Writes <batch>.checked.json; exits 1 on any ERROR."""
import argparse, json, os, re, sys
from collections import Counter

HERE = os.path.dirname(os.path.abspath(__file__))
DRUGS = os.path.dirname(HERE)
ROOT = os.path.dirname(os.path.dirname(DRUGS))
sys.path.insert(0, os.path.join(ROOT, "lexicon-src", "names", "tools"))
from check_names import check_reading, blank  # noqa: E402  (no misaki needed)
from common import auto_verdict, VOWELS  # noqa: E402

DISPOSITIONS = ("corrected", "already-correct", "covered", "ordinary-word", "not-a-drug", "unresolved")
CONFIDENCE = ("high", "medium", "low")
SYLLABIC = VOWELS | {"ᵊ"}


def syllables(ps):
    return sum(1 for c in ps if c in SYLLABIC)


def stress_index(ps):
    """Index of the syllable carrying the primary stress (ᵊ counts as a syllable)."""
    n = 0
    for c in ps:
        if c == "ˈ":
            return n
        if c in SYLLABIC:
            n += 1
    return None


def respelling_shape(resp, style):
    """(syllable count, stressed syllable index) of a MedlinePlus or label respelling."""
    if style == "medlineplus":
        sylls = resp.split()
        # ' follows the primary stress, '' a secondary one ("hye'' droe klor'' oh thye' a zide").
        stress = next((i for i, s in enumerate(sylls) if s.endswith("'") and not s.endswith("''")), None)
        return len(sylls), stress
    sylls = [t for t in re.split(r"[\s-]+", resp.strip()) if t]
    caps = [i for i, t in enumerate(sylls) if t.isupper() and len(t) >= 2]
    marked = [i for i, t in enumerate(sylls) if t.endswith("'")]   # "Re stay' sis"
    if len(caps) == len(sylls):   # an all-capitals section: no stress shown
        return len(sylls), (marked[0] if marked else None)
    if caps:                      # capitals win over an apostrophe ("trin'-TELL-ix")
        return len(sylls), caps[0]
    return len(sylls), (marked[0] if marked else None)


def harvested_respellings(row):
    """[(style, respelling, url)] for the row's own word."""
    out = []
    ev = row.get("evidence") or {}
    for m in ev.get("medlineplus", []):
        if m.get("aligned"):
            out.append(("medlineplus", m["aligned"], m["url"]))
    for d in ev.get("dailymed", []):
        # Only a respelling of this word alone ("BREZTRI AEROSPHERE (...)" may cover two words).
        if d.get("for", d.get("term", "").lower()) == row["word"] and " " not in d.get("term", ""):
            out.append(("label", d["respelling"], d["url"]))
    seen, uniq = set(), []
    for o in out:
        if o[1].lower() not in seen:
            seen.add(o[1].lower())
            uniq.append(o)
    return uniq


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("batch")
    ap.add_argument("--input")
    ap.add_argument("--table", action="store_true")
    args = ap.parse_args()
    entries = json.load(open(args.batch, encoding="utf-8"))
    if not isinstance(entries, list):
        sys.exit("ERROR the batch must be a JSON array")
    inp_path = args.input or os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(args.batch))), "in",
                                          os.path.basename(args.batch))
    rows = {(r["word"], r["kind"]): r for r in json.load(open(inp_path, encoding="utf-8"))["rows"]}

    errs, warns, out, seen = [], [], [], {}
    for i, e in enumerate(entries):
        if not isinstance(e, dict):
            errs.append(f"[{i}]: not an object")
            continue
        key = (e.get("word"), e.get("kind"))
        tag = f"[{i}] {e.get('word')!r} ({e.get('kind')})"
        row = rows.get(key)
        if row is None:
            errs.append(f"{tag}: not in the input batch (word and kind exactly as given)")
            continue
        if key in seen:
            errs.append(f"{tag}: duplicate of entry [{seen[key]}]")
        seen[key] = i
        disp = e.get("disposition")
        if disp not in DISPOSITIONS:
            errs.append(f"{tag}: disposition must be one of {'|'.join(DISPOSITIONS)}")
        conf = e.get("confidence")
        if disp in ("corrected", "already-correct") and conf not in CONFIDENCE:
            errs.append(f"{tag}: {disp} needs confidence high|medium|low")
        need = {"corrected": ["spelling", "match", "us", "respelling", "evidence"],
                "already-correct": ["evidence"],
                "covered": ["notes"], "ordinary-word": ["notes"], "not-a-drug": ["notes"],
                "unresolved": ["notes"]}.get(disp, [])
        for k in need:
            if blank(e.get(k)):
                errs.append(f"{tag}: {disp} needs '{k}'")
        evs = e.get("evidence") or []
        if not isinstance(evs, list) or not all(isinstance(x, dict) and x.get("source") for x in evs):
            errs.append(f"{tag}: evidence must be a list of {{source, says, url}}")
            evs = []
        if disp == "corrected" and conf == "high" and not any(x.get("url") for x in evs):
            errs.append(f"{tag}: high confidence needs a source with a url")
        if e.get("match") not in (None, "", "case-insensitive", "case-sensitive"):
            errs.append(f"{tag}: match must be case-insensitive or case-sensitive")
        sp = e.get("spelling") or ""
        if sp and sp.lower() != row["word"].lower():
            warns.append(f"{tag}: spelling {sp!r} differs from the candidate's letters (fine for a cut-off "
                         "or misspelt candidate; say so in notes)")

        r = dict(e)
        t_us, t_gb = row.get("today_us", ""), row.get("today_gb", "")
        r.update(today_us=t_us, today_gb=t_gb, today_source=row.get("today_source", ""))
        us = (e.get("us") or "").strip()
        gb = (e.get("gb") or "").strip()
        if disp == "already-correct" and not us:
            r.update(us=t_us, gb=t_gb, gb_effective=t_gb, verdict_us="right", verdict_gb="right")
        elif us:
            gb_eff = check_reading(tag, us, gb, errs, warns)
            vu = auto_verdict(t_us, us)
            vg = auto_verdict(t_gb, gb_eff) if gb_eff else ("wrong", "no GB")
            r.update(us=us, gb=gb, gb_effective=gb_eff or "", verdict_us=vu[0], verdict_us_detail=vu[1],
                     verdict_gb=vg[0], verdict_gb_detail=vg[1])
            same = vu[0] == "right" and vg[0] == "right"
            if disp == "corrected" and same:
                warns.append(f"{tag}: matches today's reading ({t_us} / {t_gb}): use already-correct")
            if disp == "already-correct" and not same:
                errs.append(f"{tag}: already-correct, but your reading differs from today's ({t_us} / {t_gb}): "
                            "use corrected, or leave us/gb empty")
            # Shape against the harvested respellings.
            if disp in ("corrected", "already-correct"):
                for style, resp, url in harvested_respellings(row):
                    n, s = respelling_shape(resp, style)
                    if " " not in sp and " " not in us:
                        mine_n, mine_s = syllables(us), stress_index(us)
                        if n != mine_n:
                            warns.append(f"{tag}: {mine_n} syllables, but {style} '{resp}' has {n}: explain in notes if intended")
                        if s is not None and mine_s is not None and s != mine_s and n == mine_n:
                            warns.append(f"{tag}: main stress on syllable {mine_s + 1}, but {style} '{resp}' stresses "
                                         f"syllable {s + 1}: explain in notes if intended")
        if disp == "corrected" and e.get("match") == "case-insensitive" and (
                (row.get("dictionary_word") and (row.get("zipf") or 0) >= 3.0) or row.get("given_name")
                or (row.get("zipf") or 0) >= 3.5):
            gn = row.get("given_name")
            warns.append(f"{tag}: the spelling is also "
                         + ", ".join(x for x in ["a dictionary word" if row.get("dictionary_word") and (row.get("zipf") or 0) >= 3.0 else "",
                                                  f"a given name (rank {gn['rank']})" if gn else "",
                                                  f"common in text (Zipf {row.get('zipf')})" if (row.get("zipf") or 0) >= 3.5 else ""] if x)
                         + ": a general entry changes it everywhere; use ordinary-word, or say in notes why the drug reading is safe")
        for o in row.get("other_lists", []):
            if us and o.get("us") and o["us"] != us and disp == "corrected":
                warns.append(f"{tag}: {o['pack']} already reads {o['word']} as /{o['us']}/: say in notes which should win")
        alts = e.get("alternatives") or []
        if not isinstance(alts, list):
            errs.append(f"{tag}: alternatives must be a list")
            alts = []
        for j, a in enumerate(alts):
            if not isinstance(a, dict) or blank(a.get("us")) or blank(a.get("context")):
                errs.append(f"{tag}: alternative {j} needs us and context")
            else:
                check_reading(tag, a["us"].strip(), (a.get("gb") or "").strip(), errs, warns, what=f"alternative {j}")
        out.append(r)

    missing = [f"{w} ({k})" for (w, k) in rows if (w, k) not in seen]
    if missing:
        errs.append(f"{len(missing)} input rows have no entry: {', '.join(missing[:12])}")
    cp = re.sub(r"\.json$", "", args.batch) + ".checked.json"
    with open(cp, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, indent=1)
        f.write("\n")
    if args.table:
        for r in out:
            print(f"{r.get('rank', ''):>5} {r['word']:<22} {r.get('disposition', ''):<15} today {r['today_us']} "
                  f"-> {r.get('us') or '-'} [{r.get('verdict_us', '-')}/{r.get('verdict_gb', '-')}] {r.get('confidence') or ''}")
    disp = Counter(r.get("disposition") for r in out)
    conf = Counter(r.get("confidence") for r in out if r.get("disposition") == "corrected")
    print(f"{len(entries)} entries, {len(errs)} errors, {len(warns)} warnings; {dict(disp)}; corrected by confidence: "
          f"{dict(conf)}; wrote {cp}")
    for x in errs:
        print("ERROR", x)
    for x in warns:
        print("WARN ", x)
    sys.exit(1 if errs else 0)


if __name__ == "__main__":
    main()
