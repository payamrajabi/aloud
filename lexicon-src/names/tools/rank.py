"""Rank given names from the open sources into the candidate manifest (FIN-906, phase 1).

Usage: python3 -I rank.py --cache DIR [--top 100000] [--out ../manifest.tsv]

Reads what fetch.py downloaded into DIR (untrusted data: parsed, never executed) and writes
the manifest: one row per distinct given name, ranked by an estimate of how many people
carry it (`est_people`). See ../README.md for the method. Deterministic: the same files give
byte-identical output. Plain python3, standard library only."""
import argparse, csv, glob, io, json, os, re, sys, unicodedata, zipfile
from collections import Counter, defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from xlsx import Workbook  # noqa: E402

BIRTHS_FROM = 1925         # birth-register sources: only births from this year on (roughly, people alive now)
MIN_SAMPLE = 2000          # a fallback country needs this many Wikidata name-bearer pairs to stand alone
MIN_CELL = 2               # a Wikidata name counts for a country (or the pool) only with 2+ bearers there
csv.field_size_limit(10_000_000)

# Statistics-office sources: id -> what they are, and the Wikidata items whose population they stand for.
STATS = {
    "us_ssa": {"code": "US", "pop": ["Q30"], "anglo": True},
    "gb_ew_ons": {"code": "GB-EAW", "pop": ["Q21", "Q25"], "anglo": True},
    "gb_sct_nrs": {"code": "GB-SCT", "pop": ["Q22"], "anglo": True},
    "ie_cso": {"code": "IE", "pop": ["Q27"], "anglo": True},
    "ca_statcan": {"code": "CA", "pop": ["Q16"], "anglo": True},
    "fr_insee": {"code": "FR", "pop": ["Q142"], "anglo": False},
    "es_ine": {"code": "ES", "pop": ["Q29"], "anglo": False},
    "no_ssb": {"code": "NO", "pop": ["Q20"], "anglo": False},
}
# Countries of citizenship the statistics already stand for: their Wikidata bearers don't count again.
COVERED = {"Q30", "Q145", "Q21", "Q25", "Q22", "Q26", "Q27", "Q16", "Q142", "Q29", "Q20"}
ANGLO_ISO = {"US", "GB", "IE", "CA", "AU", "NZ"}
# Register placeholders, not names.
PLACEHOLDERS = {"baby", "infant", "unknown", "unnamed", "notnamed", "boy", "girl", "male", "female", "twin",
                "babyboy", "babygirl", "infantboy", "infantgirl", "_prenoms_rares", "nn", "xx", "xxx",
                "child", "son", "daughter", "a", "b", "c", "j", "x"}
NAME_OK = re.compile(r"^[\ẁ-ͯ'\- ]+$")


# ---------- spellings ----------

def clean(s):
    s = unicodedata.normalize("NFC", s or "")
    for a, b in (("’", "'"), ("‘", "'"), ("ʼ", "'"), ("‐", "-"), ("‑", "-")):
        s = s.replace(a, b)
    return " ".join(s.split())


def key_of(s):
    """Technical duplicates share a key: case, spacing, apostrophe and hyphen forms, Unicode
    normalisation. Accents, script and spelling stay distinct (Zoe/Zoë, Mohammed/Mohamed)."""
    return clean(s).casefold()


def valid(s):
    s = clean(s)
    if not s or not NAME_OK.match(s) or any(ch.isdigit() or ch == "_" for ch in s):
        return False
    letters = sum(ch.isalpha() for ch in s)
    # One letter is an initial, except in scripts where one character is a whole name (伟).
    if letters < 2 and not any(unicodedata.name(ch, "").startswith(("CJK", "HANGUL")) for ch in s):
        return False
    if len(s) > 40 or len(s.split(" ")) > 3:
        return False
    if s.startswith(("-", "'")) or s.endswith(("-", "'")):
        return False
    return key_of(s) not in PLACEHOLDERS


