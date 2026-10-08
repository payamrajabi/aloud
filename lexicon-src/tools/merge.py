"""Merge reviewed batches into the final lexicon + a slim runtime file for the app, with dictation-safety enforcement.
Outputs: tech-lexicon-10k.json (full), runtime/tech-lexicon.json (app), merge_report.json (stats, conflicts, downgrades)."""
import json, glob, os, re
from collections import Counter, defaultdict
from wordfreq import zipf_frequency
L = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RANK = {"high": 0, "medium": 1, "low": 2}
def k(e): return e["word"] if e["match"] in ("case-sensitive", "exact") else e["word"].casefold()
def clean(v): return re.sub(r"\s+", " ", re.sub(r"[^\w\s'&+#./-]", " ", v.lower())).strip(" .")
entries, conflicts = {}, []
for f in sorted(glob.glob(f"{L}/batches/out/b*.resolved.json")):
    asr = {}
    af = f.replace(".resolved.json", ".asr.json")
    if os.path.exists(af): asr = json.load(open(af, encoding="utf-8"))
    for e in json.load(open(f, encoding="utf-8")):
        e["batch"] = os.path.basename(f)[:4]
        if e["word"] in asr: e["asr"] = asr[e["word"]]
        kk = k(e)
        if kk in entries:
            o = entries[kk]
            win = e if RANK[e["confidence"]] < RANK[o["confidence"]] else o
            conflicts.append(dict(word=e["word"], kept=win["batch"], a=o["us"], b=e["us"]))
            if win is e: entries[kk] = e
        else: entries[kk] = e
# Owner-level overrides (overrides.json) win over any batch.
for o in json.load(open(f"{L}/overrides.json", encoding="utf-8")) if os.path.exists(f"{L}/overrides.json") else []:
    for e in entries.values():
        if e["word"] == o["word"]:
            e.update({x: o[x] for x in ("us", "gb", "respelling", "match", "dictation") if x in o}); e["override"] = o.get("why", "")
# Casing clashes (casing/*.result.json, an LLM pass): the term's lowercase/Titlecase or plural form is an ordinary
# word or name (Maui/MAUI, snowpack/Snowpack, canvas/Canva+s), so only the exact spelling may match.
CASE_SENSITIVE = set()
for f in glob.glob(f"{L}/casing/*.result.json"):
    CASE_SENSITIVE |= {it["term"] for it in json.load(open(f, encoding="utf-8")).get("case_sensitive", [])}
recased = []
for kk in list(entries):
    e = entries[kk]
    if e["word"] in CASE_SENSITIVE and e["match"] == "case-insensitive":
        e["match"] = "case-sensitive"; recased.append(e["word"])
        del entries[kk]; entries.setdefault(k(e), e)
# Lowercase hyphenated terms made of ordinary words (font-weight, line-height, pre-seed): in dictation the spoken form
# is the everyday phrase ("the font weight is off"), so dictation leaves them alone; reading still uses the entry.
for e in entries.values():
    if "-" in e["word"] and e["word"] == e["word"].lower() and e["dictation"] != "never" and \
       all(zipf_frequency(x, "en") >= 3.0 for x in re.split(r"[-\s]+", e["word"]) if x):
        e["dictation"] = "never"; e["dictation_note"] = "everyday phrase when spoken"
# Pre-release review fixes (2026-10-08). The misaki gold dictionary the app ships tells ordinary English words apart.
GOLD = json.load(open(os.environ.get("ALOUD_GOLD", os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "Vendor", "g2p", "us_gold.json")), encoding="utf-8"))
GOLD_LOWER = {g.lower() for g in GOLD}                 # any spelling, names and acronyms included
GOLD_WORDS = {g for g in GOLD if g == g.lower()}      # ordinary lowercase words only ("art", "mongo"; not "SQL", "Jason")
# Words whose everyday pronunciation depends on part of speech (exploit: verb vs noun) read better without an entry.
for kk in [kk for kk, e in entries.items() if e["match"] == "case-insensitive" and isinstance(GOLD.get(e["word"].lower()), dict)]:
    del entries[kk]
# Units and clock abbreviations only mean the unit right after a number ("16 GB", "9 AM"), never "mm, nice" or "I AM".
UNITS = {"bps", "fps", "GB", "Gbps", "GHz", "GiB", "Hz", "KB", "kbps", "kHz", "KiB", "MB", "Mbps", "MiB", "mm", "ms", "nm",
         "ns", "PB", "px", "TB", "Tbps", "THz", "μm", "μs", "rem", "AM", "PM"}
