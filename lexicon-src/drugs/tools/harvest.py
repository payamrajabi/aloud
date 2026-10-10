"""Gather pronunciation evidence for every drug-name candidate (FIN-893).

Usage (from the repository root, after rank.py):
  python3 -I lexicon-src/drugs/tools/harvest.py [--cache ~/Library/Caches/aloud-drugs]
      [--only medlineplus,dailymed,wiktionary] [--limit N]

Three sources, each read politely (one request a second per site) through net.py's cache:
  medlineplus  MedlinePlus Drug Information (US National Library of Medicine; the monographs
               are ASHP's AHFS Patient Medication Information). Each monograph gives the
               generic name's pronunciation as a respelling, "pronounced as (a tore' va sta
               tin)": the apostrophe follows the stressed syllable. The A-Z index also maps
               brand names to their generic monograph.
  dailymed     FDA-approved labels on DailyMed (NLM). A maker's Medication Guide or Patient
               Information often prints the brand's own pronunciation after its name:
               "ELIQUIS (ELL eh kwiss) (apixaban)". Capitals mark the stressed syllable.
  wiktionary   English Wiktionary's IPA for the word, when it has an entry.

Writes lexicon-src/drugs/evidence.json: for each candidate (by word and kind) the facts found,
each with its URL: short respelling or IPA strings only, never page text. Downloads stay in
<cache>/http (untrusted data, only parsed). Plain python3, standard library only."""
import argparse, csv, html, json, os, re, sys, threading, urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import net  # noqa: E402

DRUGS = os.path.dirname(HERE)
MLP = "https://medlineplus.gov/druginfo/"
DM = "https://dailymed.nlm.nih.gov/dailymed/services/v2/"
WIKT = "https://en.wiktionary.org/w/index.php?action=raw&title="

# Labelers that repackage other makers' products; their copies of a label often drop the
# Medication Guide's pronunciation line, so the maker's own label is tried first.
REPACKAGERS = ("remedyrepack", "aphena", "cardinal health", "bryant ranch", "a-s medication", "proficient rx",
               "nucare", "quality care", "pd-rx", "preferred pharmaceuticals", "direct_rx", "direct rx",
               "henry schein", "medsource", "lake erie", "northwind", "denton pharma", "asclemed", "unit dose services",
               "american health packaging", "major pharmaceuticals", "golden state medical", "coupler", "rpk pharma",
               "st. mary's", "aidarex", "physicians total care", "stat rx", "rebel distributors", "dispensing solutions",
               "contract pharmacy", "readymeds", "clinical solutions", "blenheim", "advanced rx", "safecor", "avkare",
               "avpak", "precision dose", "h.j. harkins", "liberty pharmaceuticals", "medvantx", "lifestar",
               "nucare pharmaceuticals", "keltman", "altura", "legacy pharmaceutical packaging", "carilion")
TITLE_NOISE = {"injection", "ophthalmic", "topical", "oral", "inhalation", "transdermal", "patch", "nasal", "spray",
               "vaginal", "rectal", "otic", "solution", "suspension", "and", "extended-release", "delayed-release",
               "subcutaneous", "intravenous", "implant", "powder", "kit", "lotion", "cream", "gel", "ointment", "shampoo",
               "foam", "film", "sublingual", "buccal", "chewable", "tablets", "capsules", "liquid", "intramuscular",
               "rdna", "origin", "human", "recombinant", "with", "albumin", "intrauterine", "system", "ring", "eye",
               "drops", "emulsion", "pen", "vaccine", "insert"}


def load_candidates():
    rows = list(csv.DictReader(open(os.path.join(DRUGS, "candidates.tsv"), encoding="utf-8"), delimiter="\t"))
    return rows


def display(row):
    """The spelling to look up: a brand as the claims file capitalises it, else lower case."""
    w = row["word"]
    if row["kind"] in ("brand", "device"):
        for ex in row["examples"].split(" | "):
            for tok in re.split(r"[\s/,()]+", ex):
                if tok.lower().strip("*®") == w:
                    t = tok.strip("*®")
                    return t if any(c.isupper() for c in t[1:]) else t[:1].upper() + t[1:]
        return w[:1].upper() + w[1:]
    return w


# ---------- MedlinePlus ----------

def mlp_index(cache):
    """name (lower) -> [(monograph url, label as listed)] from the A-Z pages."""
    idx = {}
    letters = [chr(c) for c in range(ord("A"), ord("Z") + 1)]
    for L in letters + ["0"]:
        url = MLP + (f"drug_{L}a.html" if L != "0" else "drug_00.html")
        st, body = net.get(cache, url)
        if st != 200:
            continue
        t = body.decode("utf-8", "replace")
        for li in re.findall(r"<li>(.*?)</li>", t, re.S):
            m = re.search(r'href="\./meds/(a\d+\.html)">([^<]+)</a>', li)
            if not m:
                continue
            target = MLP + "meds/" + m.group(1)
            label = html.unescape(re.sub(r"<[^>]+>", "", li.split("<em", 1)[0]))
            label = re.sub(r"\s+", " ", label).strip()
            name = label if "see" in li else html.unescape(m.group(2)).strip()
            key = re.sub(r"\(.*?\)", "", name).replace("®", "").strip().lower()
            idx.setdefault(key, []).append((target, name, "see" in li, html.unescape(m.group(2)).strip()))
    return idx