def title(s):
    """'JEAN-PIERRE' -> 'Jean-Pierre', "D'ANDRE" -> "D'Andre": for sources written in capitals."""
    out, cap = [], True
    for i, ch in enumerate(s):
        out.append(ch.upper() if cap else ch.lower())
        cap = ch in " -" or (ch == "'" and i <= 2)
    return "".join(out)


def mixed(s):
    return s != s.upper() and s != s.lower()


# ---------- statistics offices ----------

class Tally:
    def __init__(self):
        self.count = Counter()
        self.forms = defaultdict(Counter)
        self.years = set()

    def add(self, name, n, year=None):
        if not n or not valid(name):
            return
        name = clean(name)
        k = key_of(name)
        self.count[k] += n
        self.forms[k][name] += n
        if year:
            self.years.add(int(year))


def num(v):
    try:
        return float(str(v).replace(",", "").strip())
    except ValueError:
        return 0.0


def read_ssa(folder):
    t = Tally()
    files = sorted(glob.glob(os.path.join(folder, "mirror", "yob*.txt")))
    if os.path.exists(os.path.join(folder, "names.zip")):
        z = zipfile.ZipFile(os.path.join(folder, "names.zip"))
        files = [(n, z.read(n)) for n in sorted(z.namelist()) if re.match(r"yob\d{4}\.txt$", n)]
    else:
        files = [(os.path.basename(p), open(p, "rb").read()) for p in files]
    for name, body in files:
        year = int(name[3:7])
        if year < BIRTHS_FROM:
            continue
        for line in body.decode("latin-1").splitlines():
            parts = line.strip().split(",")
            if len(parts) == 3:
                t.add(parts[0], num(parts[2]), year)
    return t


def read_ons(folder):
    t = Tally()
    wb = Workbook(os.path.join(folder, "babynames1996to2025.xlsx"))
    for sheet in ("Table_1", "Table_2"):
        header = None
        for row in wb.rows(sheet):
            if header is None:
                if row and row[0] == "Name":
                    header = row
                continue
            if not row or not isinstance(row[0], str):
                continue
            for i, h in enumerate(header):
                if isinstance(h, str) and h.endswith("Count") and i < len(row) and isinstance(row[i], float):
                    t.add(row[0], row[i], h.split()[0])
    return t


def read_nrs(folder):
    t = Tally()
    z = zipfile.ZipFile(os.path.join(folder, "full-list-1974-2024.zip"))
    name = next(n for n in z.namelist() if n.startswith("full-list") and n.endswith(".csv"))
    for row in csv.DictReader(io.StringIO(z.read(name).decode("utf-8-sig", "replace"))):
        if int(row["Year"]) >= BIRTHS_FROM:
            t.add(row["Name"], num(row["Number"]), row["Year"])
    return t


def read_cso(folder):
    t = Tally()
    for f in ("VSA50.json", "VSA60.json"):
        d = json.load(open(os.path.join(folder, f), encoding="utf-8"))
        ids, size = d["id"], d["size"]
        dims = [d["dimension"][i]["category"] for i in ids]
        idx = [c["index"] if isinstance(c["index"], list) else sorted(c["index"], key=c["index"].get) for c in dims]
        stat_i, year_i, name_i = 0, 1, 2
        count_code = next(c for c in idx[stat_i] if not dims[stat_i]["label"][c].endswith("Rank"))
        s = idx[stat_i].index(count_code)
        values = d["value"]
        for y, year in enumerate(idx[year_i]):
            for n, code in enumerate(idx[name_i]):
                v = values[(s * size[1] + y) * size[2] + n]
                if v:
                    t.add(dims[name_i]["label"][code], v, year)
    return t


