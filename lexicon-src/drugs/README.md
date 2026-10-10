# Drug names pack (FIN-893)

`Lexicons/drugs.json` (pack id `drugs`) tells Aloud's voice how to say the most-prescribed generic
and brand drug names the way US clinicians and pharmacists say them, with British forms for the
British voices. Almost every entry is a word the general dictionary doesn't know, so the entries
are general ones (FIN-890's first kind): they apply for everyone, whatever packs are switched on.
None is `pack_only`. The pack is pronunciation only (`"dictation": "never"`): dictation rewrites
need spoken variants checked against the dictation model, a follow-up.

This folder keeps everything behind the pack, so the research survives (an earlier field-pack
research folder was lost with a scratch directory):

| file | what it is |
|---|---|
| `candidates.tsv` | the ranked candidate words (below) |
| `sources.lock.json` | the ranking sources' URLs and checksums |
| `baseline.tsv` | how the app read every candidate before the pack, and what read it; collision facts |
| `evidence.json` | the pronunciation evidence the harvest found for each candidate, with URLs |
| `batches/in/`, `batches/out/` | the research batches: inputs, researched entries, checker output |
| `drugs.source.json` | every researched row: disposition, confidence, evidence, before and after, why held back |
| `ledger.tsv`, `coverage.json` | one line per candidate with its outcome; the counts |
| `decisions.json` | hand decisions that override an assembly guard (ship or hold), with reasons |
| `DRUGS-GUIDE.md` | the research brief |
| `tools/` | the pipeline (plain python3, standard library only) |

## Candidates
`tools/rank.py` ranks *words*, because the lexicon matches words: "insulin glargine" needs only
"glargine", and "Trelegy Ellipta" needs "Trelegy" and "Ellipta". The score is 2024 US
prescription volume, adding three sources for every product the word appears in:

| id | source | licence |
|---|---|---|
| `clincalc_top300_2024` | [ClinCalc DrugStats, The Top 300 of 2024](https://clincalc.com/DrugStats/Top300Drugs.aspx) (from AHRQ's Medical Expenditure Panel Survey; US outpatient prescriptions, all ages and payers) | cited for ranking only |
| `cms_partd_2024` | [CMS Medicare Part D Spending by Drug](https://data.cms.gov/summary-statistics-on-use-and-payments/medicare-medicaid-spending-by-drug/medicare-part-d-spending-by-drug), 2024 claims by brand and generic name | US government work |
| `cms_medicaid_2024` | [CMS Medicaid Spending by Drug](https://data.cms.gov/summary-statistics-on-use-and-payments/medicare-medicaid-spending-by-drug/medicaid-spending-by-drug), 2024 claims (includes over-the-counter drugs) | US government work |
| `cms_partb_2024` | [CMS Medicare Part B Spending by Drug](https://data.cms.gov/summary-statistics-on-use-and-payments/medicare-medicaid-spending-by-drug/medicare-part-b-spending-by-drug), 2024: drugs given in clinics; its top 60 by spending are a tier of their own | US government work |

On top of the top 500 generic words and top 500 brand words by score: every ingredient of the
ClinCalc Top 300, the Part B tier, the drugs the FIN-888 plan names, and the best-known US and UK
over-the-counter brands (the government files undercount drugs bought without a prescription).
Salts and esters ("besylate", "succinate") and the inhaler and pen names that are part of brands
("Ellipta", "KwikPen") are candidates of their own. Vaccines' generic names, medical supplies and
skin substitutes are left out. The CMS files cut names at 30 characters; cut words are folded into
the word they begin ("Umeclidin" → umeclidinium).

## Evidence
`tools/harvest.py` reads, politely and through a cache outside the repository
(`~/Library/Caches/aloud-drugs/http`):
- **MedlinePlus Drug Information** (US National Library of Medicine; the monographs are ASHP's
  AHFS Patient Medication Information): the generic's respelling, "pronounced as (a tore' va sta
  tin)", an apostrophe after the syllable with the main stress and a double one after a
  secondary stress; and which generic each brand is.
- **DailyMed** (FDA-approved labels, NLM): the maker's own respelling of a brand in its Medication
  Guide or Patient Information, "ELIQUIS (ELL eh kwiss)".
- **Wiktionary**: IPA where the word has an English entry.
Research batches added Merriam-Webster, the makers' websites and other references where these
were missing. `evidence.json` keeps the short facts only (respellings, IPA, URLs), never page text.

## Research
All 1,272 candidates went through 27 batches of 50 (`DRUGS-GUIDE.md`): one research pass and an
independent second-review pass per batch, each finishing with `tools/check_drugs.py` clean. The
checker compares every reading with today's and with the harvested respellings' syllable count and
main stress; a disagreement had to be fixed or explained in the entry's notes. Pack-wide rulings
(which stress is main when sources disagree, which unstressed differences count, the British "y"
after t, d and n, -sone with s) are in the guide, and `tools/families.py` lists the readings by stem
family (-statin, -mab, -sartan) so one that breaks ranks stands out.

## Results
| | generic | brand | salt | device | all |
|---|---:|---:|---:|---:|---:|
| corrected | 346 | 294 | 25 | 5 | 670 |
| already right | 200 | 279 | 31 | 11 | 521 |
| unresolved | 2 | 43 | 4 | 0 | 49 |
| ordinary word (never shipped) | 3 | 16 | 0 | 1 | 20 |
| not a drug name | 3 | 4 | 0 | 0 | 7 |
| covered by the tech list | 0 | 5 | 0 | 0 | 5 |
| **shipped** | 344 | 272 | 23 | 5 | **643** |

Shipped by confidence: 500 high, 124 medium, 20 low (each low one replaces a reading that is
clearly wrong today; `drugs.source.json` lists them). Held back: 26 corrections, 25 of them
low-confidence readings that only partly change today's, and Larin (also a given name;
`decisions.json`). The atorvastatin canary now reads uh-TOR-vuh-STAT-in.

Checks: `assemble.py` asks the app to read every shipped spelling, alone and in a sentence, US and
GB (0 problems); `check_packs.py` is clean; `Tests/g2p/regression.json` has the drug cases and
`Tests/g2p/drugs-negatives.json` the 56 ordinary sentences frozen before the pack. Loading the
pack adds about 1 ms at launch (13,555 entries in 26.9 ms against 25.7 ms without it).

`tools/listen.py` renders the before/after listening page from a sample fixed in
`listen-sample.json`.

Known limits: the harvest's label pattern missed respellings written in brackets, with primes,
accents or in lower case (the researchers found them in the cached labels by hand), and the 49
unresolved names have no written pronunciation the research could reach (several are store-brand
contraceptives with no maker respelling). Dictation rewrites (spoken variants checked against the
dictation model, and `evidence` for drug-field context) are a follow-up.

## Rebuild
```sh
swift build -c release
python3 -I lexicon-src/drugs/tools/fetch.py              # ranking sources (checksums in sources.lock.json)
python3 -I lexicon-src/drugs/tools/rank.py               # candidates.tsv
python3 -I lexicon-src/drugs/tools/harvest.py            # evidence.json (cached; the first run takes about an hour)
python3 -I lexicon-src/drugs/tools/make_batches.py       # baseline.tsv (kept) and batches/in
# research: batches/out/dNNNN.json per DRUGS-GUIDE.md, each passing tools/check_drugs.py
python3 -I lexicon-src/drugs/tools/assemble.py           # Lexicons/drugs.json, drugs.source.json, ledger, coverage; verifies in the app
python3 -I lexicon-src/tools/check_packs.py
```
`make_batches.py` keeps `baseline.tsv`'s readings (the readings before the pack); `--rebaseline`
records them again and refuses while `Lexicons/drugs.json` exists.