def mlp_monograph(cache, url):
    st, body = net.get(cache, url)
    if st != 200:
        return None
    t = body.decode("utf-8", "replace")
    m = re.search(r"<h1[^>]*>(.*?)</h1>", t, re.S)
    title = html.unescape(re.sub(r"<[^>]+>", "", m.group(1))).strip() if m else ""
    m = re.search(r"pronounced as\s*((?:\([^)]*\)\s*)+)", re.sub(r"<[^>]+>", " ", t), re.I)
    groups = [g.strip() for g in re.findall(r"\(([^)]*)\)", html.unescape(m.group(1)))] if m else []
    return {"title": title, "url": url, "pronounced": groups}


def title_words(title):
    t = re.sub(r"\(.*?\)", " ", title.lower())
    return [w for w in re.split(r"[\s,]+", t) if w and w not in TITLE_NOISE]


def align(title, groups, word):
    """The respelling group for `word` in a monograph title, when the groups line up with the words."""
    words = title_words(title)
    if word not in words or not groups:
        return None
    if len(groups) == len(words):
        return groups[words.index(word)]
    # Groups per ingredient (title split at commas and "and"), one word each.
    parts = [p for p in re.split(r",\s*|\s+and\s+", re.sub(r"\(.*?\)", " ", title.lower())) if p.strip()]
    parts = [[w for w in p.split() if w not in TITLE_NOISE] for p in parts]
    parts = [p for p in parts if p]
    if len(parts) == len(groups):
        for p, g in zip(parts, groups):
            if p == [word]:
                return g
            if word in p and len(g.split()) and len(p) == 1:
                return g
    return None


def harvest_medlineplus(cache, cands, out, limit):
    idx = mlp_index(cache)
    by_title_word = {}
    for key, items in idx.items():
        for target, name, is_see, title in items:
            if not is_see:
                for w in title_words(title):
                    by_title_word.setdefault(w, {})[target] = title
    done = 0
    for row in cands:
        w, kind = row["word"], row["kind"]
        ev = out.setdefault(f"{kind}:{w}", {})
        found = []
        if kind in ("generic", "salt"):
            # Monographs whose title has the fewest words first (a single-ingredient monograph's
            # respelling is the word's own); stop at the first that gives this word a respelling.
            targets = sorted(by_title_word.get(w, {}).items(), key=lambda kv: (len(title_words(kv[1])), kv[0]))
            for u, _ in targets[:4]:
                m = mlp_monograph(cache, u)
                if not m:
                    continue
                a = align(m["title"], m["pronounced"], w)
                found.append({"title": m["title"], "url": m["url"], "pronounced": m["pronounced"], "aligned": a})
                if a:
                    break
        else:
            key = (row.get("lookup") or w).lower()
            for target, name, is_see, title in idx.get(key, [])[:3]:
                m = mlp_monograph(cache, target)
                if m:
                    found.append({"brand_listed_as": name, "generic_monograph": m["title"], "url": m["url"],
                                  "generic_pronounced": m["pronounced"]})
        ev["medlineplus"] = found
        done += 1
        if limit and done >= limit:
            break


# ---------- DailyMed ----------

RESP = re.compile(r"\b([A-Za-z][A-Za-z0-9-]*)\s*(?:®|™|\(R\))?\s*\(([^()]{2,48})\)")


def looks_like_respelling(s):
    """Syllables of a respelling: two to eight short alphabetic pieces, at least one in capitals
    (the stressed syllable), and none of the little words that start a real parenthetical."""
    toks = [t for t in re.split(r"[\s-]+", s.strip()) if t]
    if not 2 <= len(toks) <= 8 or not all(re.fullmatch(r"[A-Za-z']{1,7}", t) for t in toks):
        return False
    if any(t.lower() in ("or", "and", "see", "the", "with", "for", "of", "table", "mg", "ml") for t in toks):
        return False
    return any(t.isupper() and len(t) >= 2 for t in toks)


def label_text(xml_bytes):
    t = xml_bytes.decode("utf-8", "replace")
    t = re.sub(r"<[^>]+>", " ", t)
    return re.sub(r"\s+", " ", html.unescape(t))