def read_statcan(folder):
    t = Tally()
    z = zipfile.ZipFile(os.path.join(folder, "17100147-eng.zip"))
    with z.open("17100147.csv") as f:
        for row in csv.DictReader(io.TextIOWrapper(f, encoding="utf-8-sig")):
            if row["Indicator"] == "Frequency" and row["GEO"] == "Canada" and row["VALUE"]:
                t.add(row["First name at birth"], num(row["VALUE"]), row["REF_DATE"][:4])
    return t


def read_insee(folder):
    t = Tally()
    z = zipfile.ZipFile(os.path.join(folder, "prenoms-2025-nat_csv.zip"))
    name = next(n for n in z.namelist() if n.endswith(".csv"))
    with z.open(name) as f:
        rows = csv.DictReader(io.TextIOWrapper(f, encoding="utf-8-sig"), delimiter=";")
        for row in rows:
            year = row.get("periode") or row.get("annais")
            first = row.get("prenom") or row.get("preusuel")
            if not year or not year.isdigit() or int(year) < BIRTHS_FROM:
                continue
            t.add(first, num(row.get("valeur") or row.get("nombre")), year)
    return t


def read_ine(folder):
    t = Tally()
    wb = Workbook(os.path.join(folder, "nombres_por_edad_media.xlsx"))
    for sheet in wb.sheets:
        header = None
        for row in wb.rows(sheet):
            cells = [c.strip() if isinstance(c, str) else c for c in row]
            if header is None:
                if "Nombre" in cells and "Frecuencia" in cells:
                    header = cells
                continue
            if len(cells) <= header.index("Frecuencia"):
                continue
            first, n = cells[header.index("Nombre")], cells[header.index("Frecuencia")]
            if isinstance(first, str):
                t.add(first, num(n))
    return t


def read_ssb(folder):
    t = Tally()
    d = json.load(open(os.path.join(folder, "10501.json"), encoding="utf-8"))
    ids, size = d["id"], d["size"]
    cats = {i: d["dimension"][i]["category"] for i in ids}
    order = {i: (c["index"] if isinstance(c["index"], list) else sorted(c["index"], key=c["index"].get)) for i, c in cats.items()}
    year = order["Tid"][-1]
    for flat, v in enumerate(d["value"]):
        if not v:
            continue
        pos, rest = {}, flat
        for i, n in zip(reversed(ids), reversed(size)):
            pos[i] = rest % n
            rest //= n
        if order["Tid"][pos["Tid"]] != year:
            continue
        code = order["Fornavn"][pos["Fornavn"]]
        t.add(cats["Fornavn"]["label"][code], v, year)
    return t


READERS = {"us_ssa": read_ssa, "gb_ew_ons": read_ons, "gb_sct_nrs": read_nrs, "ie_cso": read_cso,
           "ca_statcan": read_statcan, "fr_insee": read_insee, "es_ine": read_ine, "no_ssb": read_ssb}


# ---------- Wikidata (QLever TSV) ----------

def lit(v):
    """A QLever TSV cell: IRI -> Q-id, literal -> (text, language tag)."""
    v = v.strip()
    if v.startswith("<") and v.endswith(">"):
        return v.rsplit("/", 1)[-1][:-1], ""
    m = re.match(r'^"(.*)"(?:@([\w-]+)|\^\^<[^>]*>)?$', v, re.S)
    if not m:
        return v, ""
    text = re.sub(r"\\(.)", lambda x: {"t": "\t", "n": "\n", "r": "\r"}.get(x.group(1), x.group(1)), m.group(1))
    return text, m.group(2) or ""


def tsv(path):
    with open(path, encoding="utf-8") as f:
        header = f.readline().rstrip("\n").split("\t")
        for line in f:
            cells = line.rstrip("\n").split("\t")
            yield {h.lstrip("?"): (cells[i] if i < len(cells) else "") for i, h in enumerate(header)}


