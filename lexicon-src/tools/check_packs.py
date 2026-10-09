"""Check the lists the app ships (Lexicons/*.json) against each other before a pack lands.

Usage: python3 lexicon-src/tools/check_packs.py [--lexicons DIR] [--conflicts FILE]
       -> exit 1 on any ERROR; WARN and NOTE lines don't fail.

Each file is a pack: its name without .json, and without "-lexicon" (tech-lexicon.json is
"tech", finance.json "finance"), as the app reads it. A spelling is a word under its match
rule: "=BID" (case-sensitive or exact: that casing only) or "~bps" (any casing). Two
entries whose spellings can match the same text ("=PO" and "~po" both match "PO") are the
same spelling here too, since the app has to pick one of them for that text.

ERROR when
  - a spelling is in two or more files with different `us` phonemes and isn't listed in
    decisions/conflicts.json ({"word", "packs": [...], "readings": {pack: "what it says"},
    "why"}; it covers a clash when the word matches, ignoring case, and every pack in the
    clash is listed);
  - tech-lexicon.json has a pack_only entry (the tech list is always on: nothing in it can
    wait for a pack);
  - a file would be the "user" pack (that id is the person's own folder);
  - conflicts.json isn't an array of well-formed decisions.
WARN when a listed clash is between general entries with one match rule (the field's
reading should be pack_only, or the later file silently wins for everyone), or a listed
decision no longer matches any clash. A listed clash between general entries with
different match rules is a NOTE: the case-sensitive entry reads its own casing (the app
tries it first among keys of one length) and the case-insensitive one every other casing.
NOTE when a spelling is repeated with the same reading: of two general
copies the app keeps only the later file's, its dictation fields and `evidence` (and so
the pack its context counts for) included.
No third-party modules: plain python3."""
import argparse, json, os, sys, unicodedata
from collections import defaultdict

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
TECH = "tech"
USER = "user"


def pack_id(path):
    stem = os.path.splitext(os.path.basename(path))[0]
    return stem[:-8] if stem.endswith("-lexicon") and len(stem) > 8 else stem


def load_entries(path):
    data = json.load(open(path, encoding="utf-8"))
    if isinstance(data, dict):
        data = data.get("entries", data.get("words"))
    if not isinstance(data, list):
        raise ValueError("expected a JSON array of entries")
    return [e for e in data if isinstance(e, dict)]


def case_sensitive(match):
    return match in ("case-sensitive", "exact")


def spelling(word, match):
    return ("=" + word) if case_sensitive(match) else ("~" + word.lower())


