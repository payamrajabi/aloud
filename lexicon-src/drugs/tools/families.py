"""List the drug pack's readings by stem family, to check that families read alike (FIN-893).

Usage (from the repository root): python3 -I lexicon-src/drugs/tools/families.py [--family -statin]

For every generic word in the checked research batches with a reading (corrected or
already-correct), groups it under the USAN stem it ends with and prints the word, its US
reading, disposition and confidence, so a reviewer can see at a glance when one -mab or
-sartan ends differently from its siblings. A difference isn't always wrong (sources do
differ), but it should be explained in that entry's notes. Plain python3."""
import argparse, glob, json, os, re

HERE = os.path.dirname(os.path.abspath(__file__))
DRUGS = os.path.dirname(HERE)
STEMS = ["statin", "pril", "sartan", "olol", "alol", "ilol", "dipine", "prazole", "azole", "tidine", "cycline",
         "floxacin", "mycin", "cillin", "cef", "vir", "zumab", "ximab", "umab", "mab", "cept", "gliflozin", "gliptin",
         "glutide", "tide", "triptan", "gepant", "pam", "lam", "zepam", "azepam", "oxetine", "pramine", "triptyline",
         "afil", "tadine", "terol", "sone", "olone", "nide", "lukast", "parin", "xaban", "gatran", "grel", "dronate",
         "setron", "semide", "thiazide", "trel", "estrel", "gestrel", "sterone", "tinib", "ciclib", "lisib", "parib",
         "siran", "sen", "osin", "zosin", "tropium", "ium", "ate", "ine", "ide", "one", "ol"]


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--family")
    args = ap.parse_args()
    rows = []
    for p in sorted(glob.glob(os.path.join(DRUGS, "batches", "out", "d????.checked.json"))):
        for e in json.load(open(p, encoding="utf-8")):
            if e.get("kind") in ("generic", "salt") and e.get("us") and e.get("disposition") in ("corrected", "already-correct"):
                rows.append((os.path.basename(p)[:5], e))
    groups = {}
    for bid, e in rows:
        w = (e.get("spelling") or e["word"]).lower()
        stem = next((s for s in STEMS if w.endswith(s) and len(w) > len(s) + 2), None)
        if stem and (not args.family or args.family.strip("-") == stem):
            groups.setdefault(stem, []).append((bid, w, e))
    for stem in STEMS:
        g = groups.get(stem)
        if not g or (len(g) < 2 and not args.family):
            continue
        print(f"-{stem} ({len(g)})")
        for bid, w, e in sorted(g, key=lambda x: x[1]):
            print(f"  {w:<24} {e['us']:<28} {e.get('gb_effective') or e.get('gb') or '':<28} "
                  f"{e['disposition'][:9]:<9} {e.get('confidence') or '':<6} {bid}")


if __name__ == "__main__":
    main()