def read_wikidata(folder):
    items = {}
    for r in tsv(os.path.join(folder, "wd_given_names.tsv")):
        qid = lit(r["item"])[0]
        mul, en = lit(r["mul_label"])[0], lit(r["en_label"])[0]
        spelling = mul if valid(mul) else en if valid(en) else ""
        if not spelling:
            continue
        natives = [x for x in lit(r["native"])[0].split("|") if x]
        items[qid] = {"spelling": clean(spelling), "en": clean(en),
                      "native": [n.rsplit("@", 1) for n in natives if "@" in n],
                      "script": [x for x in lit(r["writing_system"])[0].split("|") if x],
                      "language": [x for x in lit(r["language"])[0].split("|") if x]}
    countries = {}
    for r in tsv(os.path.join(folder, "wd_countries.tsv")):
        qid = lit(r["country"])[0]
        pop = num(lit(r["population"])[0]) if r["population"] else 0
        countries[qid] = {"label": lit(r["label"])[0], "iso": lit(r["iso"])[0], "pop": pop,
                          "sovereign": bool(r["sovereign"]), "dissolved": bool(r["dissolved"])}
    bearers = defaultdict(Counter)   # item -> country (or "") -> people
    for r in tsv(os.path.join(folder, "wd_bearers.tsv")):
        qid = lit(r["name"])[0]
        if qid in items:
            bearers[qid][lit(r["country"])[0] if r["country"] else ""] += int(num(lit(r["n"])[0]))
    return items, countries, bearers


# ---------- ranking ----------