def harvest_dailymed(cache, cands, out, limit, words_of_interest):
    done = 0
    for row in cands:
        w, kind = row["word"], row["kind"]
        ev = out.setdefault(f"{kind}:{w}", {})
        if kind not in ("brand", "device"):
            continue
        name = display(row)
        st, body = net.get(cache, DM + "spls.json?" + urllib.parse.urlencode({"drug_name": name, "pagesize": 100}))
        labels = []
        if st == 200 and body:
            try:
                labels = json.loads(body.decode("utf-8")).get("data", [])
            except ValueError:
                labels = []
        def pref(l):
            t = l.get("title", "")
            lab = (re.findall(r"\[([^\]]*)\]\s*$", t) or [""])[0].lower()
            first = t.split(" ", 1)[0].lower().strip("®")
            return (first != w.split("-")[0], any(r in lab for r in REPACKAGERS), -int(l.get("spl_version", 0)), t)
        labels.sort(key=pref)
        found = []
        tried = 0
        for l in labels:
            if tried >= 2 or (found and any(f["term"].lower() == w for f in found)):
                break
            if pref(l)[0]:
                break
            tried += 1
            url = DM + f"spls/{l['setid']}.xml"
            st, xml = net.get(cache, url)
            if st != 200:
                continue
            text = label_text(xml)
            seen = set()
            for m in RESP.finditer(text):
                term, resp = m.group(1), m.group(2).strip()
                tl = term.lower()
                if tl != w and tl not in words_of_interest:
                    continue
                if not looks_like_respelling(resp) or resp.lower() == tl:
                    continue
                key = (tl, resp.lower())
                if key in seen:
                    continue
                seen.add(key)
                found.append({"term": term, "respelling": resp, "label": l.get("title", ""), "setid": l["setid"],
                              "url": f"https://dailymed.nlm.nih.gov/dailymed/drugInfo.cfm?setid={l['setid']}"})
        ev["dailymed"] = found
        done += 1
        if limit and done >= limit:
            break


# ---------- Wiktionary ----------

def harvest_wiktionary(cache, cands, out, limit):
    done = 0
    for row in cands:
        w, kind = row["word"], row["kind"]
        ev = out.setdefault(f"{kind}:{w}", {})
        found = []
        for page in [display(row)]:
            st, body = net.get(cache, WIKT + urllib.parse.quote(page))
            if st != 200 or not body:
                continue
            t = body.decode("utf-8", "replace")
            m = re.search(r"^==\s*English\s*==\s*$(.*?)(?=^==[^=]|\Z)", t, re.S | re.M)
            if not m:
                continue
            sec = m.group(1)
            ipas = re.findall(r"\{\{IPA\|en\|([^}]*)\}\}", sec)
            enpr = re.findall(r"\{\{enPR\|([^}]*)\}\}", sec)
            if ipas or enpr:
                found.append({"page": page, "url": "https://en.wiktionary.org/wiki/" + urllib.parse.quote(page),
                              "ipa": ipas, "enpr": enpr})
        ev["wiktionary"] = found
        done += 1
        if limit and done >= limit:
            break


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--cache", default=net.DEFAULT_CACHE)
    ap.add_argument("--only", default="medlineplus,dailymed,wiktionary")
    ap.add_argument("--limit", type=int, default=0)
    args = ap.parse_args()
    cands = load_candidates()
    path = os.path.join(DRUGS, "evidence.json")
    old = json.load(open(path, encoding="utf-8")) if os.path.exists(path) else {}
    words = {r["word"] for r in cands}
    parts = {}
    jobs = []
    # Two workers per site, each on every other candidate: requests overlap their wait for the
    # server, and net.py still spaces the starts at least a second apart per site.
    for name in args.only.split(","):
        parts[name] = {}
        for half in (cands[0::2], cands[1::2]):
            fn = {"medlineplus": lambda o, c=half: harvest_medlineplus(args.cache, c, o, args.limit),
                  "dailymed": lambda o, c=half: harvest_dailymed(args.cache, c, o, args.limit, words),
                  "wiktionary": lambda o, c=half: harvest_wiktionary(args.cache, c, o, args.limit)}[name]
            jobs.append(threading.Thread(target=fn, args=(parts[name],), name=name))
    for j in jobs:
        j.start()
    for j in jobs:
        j.join()
    merged = {}
    for r in cands:
        k = f"{r['kind']}:{r['word']}"
        e = dict(old.get(k, {}))
        for name, p in parts.items():
            if k in p and name in p[k]:
                e[name] = p[k][name]
        merged[k] = e
    with open(path, "w", encoding="utf-8") as f:
        json.dump(merged, f, ensure_ascii=False, indent=1, sort_keys=True)
        f.write("\n")
    stats = {name: sum(1 for e in merged.values() if e.get(name)) for name in ("medlineplus", "dailymed", "wiktionary")}
    resp = sum(1 for k, e in merged.items() if any(x.get("aligned") for x in e.get("medlineplus", [])))
    dmb = sum(1 for k, e in merged.items() if any(x["term"].lower() == k.split(":", 1)[1] for x in e.get("dailymed", [])))
    print(f"wrote {path}: {len(merged)} candidates; with any hit: {stats}; MedlinePlus respelling aligned: {resp}; "
          f"DailyMed own-name respelling: {dmb}")


if __name__ == "__main__":
    main()