for e in entries.values():
    e["unit"] = e["word"] in UNITS
    if e["unit"]: e["dictation"] = "never"
    # All-caps acronyms spelled like ordinary words (ART, BIG, KISS): skipped in all-caps text ("BIG NEWS").
    e["caps_word"] = e["word"].isupper() and len(e["word"]) >= 2 and e["word"].lower() in GOLD_WORDS
# Tech context for dictation comes only from developer tech: engineering/cloud/data/AI/security terms, plus the
# company/product/hardware/design terms an LLM pass judged to be developer tools (evidence/*.result.json), and never
# from a term that is itself an ordinary word. Consumer brands (Netflix, iPhone, Tesla) no longer unlock rewrites.
DEV = {"engineering", "cloud", "data", "ai", "security"}
DEV_EXTRA = set()
for f in glob.glob(f"{L}/evidence/*.result.json"):
    DEV_EXTRA |= set(json.load(open(f, encoding="utf-8")).get("developer", []))
for e in entries.values():
    acronym = e["word"].isupper() and len(e["word"]) <= 5 and e["category"] in DEV      # SQL, API, JSON, CORS
    e["evidence"] = (e["category"] in DEV or e["word"] in DEV_EXTRA) and (acronym or e["word"].lower() not in GOLD_WORDS) and not e["unit"]
# dictation: gather variants (agent + observed ASR), enforce safety
# Forms real speech-to-text produces that the batches missed (the essay demo and the app's own regression suite).
ADD_VARIANTS = {"kubectl": {"cubic control"}}   # ("dino" can't go to Deno: DINO is its own term)
by_variant = defaultdict(set)
for e in entries.values():
    vs = {clean(v) for v in e.get("spoken_variants", [])}
    for key in ("heart", "michael"):
        if e.get("asr", {}).get(key): vs.add(clean(e["asr"][key]))
    canon = clean(e["word"])
    vs = {v for v in vs if v and v != canon}
    e["_variants"] = sorted(vs | ADD_VARIANTS.get(e["word"], set()))
    for v in e["_variants"]: by_variant[v].add(k(e))
# Collisions: one spoken form claimed by several terms. Same-term aliases go to one canonical spelling; genuinely
# ambiguous forms are dropped from everyone (dictation then leaves them as heard). Anything not listed: dropped.
OWNER = {"dali": "DALL-E", "dolly": "DALL-E", "exa flop": "exaflop", "peta flops": "petaflops", "tek ton": "Tekton",
         "bio tech": "biotech", "d to c": "DTC", "m s a": "MSA", "nucks": "Nuxt", "o t": "OT", "waff": "WAF",
         "ader": "Aider", "et see": "Etsy", "w and b": "W&B", "wix dot com": "Wix.com", "you fee": "eufy",
         "eye oh": "I/O", "i o": "I/O", "p and g": "PNG", "message pack": "MessagePack", "ant d": "antd",
         "shad c n": "shadcn", "shad cn": "shadcn", "shad see en": "shadcn", "shadcn ui": "shadcn/ui", "read me": "README",
         "yamel": "YAML", "zed shell": "zsh", "zee shell": "zsh", "cmd k": "Cmd+K", "command k": "Cmd+K",
         "command-k": "Cmd+K", "t l d r": "TL;DR", "zel": "Zelle", "zell": "Zelle", "z standard": "Zstandard",
         "premier pro": "Premiere Pro", "pro res": "ProRes", "eleven t y": "11ty", "imagine 4": "Imagen 4",
         "r three f": "R3F", "u e five": "UE5", "ue five": "UE5", "zero day": "zero-day", "mono space": "monospace"}
canon_keys = {clean(e["word"]) for e in entries.values()}
resolved_collisions = []
for v, owners in list(by_variant.items()):
    if v in canon_keys:                      # the variant is itself another term's spelling: never rewrite it away
        for e in entries.values():
            if v in e["_variants"]: e["_variants"].remove(v)
        resolved_collisions.append(dict(variant=v, words=sorted(owners), kept=None, why="is another term")); by_variant[v] = set(); continue
    if len(owners) < 2: continue
    want = OWNER.get(v); keep = None
    for kk in owners:
        if want and entries[kk]["word"].casefold() == want.casefold(): keep = kk
    for kk in owners:
        if kk != keep and v in entries[kk]["_variants"]: entries[kk]["_variants"].remove(v)
    by_variant[v] = {keep} if keep else set()
    resolved_collisions.append(dict(variant=v, words=sorted(owners), kept=entries[keep]["word"] if keep else None))
