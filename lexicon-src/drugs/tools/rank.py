"""Rank the drug-name candidates for the drugs pack (FIN-893).

Usage (from the repository root, after fetch.py):
  python3 -I lexicon-src/drugs/tools/rank.py [--cache ~/Library/Caches/aloud-drugs]
      [--generics 500] [--brands 500]

Writes lexicon-src/drugs/candidates.tsv: one row per *word* a reader meets on a label or
a prescription list, because the lexicon matches words ("insulin glargine" needs only
"glargine"; "Trelegy Ellipta" needs "Trelegy" and "Ellipta"). Columns:
  rank, word, kind, score, meps_rx, partd_claims, medicaid_claims, partb_spend_musd,
  examples, generic_of, why
kind: generic (an active ingredient's word), brand, salt (the salt or ester half of a
generic name on a label: besylate, succinate), device (an inhaler or pen name that is part
of the brand: Ellipta, KwikPen).

Score: 2024 US prescription volume, adding the three sources: MEPS prescriptions (ClinCalc
Top 300, all ages and payers), Medicare Part D claims and Medicaid claims, for every product
the word appears in. Part B (drugs given in clinics: biologics, cancer drugs) has no
comparable count, so its top drugs by spending are added as a tier of their own. The word
list then takes the top --generics generic words and --brands brand words, plus every
ClinCalc Top 300 ingredient, the Part B tier and a short curated list (CURATED below: drugs
the FIN-888 plan names, and the best-known over-the-counter brands, which the government
files undercount because most are bought without a prescription). Deterministic: the same
source files give the same candidates.tsv. Plain python3, standard library only."""
import argparse, csv, html, json, os, re, sys
from collections import defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import net  # noqa: E402

DRUGS = os.path.dirname(HERE)

# Salt and ester halves of a generic name ("amlodipine besylate"). Plain chemistry words
# (sodium, chloride, calcium) are ordinary generic words and stay kind=generic.
SALTS = set("""besylate besilate succinate tartrate bitartrate fumarate hemifumarate maleate mesylate dimesylate
bisulfate hyclate hydrobromide hydrochloride monohydrate dihydrate trihydrate sesquihydrate oxalate propionate
dipropionate furoate acetonide valerate decanoate pamoate xinafoate tosylate napsylate edisylate malate camsylate
palmitate stearate ethylsuccinate estolate lauroxil cypionate enanthate undecanoate medoxomil axetil proxetil
pivoxil mofetil disoproxil alafenamide hexanoate diacetate monobasic dibasic mononitrate dinitrate gluconate
lactobionate trometamol tromethamine meglumine erbumine lysinate benzathine procaine sulfonate monosodium
disodium dihydrochloride trifenatate bromide iodide nitrate sulfate phosphate acetate citrate carbonate
bicarbonate lactate glycinate aspartate orotate picolinate""".split())
# Plain chemistry words in that list are kept as generic words too (they're real words the
# dictionary knows; listing them as salts would only hide that).
PLAIN_SALTS = {"bromide", "iodide", "nitrate", "sulfate", "phosphate", "acetate", "citrate", "carbonate",
               "bicarbonate", "lactate", "gluconate", "hydrochloride"}

DEVICES = set("""ellipta diskus respimat handihaler solostar flexpen kwikpen flextouch inhub redihaler pressair
aerosphere twisthaler flexhaler autoinjector sensoready digihaler clickject penfill turbuhaler accuhaler evohaler
easyhaler genuair breezhaler neohaler podhaler rotacap spiromax trimbow""".split())

