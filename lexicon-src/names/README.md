# People's names: candidate manifest and baseline audit (FIN-906)

This folder holds phases 1 and 2 of the names pack: a ranked list of about 100,000 given names
(`manifest.tsv`), and how Aloud reads each of them today, sorted into triage buckets
(`ledger.tsv`, `coverage.json`, `spotcheck.tsv`). No pronunciations have been researched or
written yet; nothing here changes what the app says.

**This is a source-based ranking, not a world census.** It counts names where open statistics
exist (eight national registers covering about 571 million people, mostly in English-speaking
countries and western Europe) and estimates the rest of the world from the given names of
notable people in Wikidata. Treat `est_people` as an order of magnitude, good for deciding what
to research first, not as a count of anyone.

## Sources

| id | Source | Edition and coverage | Licence |
|---|---|---|---|
| `us_ssa` | US Social Security Administration, *Popular Baby Names*, national data ([names.zip](https://www.ssa.gov/oact/babynames/names.zip)) | Births 1880 to 2024, names given 5+ times per sex and year. Used: 1925 to 2024. | Public domain (US federal government work) |
| `gb_ew_ons` | Office for National Statistics, [*Baby names in England and Wales: from 1996*](https://www.ons.gov.uk/peoplepopulationandcommunity/birthsdeathsandmarriages/livebirths/datasets/babynamesinenglandandwalesfrom1996) (`babynames1996to2025.xlsx`) | Births 1996 to 2025 (the file's year columns), exact spellings, counts of 3+ | Open Government Licence v3.0 |
| `gb_sct_nrs` | National Records of Scotland, [*Babies' first names*, full lists 1974 to 2024](https://www.nrscotland.gov.uk/publications/babies-first-names-2024/) | Births 1974 to 2024, counts of 3+; NRS removes accents | Open Government Licence v3.0 |
| `ie_cso` | Central Statistics Office Ireland, tables [VSA50](https://data.cso.ie/table/VSA50) (boys) and [VSA60](https://data.cso.ie/table/VSA60) (girls) | Births 1964 to 2025, names with 3+ registrations | CC BY 4.0 |
| `ca_statcan` | Statistics Canada, [table 17-10-0147-01](https://www150.statcan.gc.ca/t1/tbl1/en/tv.action?pid=1710014701), *First names at birth by sex at birth* | Births 1991 to 2025, Canada as a whole; written in capitals | Statistics Canada Open Licence |
| `fr_insee` | INSEE, [*Fichier des prénoms*](https://www.insee.fr/fr/statistiques/8595130), édition 2025 (`prenoms-2025-nat_csv.zip`) | Births 1900 to 2025. Used: 1925 to 2025. Rare names grouped as `_PRENOMS_RARES` (dropped); capitals with accents | Licence Ouverte / Open Licence 2.0 (Etalab) |
| `es_ine` | INE, *Nombres y apellidos*: [`nombres_por_edad_media.xlsx`](https://www.ine.es/daco/daco42/nombyapel/nombres_por_edad_media.xlsx) | Residents of Spain on 1 January 2025, names held by 20+ people; capitals without accents; compound names kept whole ("MARIA CARMEN") | CC BY 4.0 ([INE aviso legal](https://ine.es/dyngs/AYU/es/index.htm?cid=125)); "Fuente: INE, elaboración propia" |
| `no_ssb` | Statistics Norway, [table 10501](https://www.ssb.no/en/statbank/table/10501) | Residents of Norway at the end of 2025, names held by 200+ people | CC BY 4.0 |
| `wikidata` | Wikidata through the [QLever](https://qlever.dev/wikidata) endpoint; queries in `tools/queries/` | Every given-name item (125,460 with a usable label) and, for each, how many people (instance of human) carry it (P735), by country of citizenship (P27); country populations (P1082). Index: dump of 2026-08-10, updated live | CC0 |

Population figures for weighting come from Wikidata (P1082, CC0) for every area, including the
statistics offices' countries (England and Wales together, Scotland, ...).

**SSA download.** `www.ssa.gov` answered 403 to every request from our network on 2026-10-08.
`tools/fetch.py` tries the official `names.zip` first and otherwise takes the same `yobYYYY.txt`
files from a public mirror ([dcadata/name-finder](https://github.com/dcadata/name-finder) at commit
`7991ac3`, Git LFS), checking each file against the SHA-256 in its LFS pointer. The files have
the SSA's layout and its well-known first line (1880: Mary, F, 7,065), but they are a third
party's copy until checked against the official zip. Re-run the fetch
from a network that can reach ssa.gov to swap in the official zip; the parser reads either.

**Excluded on purpose.** The `names-dataset` package (philipperemy/name-dataset) and anything
derived from it: it was built from the 2021 leak of 533 million Facebook users' personal data,
which we won't use however it's licensed. Also not used: Forebears, Behind the Name and similar
sites (no open licence; Behind the Name's pronunciations may be useful later as research
references, not as data); the Brazil IBGE names API (it exposes only per-name lookups and top
lists, and the bulk copy on brasil.io is CC BY-SA); the Netherlands' Meertens Voornamenbank (no
open licence).

**Not yet used, worth adding later** (all open): Northern Ireland (NISRA), Australian states and
New Zealand (DIA) baby names, Belgium (Statbel), Finland (DVV), Denmark (DST), Québec (Retraite
Québec). Germany, India, China, Nigeria and most of the world publish no open name counts.

**Used only by the audit**, never shipped: the misaki gold dictionary already in `Vendor/g2p`
(Apache-2.0); macOS's `/usr/share/dict/web2` (Webster's Second International, 1934, public
domain); wordfreq 3.1.1's English frequencies (Robyn Speer, CC BY-SA 4.0), read from a local copy
only to grade collision words as common, uncommon or rare. No frequency figures are written out.

## Method (`tools/rank.py`)

1. **Read each register.** Birth registers count births from 1925 on (roughly the people alive
   today); INE and SSB already count living residents. Sexes are added together.
2. **Normalise technical duplicates only.** A name's key is its NFC form, case-folded, with
   spacing, apostrophes (’ ‘ ʼ → ') and hyphens (‐ ‑ → -) unified. Accents, script and spelling
   stay distinct: Zoe and Zoë, Mohammed, Muhammad, Mohamed and Muḥammad, Мария and Maria are
   separate candidates. Register placeholders (Baby, Infant, Unknown, Unnamed, Boy, Girl,
   `_PRENOMS_RARES`), single initials, anything with digits, and names of more than three words
   are dropped.
3. **Per-head share in each register**, times the population it stands for:
   `people_s = population_s × count_s(name) / total_s`. (England and Wales: the two countries'
   populations; the SSA: the US; and so on.)
4. **The rest of the world from Wikidata.** People's given names (P735) are counted by country of
   citizenship (P27). Citizens of the eight register countries (and the UK) are left out, so
   nobody counts twice. Each other current sovereign state with at least 2,000 name-bearer pairs
   (86 states) is its own sample, weighted by its population; the 104 smaller states are pooled
   into one sample weighted by their combined population (1.24 billion). A name counts in a
   sample only with 2+ bearers there. People with no citizenship recorded, or only a former
   state's (5.0 million name-bearer pairs), supply spellings but no weight: they stand for no
   population alive today.
5. **`est_people`** is the sum. Names are ranked by it (ties broken by the key, so the output is
   byte-identical for the same inputs) and the top 100,000 are kept, out of 273,744 scored. The
   last few thousand rows are rare names with equal scores (about 75 people-equivalents), so
   where exactly the cut falls among them is arbitrary.
6. **Spelling shown**: Wikidata's label when there is one; else a mixed-case spelling from a
   register that keeps capitals inside names (McKenzie); else the SSA's (which writes Mckenzie);
   else the capitals written as a name (JEAN-PIERRE → Jean-Pierre).

**Usage hint** (`usage`): "english" when the spelling is mostly a name of English-speaking
countries: more common there per head than elsewhere (`anglo_affinity` ≥ 0.6), and no
non-English register records it more than twice as often per head (Jesus: Spain). This is about
usage, not etymology. Liam and Sophia are "english" because the people who carry those
spellings mostly live in English and say them the English way, which is the reading the pack
wants ("anglicised the way English speakers who know them say it", `../PACKS-GUIDE.md`). Open
data on etymology is too sparse to use: Wikidata gives a language for only some names, and often
lists many.

### Coverage limits, honestly
- The registers are 8 countries, 6 of them in western Europe or North America. Everyone else
  comes from Wikidata's notable people, who skew male, historical, European and towards sport
  and politics. The world's most common name spellings still surface (Muḥammad, José, Ali,
  Wei, Александр), but the order inside the Wikidata-only part is rough.
- Wikidata often links people to their name in its own script (Александр, 偉, علي): those are
  kept as candidates (2,610 non-Latin names), though English text usually spells them in
  Latin letters, which may rank lower or be missing.
- Chinese, Vietnamese and many African and South Asian people in Wikidata have no given-name
  statement, so those names are under-counted.
- Spellings the registers flatten (INE and NRS drop accents; SSA drops spaces, hyphens and
  apostrophes: Maryjane) count under the flattened spelling.
- The SSA lists a name only with 5+ births in a year, and the other registers only with 3+ or
  20+ or 200+: very rare names are under-counted everywhere.

## Files

**`manifest.tsv`** (UTF-8, tab-separated, one row per candidate, ranked):
`rank`, `name`, `est_people` (step 5), `anglo_share` (share of `est_people` in the US, UK,
Ireland, Canada, Australia and New Zealand), `anglo_affinity` (per-head rate in those countries
÷ (that + the rate elsewhere): 0.5 = equally common, 1 = only there), `usage` (above),
`sources` (register ids, plus `wikidata` when Wikidata has the spelling), `countries` (the
registers where it occurs, then up to three Wikidata countries with the most bearers),
`origin` (Wikidata's language of the name, or the language tag of its native label), `script`
(Wikidata's writing system), `native` (Wikidata's native-script label when it differs),
`evidence` (raw counts per register, `US=` births since 1925 and so on, and Wikidata bearers by
country, `wd=IR:19,...`; `pool` is the pooled small states).

**`ledger.tsv`**: one row per candidate with today's readings and the triage:
`rank`, `name`; `us`, `gb` (the name on its own); `us_sentence`, `gb_sentence` (the name's
phonemes inside "I met NAME yesterday."); `sentence_differs`; `source` and `source_sentence`
(what read it: `lexicon`, `gold`, `cmudict`, `guesser`, `letters`, `none`, joined with `+` for
names of several words); `lexicon` (which list covers it: `irish-names`, `tech`); `collision`
(`word` when the gold dictionary and Webster's both have the lower-case spelling as an ordinary
word: Rose, Will, Grace; `gold-only` when only the gold dictionary does: john); `word_freq`
(common / uncommon / rare, for collisions; wordfreq lower-cases, so a popular name inflates its
word's figure); `script`; `usage`; `origin`; `multiword` (spaces or hyphens); `bucket`;
`disposition` (`covered` or `unaudited`).

**`coverage.json`**: totals by bucket (all, top 1,000, top 10,000), by source, collision,
script, first country and origin, and the spot-check results per bucket.

**`spotcheck.tsv`**: 30 names per bucket drawn with a fixed seed (906), each with a verdict
(`right`, `wrong`, `unsure`) and a note.

**`sources.lock.json`**: every downloaded file's URL, size and SHA-256, and the numbers above.

## Triage buckets (`tools/audit.py`)
Each name gets the first that applies:
1. `covered-by-lexicon`: a custom list already reads it (`irish-names`, or a person in the tech
   list). Disposition `covered`.
2. `unsupported-script`: not Latin script, or the voice reads nothing for it today.
3. `collision-word`: also an ordinary English word (`collision` = `word`). A fix must never change
   the word in everyday prose: case-sensitive and probably `pack_only`.
4. `guesser-reading`: some part read by the mini-bart guesser. Needs research.
5. `dictionary-reading-needs-check`: read from the gold dictionary or CMUdict, `usage` other: the
   dictionary may have anglicised it in a way its bearers don't (Jean as "jeen", Jesus as
   "JEE-zus").
6. `dictionary-reading-likely-right`: read from a dictionary, `usage` english.

## Rebuild
From the repository root:
```sh
swift build -c release
python3 -I lexicon-src/names/tools/fetch.py --cache ~/Library/Caches/aloud-names/run-$(date +%Y%m%d)
python3 -I lexicon-src/names/tools/rank.py --cache ~/Library/Caches/aloud-names/run-YYYYMMDD
python3 -I lexicon-src/names/tools/audit.py --wordfreq PATH/TO/wordfreq/data/large_en.msgpack.gz
```
Downloads are untrusted data: keep the cache outside the repository and run python with `-I`.
`rank.py` is deterministic: the same cache gives a byte-identical manifest, so compare the
`sources.lock.json` checksums first. A new fetch gives slightly different Wikidata answers (the
endpoint follows Wikidata live) and new register editions add years. `audit.py --sample 30
--seed 906` draws the spot-check sample again; verdicts already in `spotcheck.tsv` for names
still drawn are kept. Tools are plain python3 (3.9+), standard library only; `fetch.py` needs
network access, the others don't.