def overlap(a, b):
    """Whether two entries (same lower-cased word) can match the same text."""
    if case_sensitive(a["match"]) and case_sensitive(b["match"]):
        return a["word"] == b["word"]
    return True


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--lexicons", default=os.path.join(ROOT, "Lexicons"))
    ap.add_argument("--conflicts", default=os.path.join(ROOT, "lexicon-src", "decisions", "conflicts.json"))
    args = ap.parse_args()
    errors, warns, notes = [], [], []

    # Every file's entries, one per spelling (a later copy in the same file replaces an earlier one).
    files = sorted(f for f in os.listdir(args.lexicons) if f.endswith(".json"))
    by_word = defaultdict(list)   # lower-cased word -> entries from every file
    order = {}                    # pack -> load position (later files win in the app)
    for i, name in enumerate(files):
        path = os.path.join(args.lexicons, name)
        pack = pack_id(path)
        order[pack] = i
        if pack == USER:
            errors.append(f"{name}: the pack id \"user\" is reserved for the person's own folder; rename the file")
        try:
            entries = load_entries(path)
        except Exception as ex:
            errors.append(f"{name}: {ex}")
            continue
        own = {}
        for e in entries:
            word, us = e.get("word"), e.get("us")
            if not isinstance(word, str) or not word.strip() or not isinstance(us, str) or not us.strip():
                continue
            word = unicodedata.normalize("NFC", word.strip())
            match = e.get("match") if e.get("match") in ("case-sensitive", "case-insensitive", "exact") else (
                "case-sensitive" if e.get("match") is None else "case-insensitive")
            item = {"word": word, "match": match, "us": us.strip(), "pack": pack, "file": name,
                    "pack_only": e.get("pack_only") is True}
            own[spelling(word, match)] = item
            if pack == TECH and item["pack_only"]:
                errors.append(f"{name}: {word}: pack_only isn't allowed in the tech list (it's always on); "
                              "drop the flag or move the entry to a field pack")
        for item in own.values():
            by_word[item["word"].lower()].append(item)

    # Decisions on clashes.
    decisions = []
    if os.path.exists(args.conflicts):
        try:
            raw = json.load(open(args.conflicts, encoding="utf-8"))
            if not isinstance(raw, list):
                raise ValueError("expected a JSON array")
            for i, d in enumerate(raw):
                ok = (isinstance(d, dict) and isinstance(d.get("word"), str) and d["word"].strip()
                      and isinstance(d.get("packs"), list) and len(d["packs"]) >= 2
                      and all(isinstance(p, str) for p in d["packs"])
                      and isinstance(d.get("readings"), dict) and isinstance(d.get("why"), str) and d["why"].strip())
                if not ok:
                    errors.append(f"conflicts.json [{i}]: needs word, packs (two or more), readings and why")
                    continue
                missing = [p for p in d["packs"] if p not in d["readings"]]
                if missing:
                    warns.append(f"conflicts.json [{i}] {d['word']}: no reading given for {', '.join(missing)}")
                decisions.append({"word": d["word"].strip().lower(), "packs": set(d["packs"]), "used": False, "index": i})
        except Exception as ex:
            errors.append(f"{os.path.basename(args.conflicts)}: {ex}")

    # Clashes: entries from different files that can match the same text.
    clashes = 0
    for word, items in sorted(by_word.items()):
        if len({it["pack"] for it in items}) < 2:
            continue
        # Group entries that overlap (transitively) into one spelling.
        groups = []
        for it in items:
            joined = [g for g in groups if any(overlap(it, o) for o in g)]
            merged = [it] + [o for g in joined for o in g]
            groups = [g for g in groups if g not in joined] + [merged]
        for g in groups:
            packs = {it["pack"] for it in g}
            if len(packs) < 2:
                continue
            readings = {it["us"] for it in g}
            shown = "; ".join(f"{it['pack']}{' (pack_only)' if it['pack_only'] else ''} {it['word']} "
                              f"[{it['match']}] /{it['us']}/" for it in sorted(g, key=lambda x: order[x["pack"]]))
            if len(readings) == 1:
                general = [it for it in g if not it["pack_only"]]
                same_rule = len({spelling(it["word"], it["match"]) for it in general}) == 1
                kept = max(general, key=lambda x: order[x["pack"]])["pack"] if len(general) > 1 and same_rule else None
                notes.append(f"{g[0]['word']}: same reading in {', '.join(sorted(packs))}"
                             + (f"; the app keeps only {kept}'s entry, dictation fields and evidence included, so drop "
                                "the other copy once its fields are right" if kept else "") + f" ({shown})")
                continue
            clashes += 1
            decision = next((d for d in decisions if d["word"] == word and packs <= d["packs"]), None)
            if decision is None:
                errors.append(f"{g[0]['word']}: read differently in {', '.join(sorted(packs))} and not in conflicts.json: {shown}")
                continue
            decision["used"] = True
            if not any(it["pack_only"] for it in g):
                # One spelling under one match rule: the later file replaces the earlier for
                # everyone. Different match rules split the text instead: a case-sensitive
                # entry reads its own casing (the app tries it first) and a case-insensitive
                # one every other casing ("=Pir" in names, "~pir" in tech).
                same = defaultdict(list)
                for it in g:
                    same[spelling(it["word"], it["match"])].append(it)
                shadowed = [v for v in same.values() if len({it["pack"] for it in v}) > 1 and len({it["us"] for it in v}) > 1]
                if shadowed:
                    for v in shadowed:
                        last = max(v, key=lambda x: order[x["pack"]])
                        warns.append(f"{v[0]['word']}: listed, but no side is pack_only, so {last['pack']}'s reading wins "
                                     f"for everyone; mark the field's entry pack_only ({shown})")
                else:
                    split = "; ".join(f"{it['pack']} reads " + (f"\"{it['word']}\"" if case_sensitive(it["match"]) else "any other casing")
                                      for it in sorted(g, key=lambda x: (not case_sensitive(x["match"]), order[x["pack"]])))
                    notes.append(f"{g[0]['word']}: listed; split by casing: {split} ({shown})")
    for d in decisions:
        if not d["used"]:
            warns.append(f"conflicts.json [{d['index']}] {d['word']}: no longer matches a clash in {', '.join(sorted(d['packs']))}")

    total = sum(len(v) for v in by_word.values())
    print(f"{len(files)} files ({', '.join(pack_id(f) for f in files)}), {total} spellings, "
          f"{clashes} clash{'es' if clashes != 1 else ''}, {len(decisions)} listed decision{'s' if len(decisions) != 1 else ''}")
    for kind, lines in (("ERROR", errors), ("WARN", warns), ("NOTE", notes)):
        for line in lines:
            print(f"{kind}: {line}")
    print("FAILED" if errors else "OK")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