# Words that describe the product, not the drug.
DESCRIPTORS = set("""hcl hbr er xr xl sr cr dr la ir cd xt et odt hfa pf mdi dpi ext rel oral topical ophth ophthalmic
otic nasal vaginal rectal inj injection solution soln sol susp suspension cream ointment oint gel lotion patch
tablet tablets tab tabs capsule capsules cap caps syrup elixir spray inhaler inhalation powder drops drop kit pen
pens vial vials syringe syringes dose doses single multi plus max extra strength children childrens infant infants
adult adults liquid chewable chew micronized with and in of the mi spheres hum rec anlog analog conc u-100 u-200
u-500 24hr 12hr hr 1st tier preservative free starter pack pak sprinkle junior jr mix depot lar ped pediatric
regular reg mini lite forte ds ss dm pm am day night nighttime daytime severe cold flu sinus allergy relief
pain fever cough congestion original formula advanced complete total ultra rapid fast quick instant release
sodium-free sugar-free sf usp nf film coated chewables gummies gummy softgel softgels liquigels caplet caplets
gelcaps tablet's kids kid's child children's mg mcg ml g iu unit units vac vacc vaccine toxoid recombinant
adjuvanted adjuvant conj conjugate val dip crm syr inh soln. water extended base salts esters human complex oil
alcohol beta protein-bound fam- fam ado- eye ear chest prep mucus low high-dose stimulant arthritis denta gas
antacid antacid-antigas vitamin vitamins balance stool lubricant classic medication acne reliever magnesia milk
sensitive triple dry removal wax softener heartburn mouth once antifungal all aria anti-diarrheal antibiotic
one-step multidose unoready flexpro actpen l-a consta trinza maintena sustenna faspro respiclick hypopen
pushtronex sureclick tears laxative lax itch prenatal optive ringers lactated ringer's diskets dropsafe
clearlax tempo methoxy peg multivit pnv nph""".split())
# Short words kept although they have three letters or fewer (real drug-name words).
SHORT_OK = {"zinc", "urea"}
# Cut or run-together words the 30-character CMS names leave behind, mapped to the word
# they stand for (None drops the leftover).
FIXUPS = {"bictegrav": "bictegravir", "alafenam": "alafenamide", "insuln": "insulin", "mesylat": "mesylate",
          "maleat": "maleate", "monohyd": "monohydrate", "m-cryst": None, "di-hcl": None, "pedi": None,
          "w-fluoride": "fluoride", "alfa-epbx": "alfa", "dextrose-water": "dextrose", "peg-epoetin": "epoetin",
          "norethindron": "norethindrone", "hydrochlorothiazid": "hydrochlorothiazide", "emtricit": "emtricitabine",
          "tenofov": "tenofovir", "tenof": "tenofovir", "glycopyr": "glycopyrrolate", "umeclidin": "umeclidinium",
          "vilanter": "vilanterol", "dexametha": "dexamethasone", "dexameth": "dexamethasone",
          "pseudoephed": "pseudoephedrine", "butalb": "butalbital", "hydrocort": "hydrocortisone",
          "deruxtecn": "deruxtecan", "nanocrystallized": None, "macrocrystal": None, "microspheres": None,
          "alfa": None, "pegol": None, "isophane": None,
          "tart": "tartrate", "pads": None, "alfa-fcab": None, "fam-trastuzumab": "trastuzumab",
          "pertuzumab-trastuzumab-hy": "pertuzumab"}

SUPPLY_WORDS = ("needle", "syringe", "lancet", "test strip", "diagnostic", "glucose meter", "monitor", "sensor",
                "pump", "cartridge", "alcohol pad", "alcohol prep", "swab", "gauze", "bandage", "catheter", "ostomy",
                "spacer", "chamber", "nebulizer", "blood sugar", "blood-glucose", "urine", "ketone", "lancing",
                "transmitter", "dressing", "tape", "condom", "diaphragm", "pregnancy test", "per square centimeter",
                "skin sub", "graft", "membrane", "supplies", "device", "meter", "strip", "elastic", "glove", "pad,",
                "applicator", "irrigation", "electrolyte", "dialysis", "contrast", "radiopharm", "technetium",
                "contact lens", "nutritional", "formula", "food", "enteral")
VACCINE_WORDS = ("vac", "vaccine", "toxoid", "covid", "flu ", "pneumoc", "varicella", "zoster", "hep a", "hepatitis",
                 "mening", "tdap", "rsv", "immun glob", "immune glob", "(igg)", "rabies", "measles", "polio",
                 "hpv", "rotavirus", "typhoid", "cholera", "yellow fever", "encephalitis", "botulism", "allergenic",
                 "pollen", "extract")

