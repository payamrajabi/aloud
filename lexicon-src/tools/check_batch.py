"""Validate a batch file; write <name>.resolved.json (resolved phonemes + stack baselines + verdicts).
Usage: check_batch.py batches/out/b012.json   -> exit 1 if any ERROR; fix the batch and re-run until clean."""
import sys, json, re
from collections import Counter
from common import *  # noqa
path = sys.argv[1]
entries = json.load(open(path, encoding="utf-8"))
errs, warns, out, seen = [], [], [], {}
REQ = ["word", "match", "us", "category", "respelling", "source", "confidence", "spoken_variants", "dictation"]
for i, e in enumerate(entries):
    w = e.get("word", ""); tag = f"[{i}] {w!r}"
    for k in REQ:
        if k not in e or e[k] in (None, ""): errs.append(f"{tag}: missing {k}")
    if not w: continue
    key = w if e.get("match") in ("case-sensitive", "exact") else w.lower()
    if key in seen: errs.append(f"{tag}: duplicate of entry {seen[key]}")
    seen[key] = i
    if e.get("match") not in ("case-insensitive", "case-sensitive", "exact"): errs.append(f"{tag}: match must be case-insensitive|case-sensitive|exact")
    if e.get("category") not in CATEGORIES: errs.append(f"{tag}: category must be one of {sorted(CATEGORIES)}")
    if e.get("confidence") not in ("high", "medium", "low"): errs.append(f"{tag}: confidence must be high|medium|low")
    if e.get("dictation") not in DICTATION: errs.append(f"{tag}: dictation must be always|context|never")
    sv = e.get("spoken_variants")
    if not isinstance(sv, list) or not all(isinstance(s, str) and s.strip() for s in sv): errs.append(f"{tag}: spoken_variants must be a list of non-empty strings")
    try:
        us = resolve(e.get("us"), False); gb = resolve(e.get("gb"), True) if e.get("gb") else None
    except Exception as ex:
        errs.append(f"{tag}: could not resolve phonemes: {ex}"); continue
    if not us: errs.append(f"{tag}: empty us phonemes"); continue
    bu = bad_symbols(us, False); bg = bad_symbols(gb, True) if gb else []
    if bu: errs.append(f"{tag}: US {us!r} has symbols outside the US/Kokoro set: {bu}")
    if bg: errs.append(f"{tag}: GB {gb!r} has symbols outside the GB/Kokoro set: {bg}")
    if gb and set(gb) & US_ONLY: errs.append(f"{tag}: GB {gb!r} uses US-only symbols {sorted(set(gb) & US_ONLY)}")
    if not gb and set(us) & US_ONLY: errs.append(f"{tag}: US {us!r} uses US-only symbols {sorted(set(us) & US_ONLY)} -> add a 'gb' entry (British voices)")
    if "ˈ" not in us and sum(c in VOWELS for c in us) > 1: errs.append(f"{tag}: US {us!r} has no primary stress ˈ")
    r = dict(e); r["us"] = us
    if gb: r["gb"] = gb
    r["baseline_us"], r["baseline_gb"] = baseline(w, False), baseline(w, True)
    v = auto_verdict(r["baseline_us"], us); r["verdict"], r["verdict_detail"] = v
    r["tts_needed"] = v[0] != "right"
    out.append(r)
rp = re.sub(r"\.json$", ".resolved.json", path)
json.dump(out, open(rp, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
print(f"{len(entries)} entries, {len(errs)} errors; verdicts: {dict(Counter(r['verdict'] for r in out))}; wrote {rp}")
for x in errs: print("ERROR", x)
sys.exit(1 if errs else 0)