FUNC = {"a","an","the","is","it","its","of","to","in","on","and","or","for","as","at","by","be","are","was","i","my","we","you","so","if","no","not","do","up"}
def risky_variant(v):
    """Ordinary-English check at the PHRASE level. wordfreq scores a multi-word string by its separate words, so
    'super base' looked common. Single words: common word or name (zipf >= 3.3). Multi-word (hyphens count as gaps):
    letter runs ('a p i', 'gen a i') are safe; a phrase is risky only if it starts or ends with a small function word
    that isn't part of a spelled-letter run ('a genetic', 'red is', 'i clear')."""
    w = v.replace("-", " ").replace(".", " ").split()
    if not w: return False
    if len(w) == 1: return zipf_frequency(w[0], "en") >= 3.3
    letterish = lambda x: len(x) == 1 or x.isdigit()
    if all(letterish(x) for x in w): return False
    first = w[0] in FUNC and not letterish(w[1])
    last = w[-1] in FUNC and not letterish(w[-2])
    return first or last
# Ordinary-English judgement (ordinary/*.result.json, an LLM pass over every variant made only of real words):
# "drop" = an everyday word/phrase or a mishearing nobody would mean as the term; "context_only" = everyday, but in a
# tech sentence it almost always means the term. Variants the pass never saw fall back to word frequency.
JUDGED = {}
for f in glob.glob(f"{L}/ordinary/o[0-9].json"):          # every item the pass saw: "keep" unless listed below
    if os.path.exists(f.replace(".json", ".result.json")):
        for it in json.load(open(f, encoding="utf-8")): JUDGED[(clean(it["variant"]), it["term"])] = "keep"
for f in glob.glob(f"{L}/ordinary/*.result.json"):
    for bucket in ("drop", "context_only"):
        for it in json.load(open(f, encoding="utf-8")).get(bucket, []):
            JUDGED[(clean(it["variant"]), it["term"])] = bucket
# Strict second pass (strict/sN.{a,b}.result.json): two independent judges per chunk over every variant made only of
# dictionary words; the more careful verdict wins (drop > context_only > keep). Unlisted items in a judged chunk: keep.
RANKV = {"keep": 0, "context_only": 1, "drop": 2}
STRICT = {}
for f in glob.glob(f"{L}/strict/s[0-9].json"):
    res = [f.replace(".json", f".{x}.result.json") for x in ("a", "b")]
    if not all(os.path.exists(r) for r in res): continue
    for it in json.load(open(f, encoding="utf-8")): STRICT[(clean(it["variant"]), it["term"])] = "keep"
    for r in res:
        got = json.load(open(r, encoding="utf-8"))
        for bucket in ("drop", "context_only"):
            for it in got.get(bucket, []):
                key = (clean(it["variant"]), it["term"])
                if key in STRICT and RANKV[bucket] > RANKV[STRICT[key]]: STRICT[key] = bucket
# The flagship spoken forms, kept after the strict pass: tech context now comes only from developer terms, so
# "jason" and "sequel" change in "send the jason payload to the API" but not in "the sequel was great".
RESTORE = {("jason", "JSON"): "context_only", ("sequel", "SQL"): "context_only", ("jupiter", "Jupyter"): "context_only",
           ("oh auth", "OAuth"): "keep", ("cubic control", "kubectl"): "keep"}