# Curated additions, with the reason each group is here. Brands are spelled as the maker does.
CURATED = {
    "fin-888": {
        "why": "named in the FIN-888 plan",
        "generic": ["atorvastatin", "semaglutide", "tirzepatide", "adalimumab", "pembrolizumab"],
        "brand": ["Wegovy", "Mounjaro", "Humira", "Keytruda", "Ozempic", "Zepbound"],
    },
    "otc-us": {
        "why": "best-known US over-the-counter brands (bought mostly without a prescription, so the claims files undercount them)",
        "brand": ["Tylenol", "Advil", "Motrin", "Aleve", "Excedrin", "Bayer", "Midol", "Benadryl", "Claritin", "Zyrtec",
                  "Allegra", "Xyzal", "Flonase", "Nasacort", "Rhinocort", "Afrin", "Sudafed", "Mucinex", "Robitussin",
                  "Delsym", "NyQuil", "DayQuil", "Theraflu", "Dimetapp", "Coricidin", "Vicks", "ZzzQuil", "Unisom",
                  "Pepcid", "Prilosec", "Nexium", "Prevacid", "Zantac", "Tagamet", "Tums", "Rolaids", "Mylanta",
                  "Maalox", "Gaviscon", "Pepto-Bismol", "Imodium", "Kaopectate", "Dramamine", "Bonine", "Gas-X",
                  "Miralax", "Dulcolax", "Senokot", "Colace", "Metamucil", "Citrucel", "Ex-Lax", "Monistat",
                  "Lotrimin", "Lamisil", "Tinactin", "Neosporin", "Polysporin", "Cortizone", "Abreva", "Orajel",
                  "Anbesol", "Chloraseptic", "Cepacol", "Visine", "Systane", "Pataday", "Zaditor", "Lumify",
                  "Rogaine", "Nicorette", "NicoDerm", "Voltaren", "Salonpas", "Bengay", "Aspercreme", "Pedialyte",
                  "Emergen-C", "Alka-Seltzer", "Debrox", "Plan B", "Primatene", "Nytol", "Sominex"],
    },
    "otc-uk": {
        "why": "best-known UK over-the-counter brands (Aloud has British voices)",
        "brand": ["Nurofen", "Calpol", "Lemsip", "Beechams", "Piriton", "Piriteze", "Strepsils", "Rennie", "Gaviscon",
                  "Buscopan", "Canesten", "Anadin", "Solpadeine", "Sudocrem", "Germolene", "Olbas", "Night Nurse",
                  "Benylin", "Day Nurse", "Lyclear", "Dioralyte", "Movicol", "Fybogel", "Senokot", "Clarityn"],
    },
}


def num(x):
    try:
        return float(str(x).replace(",", ""))
    except ValueError:
        return 0.0


def clean_words(text):
    """Lower-cased words of a product or ingredient name, punctuation stripped (hyphens kept)."""
    text = html.unescape(text).replace("®", " ").replace("™", " ").replace("*", " ")
    text = re.sub(r"\([^)]*\)", " ", text)
    return [w for w in re.split(r"[\s,;/+&]+", text.lower()) if w]


def is_supply(name):
    n = name.lower()
    return any(s in n for s in SUPPLY_WORDS)


def is_vaccine(name):
    n = " " + name.lower() + " "
    return any(s in n for s in VACCINE_WORDS)


def strip_biologic_suffix(w):
    # FDA's four-letter biologic suffixes ("faricimab-svoa", "ravulizumab-cwvz").
    return re.sub(r"-[a-z]{4}$", "", w) if len(w) > 9 else w


def ingredient_words(generic):
    """(words, salts) of a generic name, combinations split."""
    words, salts = [], []
    g = generic.replace(";", "/")
    for part in g.split("/"):
        part = part.split(",")[0]   # "Insulin Glargine,Hum.Rec.Anlog"
        for w0 in clean_words(part.replace(".", " ") if re.search(r"[a-z]\.[a-z]{4,}", part.lower()) else part):
            w0 = strip_biologic_suffix(w0.strip(".-'"))
            # Run-together combinations ("norgestimate-ethinyl", "norethindrone-e"): split on hyphens
            # unless the word is a real hyphenated name (biologic suffixes are already gone).
            pieces = w0.split("-") if "-" in w0 and all(len(x) >= 5 or len(x) <= 1 for x in w0.split("-")) else [w0]
            for piece in pieces:
                piece = strip_biologic_suffix(piece)
                if piece in FIXUPS:
                    if FIXUPS[piece] is None:
                        continue
                    piece = FIXUPS[piece]
                if len(piece) < 3 or not re.search(r"[a-z]", piece) or re.search(r"\d", piece):
                    continue
                if piece in DESCRIPTORS:
                    continue
                if piece in SALTS:
                    salts.append(piece)
                    if piece not in PLAIN_SALTS:
                        continue
                words.append(piece)
    return words, salts


def brand_words(brand, generic_words):
    """(brand words, device words) of a product name, or ([], []) when it's a generic product."""
    ws = [w.strip(".-'") for w in clean_words(brand)]
    ws = [w for w in ws if w and not re.fullmatch(r"[\d.%-]+", w)]
    if not ws:
        return [], []
    first = ws[0]
    gw = set(generic_words)
    if first in DESCRIPTORS or first in SALTS or any(g.startswith(first) or first.startswith(g) for g in gw if len(g) >= 4):
        return [], []
    brands, devices = [], []
    for w in ws:
        if w in DEVICES:
            devices.append(w)
        elif w in DESCRIPTORS or w in SALTS or len(w) < 3 or re.search(r"\d", w) or w in gw:
            continue
        else:
            brands.append(w)
    return brands, devices