def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--cache", required=True)
    ap.add_argument("--top", type=int, default=100_000)
    ap.add_argument("--out", default=os.path.join(HERE, "..", "manifest.tsv"))
    ap.add_argument("--stats", default=os.path.join(HERE, "..", "sources.lock.json"))
    args = ap.parse_args()
    cache = os.path.abspath(os.path.expanduser(args.cache))

    items, countries, bearers = read_wikidata(os.path.join(cache, "wikidata"))
    pop = {q: c["pop"] for q, c in countries.items()}
    current = {q for q, c in countries.items() if c["sovereign"] and not c["dissolved"] and c["pop"] > 0}
    world = sum(pop[q] for q in current)

    tallies, source_pop = {}, {}
    for sid, info in STATS.items():
        tallies[sid] = READERS[sid](os.path.join(cache, sid))
        source_pop[sid] = sum(pop.get(q, 0) for q in info["pop"])
        print(f"{sid}: {len(tallies[sid].count):,} names, {sum(tallies[sid].count.values()):,.0f} people, "
              f"population {source_pop[sid]:,.0f}", file=sys.stderr)

    # Wikidata fallback: one sample per uncovered sovereign state with enough bearers, and one
    # pooled sample for the smaller states.
    by_country = defaultdict(Counter)   # country or "pool" -> key -> bearers
    wd_forms = defaultdict(Counter)
    wd_meta = defaultdict(lambda: {"native": set(), "script": set(), "language": set()})
    for qid, it in items.items():
        k = key_of(it["spelling"])
        meta = wd_meta[k]
        meta["script"].update(it["script"])
        meta["language"].update(it["language"])
        for text, tag in it["native"]:
            meta["native"].add((clean(text), tag))
        total = sum(bearers[qid].values())
        wd_forms[k][it["spelling"]] += total + 0.5     # +0.5: an item with no bearers still offers its spelling
        for c, n in bearers[qid].items():
            if c not in COVERED:
                by_country[c][k] += n
    sizes = {c: sum(v.values()) for c, v in by_country.items()}
    # People with no citizenship recorded, or only a former or non-sovereign one, stand for
    # no population alive today: they offer spellings but carry no weight.
    alone = sorted(c for c in by_country if c in current and sizes[c] >= MIN_SAMPLE)
    small = sorted(c for c in by_country if c in current and sizes[c] < MIN_SAMPLE)
    pool = Counter()
    for c in small:
        pool.update(by_country[c])
    weights = {c: pop[c] for c in alone}
    covered_pop = sum(source_pop.values())
    weights["pool"] = sum(pop[c] for c in small)
    samples = {c: by_country[c] for c in alone}
    samples["pool"] = pool
    sample_size = {c: sum(v.values()) for c, v in samples.items()}
    anglo_pop = sum(source_pop[s] for s in STATS if STATS[s]["anglo"]) + \
        sum(w for c, w in weights.items() if countries.get(c, {}).get("iso") in ANGLO_ISO)
    other_pop = sum(source_pop.values()) + sum(weights.values()) - anglo_pop

    # Score every spelling: people-equivalents from each source.
    keys = set(wd_forms)
    for t in tallies.values():
        keys.update(t.count)
    rows = []
    for k in keys:
        parts, anglo = {}, 0.0
        for sid, t in tallies.items():
            if t.count[k]:
                parts[sid] = source_pop[sid] * t.count[k] / sum_cache(t)
                if STATS[sid]["anglo"]:
                    anglo += parts[sid]
        wd_parts = {}
        for c, sample in samples.items():
            n = sample.get(k, 0)
            if n >= MIN_CELL and sample_size[c]:
                wd_parts[c] = weights[c] * n / sample_size[c]
                if countries.get(c, {}).get("iso") in ANGLO_ISO:
                    anglo += wd_parts[c]
        score = sum(parts.values()) + sum(wd_parts.values())
        if score <= 0:
            continue
        # How much more common the name is in English-speaking countries than elsewhere, per
        # head: 0.5 = equally common, 1 = only there. (A share of bearers would call John
        # non-English: there are more Johns outside the anglosphere than in it.)
        rate_in, rate_out = anglo / anglo_pop, (score - anglo) / other_pop
        rows.append((score, k, parts, wd_parts, anglo / score, rate_in / (rate_in + rate_out)))
    rows.sort(key=lambda r: (-r[0], r[1]))
    rows = rows[: args.top]

    with open(args.out, "w", encoding="utf-8", newline="") as f:
        f.write("rank\tname\test_people\tanglo_share\tanglo_affinity\tusage\tsources\tcountries\torigin\tscript\tnative\tevidence\n")
        for rank, (score, k, parts, wd_parts, anglo, affinity) in enumerate(rows, 1):
            name = display(k, tallies, wd_forms)
            meta = wd_meta.get(k)
            srcs = [s for s in STATS if s in parts]
            wd_bearers = Counter()
            for c, sample in samples.items():
                if sample.get(k):
                    wd_bearers[c] = sample[k]
            if k in wd_meta:
                srcs.append("wikidata")
            codes = [STATS[s]["code"] for s in STATS if s in parts]
            top = sorted(((n, c) for c, n in wd_bearers.items() if c != "pool"), key=lambda x: (-x[0], x[1]))[:3]
            codes += [countries[c]["iso"] or countries[c]["label"] for _, c in top if c in countries]
            origin, script, native = "", "", ""
            if meta:
                langs = sorted(meta["language"]) or sorted({t for _, t in meta["native"] if t and t != "mul"})
                origin = "/".join(langs[:5]) + (f"/+{len(langs) - 5}" if len(langs) > 5 else "")
                script = "/".join(sorted(meta["script"]))
                native = "/".join(sorted({n for n, _ in meta["native"] if key_of(n) != k}))
            ev = [f"{STATS[s]['code']}={tallies[s].count[k]:.0f}" for s in STATS if s in parts]
            if wd_bearers:
                ev.append("wd=" + ",".join(f"{countries[c]['iso'] or c if c in countries else c}:{n}"
                                              for n, c in sorted(((n, c) for c, n in wd_bearers.items()), key=lambda x: (-x[0], x[1]))[:4]))
            usage = english_usage(parts, source_pop, affinity)
            f.write(f"{rank}\t{name}\t{score:.0f}\t{anglo:.2f}\t{affinity:.2f}\t{usage}\t{','.join(srcs)}\t{','.join(codes)}\t"
                    f"{origin}\t{script}\t{native}\t{' '.join(ev)}\n")

    summary = {
        "births_from": BIRTHS_FROM, "min_sample": MIN_SAMPLE, "min_cell": MIN_CELL,
        "world_population": round(world), "covered_population": round(covered_pop),
        "anglophone_population": round(anglo_pop),
        "sources": {sid: {"names": len(t.count), "people": round(sum(t.count.values())),
                          "years": [min(t.years), max(t.years)] if t.years else None,
                          "population": round(source_pop[sid])} for sid, t in tallies.items()},
        "wikidata": {"given_name_items": len(items), "fallback_countries": len(alone),
                     "pooled_countries": len(small), "pool_population": round(weights["pool"]),
                     "fallback_population": round(sum(weights.values())),
                     "unweighted_bearers": sum(n for c, v in by_country.items() if c not in current for n in v.values()),
                     "pool_bearers": sample_size["pool"]},
        "candidates_scored": len(keys), "manifest_rows": len(rows),
    }
    files = {}
    for log in sorted(glob.glob(os.path.join(cache, "*", "fetch-log.json"))):
        sid = os.path.basename(os.path.dirname(log))
        for path, meta in json.load(open(log)).items():
            files[f"{sid}/{path}"] = {k: meta[k] for k in ("url", "bytes", "sha256", "fetched")}
    summary["files"] = files
    with open(args.stats, "w", encoding="utf-8") as f:
        json.dump(summary, f, indent=1, sort_keys=True, ensure_ascii=False)
        f.write("\n")
    print(json.dumps({k: v for k, v in summary.items() if k != "files"}, indent=1), file=sys.stderr)