FORCE_CONTEXT = {("p and g", "PNG"), ("log stash", "Logstash"), ("hot mail", "Hotmail")}
FORCE_DROP = {("sales force", "Salesforce"), ("sacey sharp", "C#")}   # "our sales force is two people"   # "Export it as P and G" vs "P and G reported earnings"
def real_words(w): return all(len(x) > 1 and not x.isdigit() and zipf_frequency(x, "en") >= 3.0 for x in w)
downgrades, collisions, dropped = [], [], []
for e in entries.values():
    risky = []
    for v in list(e["_variants"]):
        w = v.replace("-", " ").split()
        j = JUDGED.get((v, e["word"]))
        if j is None and len(w) == 1 and zipf_frequency(v, "en") >= 3.3: j = "drop"
        if j is None and len(w) > 1 and real_words(w): j = "context_only"
        sj = STRICT.get((v, e["word"]))
        if sj is None and len(w) == 1 and v in GOLD_LOWER: sj = "drop"            # an unjudged dictionary word
        if sj is not None and RANKV[sj] > RANKV.get(j or "keep", 0): j = sj
        if (v, e["word"]) in RESTORE: j = RESTORE[(v, e["word"])]
        if (v, e["word"]) in FORCE_CONTEXT: j = "context_only"
        if (v, e["word"]) in FORCE_DROP: j = "drop"
        if j == "drop":
            e["_variants"].remove(v); dropped.append(dict(word=e["word"], variant=v)); continue
        if j == "context_only" or risky_variant(v): risky.append((v, round(zipf_frequency(v, "en"), 2)))
        if len(by_variant[v]) > 1: collisions.append(dict(variant=v, words=sorted(by_variant[v])))
    # Risky variants are gated one by one in the app (spoken_context_only). A "context" entry whose own spelling is
    # no ordinary word ("json", "sudo", "svelte" is not; "mongo" is) needs no entry-wide gate any more: its safe
    # variants ("sue dough", "o auth") and its recasing apply anywhere, while the risky ones stay gated one by one.
    if e["dictation"] == "context" and e["match"] != "case-sensitive" and e["word"].lower() not in GOLD_WORDS:
        e["dictation"] = "always"; e["promoted"] = True
        # Its agent gated it for a reason: a one-word variant that is any recognisable word or name ("kates" for K8s)
        # stays gated even though it isn't in the dictionary.
        for v in e["_variants"]:
            if " " not in v and "-" not in v and zipf_frequency(v, "en") >= 2.0 and v not in [x for x, _ in risky]:
                risky.append((v, round(zipf_frequency(v, "en"), 2)))
    if risky: downgrades.append(dict(word=e["word"], risky=risky))
    e["dictation_risky"] = [v for v, _ in risky]
final = sorted(entries.values(), key=lambda e: e["word"].casefold())
json.dump(final, open(f"{L}/tech-lexicon-10k.json", "w", encoding="utf-8"), ensure_ascii=False, indent=1)
os.makedirs(f"{L}/runtime", exist_ok=True)
slim = []
for e in final:
    r = {"word": e["word"], "match": e["match"], "us": e["us"]}
    if e.get("gb"): r["gb"] = e["gb"]
    r["dictation"] = e["dictation"]
    if e["unit"]: r["unit"] = True
    if e["caps_word"]: r["caps_word"] = True
    if e["dictation"] != "never" and not e["evidence"]: r["evidence"] = False
    if e["dictation"] != "never" and e["_variants"]:
        r["spoken"] = e["_variants"]
        if e["dictation_risky"]: r["spoken_context_only"] = e["dictation_risky"]
    slim.append(r)
json.dump(slim, open(f"{L}/runtime/tech-lexicon.json", "w", encoding="utf-8"), ensure_ascii=False, separators=(",", ":"))
rep = dict(total=len(final), verdicts=dict(Counter(e["verdict"] for e in final)),
           confidence=dict(Counter(e["confidence"] for e in final)), categories=dict(Counter(e["category"] for e in final)),
           dictation=dict(Counter(e["dictation"] for e in final)),
           asr_exact=sum(1 for e in final if e.get("asr", {}).get("ok")), asr_tested=sum(1 for e in final if "asr" in e),
           conflicts=conflicts, context_only_variants=downgrades, dropped_variants=dropped, resolved_collisions=resolved_collisions, made_case_sensitive=recased, variant_collisions=list({c["variant"]: c for c in collisions}.values())[:500],
           runtime_bytes=os.path.getsize(f"{L}/runtime/tech-lexicon.json"))
json.dump(rep, open(f"{L}/merge_report.json", "w", encoding="utf-8"), ensure_ascii=False, indent=1)
print(json.dumps({x: rep[x] for x in ("total", "verdicts", "confidence", "dictation", "asr_exact", "asr_tested", "runtime_bytes")}, ensure_ascii=False))
print("conflicts:", len(conflicts), "entries with context-only variants:", len(downgrades), "dropped variants:", len(dropped), "collisions left:", len(collisions), "resolved:", len(resolved_collisions))