def load_clincalc(path):
    t = open(path, encoding="utf-8").read()
    out = []
    for row in re.findall(r"<tr[^>]*>(.*?)</tr>", t, re.S):
        cells = [html.unescape(re.sub(r"<[^>]+>", "", c)).strip() for c in re.findall(r"<td[^>]*>(.*?)</td>", row, re.S)]
        if len(cells) >= 3 and cells[0].isdigit():
            out.append((int(cells[0]), cells[1], num(cells[2])))
    return out


def load_cms(path, claims_col, spend_col=None):
    rows = []
    for r in csv.DictReader(open(path, encoding="utf-8-sig")):
        if "Mftr_Name" in r and r["Mftr_Name"] != "Overall":
            continue
        rows.append({"brand": (r.get("Brnd_Name") or "").strip(), "generic": (r.get("Gnrc_Name") or "").strip(),
                     "claims": num(r.get(claims_col)), "spend": num(r.get(spend_col)) if spend_col else 0.0})
    return rows


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--cache", default=net.DEFAULT_CACHE)
    ap.add_argument("--generics", type=int, default=500)
    ap.add_argument("--brands", type=int, default=500)
    ap.add_argument("--partb", type=int, default=60, help="top Part B drugs by spending kept as a tier")
    args = ap.parse_args()
    src = os.path.join(args.cache, "sources")

    stats = defaultdict(lambda: {"meps_rx": 0.0, "partd_claims": 0.0, "medicaid_claims": 0.0, "partb_spend": 0.0,
                                 "examples": {}, "generic_of": {}, "why": set(), "kind": None})

    def note(word, kind, field, value, example, generic_of=None, why=None):
        s = stats[(word, kind)]
        s["kind"] = kind
        if field:
            s[field] += value
        if example:
            s["examples"][example] = s["examples"].get(example, 0) + value
        if generic_of:
            for g in generic_of:
                s["generic_of"][g] = s["generic_of"].get(g, 0) + value
        if why:
            s["why"].add(why)

    # ClinCalc Top 300 (MEPS prescriptions).
    clincalc_words = set()
    for rank, name, rx in load_clincalc(os.path.join(src, "clincalc_top300_2024.html")):
        if is_supply(name) or is_vaccine(name):
            continue
        words, salts = ingredient_words(name)
        for w in words:
            note(w, "generic", "meps_rx", rx, name, why="clincalc-top300")
            clincalc_words.add(w)
        for w in salts:
            note(w, "salt", "meps_rx", rx, name)

    # Part D and Medicaid claims.
    for fname, field in (("cms_partd_2024.csv", "partd_claims"), ("cms_medicaid_2024.csv", "medicaid_claims")):
        for r in load_cms(os.path.join(src, fname), "Tot_Clms_2024"):
            if not r["claims"] or is_supply(r["generic"]) or is_supply(r["brand"]):
                continue
            vaccine = is_vaccine(r["generic"])
            words, salts = ([], []) if vaccine else ingredient_words(r["generic"])
            for w in words:
                note(w, "generic", field, r["claims"], r["generic"])
            for w in salts:
                note(w, "salt", field, r["claims"], r["generic"])
            bws, dws = brand_words(r["brand"], words)
            ings = [w for w in words if w not in PLAIN_SALTS] or [r["generic"].lower()]
            for w in bws:
                note(w, "brand", field, r["claims"], r["brand"], ings)
            for w in dws:
                note(w, "device", field, r["claims"], r["brand"], ings)

    # Part B: the top drugs by spending, a tier of their own.
    partb = [r for r in load_cms(os.path.join(src, "cms_partb_2024.csv"), "Tot_Clms_2024", "Tot_Spndng_2024")
             if r["generic"] and not is_supply(r["brand"]) and not is_supply(r["generic"])]
    partb.sort(key=lambda r: -r["spend"])
    kept = 0
    for r in partb:
        vaccine = is_vaccine(r["generic"])
        words, salts = ([], []) if vaccine else ingredient_words(r["generic"])
        bws, dws = brand_words(r["brand"], words)
        if not words and not bws:
            continue
        for w in words:
            note(w, "generic", "partb_spend", r["spend"] / 1e6, r["generic"], why="partb-top")
        for w in bws:
            note(w, "brand", "partb_spend", r["spend"] / 1e6, r["brand"],
                 [x for x in words if x not in PLAIN_SALTS] or [r["generic"].lower()], why="partb-top")
        kept += 1
        if kept >= args.partb:
            break

    # The CMS files cut long generic names at 30 characters ("Fluticasone/Umeclidin/Vilanter",
    # "Hydrochlorothiazid"): fold a cut word into the one full word it begins (the
    # most-prescribed one when several do), and drop leftovers of three letters or fewer.
    gen = [k for k in stats if k[1] in ("generic", "salt")]
    full = sorted({w for w, _ in gen}, key=len, reverse=True)
    for w, kind in sorted(gen):
        if (w, kind) not in stats:
            continue
        longer = [v for v in full if len(v) > len(w) and v.startswith(w.rstrip("."))
                  and (v, kind) in stats and v != w]
        target = None
        if len(w) >= 4 and longer and not stats[(w, kind)]["why"] & {"clincalc-top300"}:
            # A cut word never appears in ClinCalc (which spells names in full).
            target = max(longer, key=lambda v: (stats[(v, kind)]["partd_claims"] + stats[(v, kind)]["medicaid_claims"]
                                                + stats[(v, kind)]["meps_rx"], v))
        if target:
            a, b = stats[(target, kind)], stats.pop((w, kind))
            for f in ("meps_rx", "partd_claims", "medicaid_claims", "partb_spend"):
                a[f] += b[f]
            for e, v in b["examples"].items():
                a["examples"][e] = a["examples"].get(e, 0) + v
            a["why"] |= b["why"]
        elif len(w.strip(".-")) <= 3 and w not in SHORT_OK:
            stats.pop((w, kind))
    for k in [k for k in stats if k[1] in ("brand", "device")]:
        gof = stats[k]["generic_of"]
        for g in list(gof):
            longer = [v for v in full if len(v) > len(g) and v.startswith(g) and (v, "generic") in stats]
            if (g, "generic") not in stats and longer:
                tgt = max(longer, key=lambda v: (stats[(v, "generic")]["partd_claims"], v))
                gof[tgt] = gof.get(tgt, 0) + gof.pop(g)

    curated = defaultdict(set)   # (word, kind) -> groups
    for group, spec in CURATED.items():
        for kind in ("generic", "brand"):
            for w in spec.get(kind, []):
                # A curated brand of several words ("Plan B", "Night Nurse") is one candidate:
                # its words alone are ordinary.
                for part in [w]:
                    key = (part.lower(), kind)
                    note(key[0], kind, None, 0, w, why=group)
                    curated[key].add(group)

    def score(s):
        return s["meps_rx"] + s["partd_claims"] + s["medicaid_claims"]

    chosen = []
    for kind, limit in (("generic", args.generics), ("brand", args.brands), ("salt", 60), ("device", 25)):
        pool = sorted(((k, s) for k, s in stats.items() if k[1] == kind), key=lambda kv: (-score(kv[1]), kv[0][0]))
        top = pool[:limit]
        names = {k for k, _ in top}
        for k, s in pool[limit:]:
            if s["why"] & {"clincalc-top300", "partb-top"} or k in curated:
                top.append((k, s))
                names.add(k)
        for k, s in top:
            why = sorted(s["why"]) + ([f"top-{limit}-{kind}"] if (k, s) in pool[:limit] else [])
            chosen.append((k, s, why))

    # A word that is both a generic and a brand word (rare: "bayer" isn't, "zinc" isn't a brand) keeps
    # both rows; the research decides once per spelling.
    chosen.sort(key=lambda x: (-score(x[1]), -x[1]["partb_spend"], x[0][0], x[0][1]))
    out_path = os.path.join(DRUGS, "candidates.tsv")
    with open(out_path, "w", encoding="utf-8") as f:
        f.write("rank\tword\tkind\tscore\tmeps_rx\tpartd_claims\tmedicaid_claims\tpartb_spend_musd\texamples\tgeneric_of\twhy\n")
        for i, ((word, kind), s, why) in enumerate(chosen, 1):
            ex = sorted(s["examples"].items(), key=lambda kv: (-kv[1], kv[0]))[:3]
            go = sorted(s["generic_of"].items(), key=lambda kv: (-kv[1], kv[0]))[:3]
            f.write("\t".join([str(i), word, kind, str(int(score(s))), str(int(s["meps_rx"])), str(int(s["partd_claims"])),
                               str(int(s["medicaid_claims"])), f"{s['partb_spend']:.1f}",
                               " | ".join(e for e, _ in ex), " | ".join(g for g, _ in go), ",".join(why)]) + "\n")
    counts = defaultdict(int)
    for (word, kind), _, _ in chosen:
        counts[kind] += 1
    print(f"wrote {out_path}: {len(chosen)} rows {dict(counts)}")


if __name__ == "__main__":
    main()