def english_usage(parts, source_pop, affinity):
    """"english" when the spelling is mainly a name of English-speaking countries: more common
    there per head than elsewhere (affinity >= 0.6), and no non-English statistics office
    records it more than twice as often per head (Jesus: Spain). Otherwise "other". A
    triage hint about usage, not origin: Liam and Sophia are "english" here because the
    people who carry those spellings mostly live in English and say them the English way,
    which is the reading the pack wants (PACKS-GUIDE: anglicised the way English speakers
    who know them say it)."""
    anglo = [s for s in parts if STATS[s]["anglo"]]
    rate = sum(parts[s] for s in anglo) / sum(source_pop[s] for s in anglo) if anglo else 0.0
    peak = max((parts[s] / source_pop[s] for s in parts if not STATS[s]["anglo"]), default=0.0)
    return "english" if affinity >= 0.6 and rate > 0 and peak <= 2 * rate else "other"


_sums = {}


def sum_cache(t):
    if id(t) not in _sums:
        _sums[id(t)] = sum(t.count.values())
    return _sums[id(t)]


def display(k, tallies, wd_forms):
    """The spelling to show: Wikidata's label, else a mixed-case form from a register that
    keeps capitals inside names (not the SSA's, which writes 'Mckenzie'), else the SSA's,
    else the capitals written as a name."""
    if k in wd_forms:
        return max(wd_forms[k].items(), key=lambda x: (x[1], x[0]))[0]
    forms = Counter()
    for sid, t in tallies.items():
        if sid != "us_ssa":
            for f, n in t.forms.get(k, {}).items():
                if mixed(f):
                    forms[f] += n
    if forms:
        return max(forms.items(), key=lambda x: (x[1], x[0]))[0]
    if k in tallies["us_ssa"].forms:
        return max(tallies["us_ssa"].forms[k].items(), key=lambda x: (x[1], x[0]))[0]
    allforms = Counter()
    for t in tallies.values():
        allforms.update(t.forms.get(k, {}))
    return title(max(allforms.items(), key=lambda x: (x[1], x[0]))[0])


if __name__ == "__main__":
    main()
