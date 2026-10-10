# Drug names: research guide (FIN-893)

Aloud reads text aloud with an English voice (Kokoro-82M v1.0, misaki phonemes). The drugs pack
tells it how to say the most-prescribed generic and brand drug names the way clinicians and
pharmacists say them. Today "atorvastatin" comes out AY-ter-VAS-tay-tin (a guess); it should be
uh-TOR-vuh-stat-in. Your job, per batch: one entry for every row of the input batch, with the
intended reading, the evidence for it and a disposition, checked by `tools/check_drugs.py`.

Notation is the same as the rest of Aloud's lexicons: `../GUIDE.md` (phoneme rules),
`../PACKS-GUIDE.md` (packs), `../decisions/EN_PHONES.md` (the misaki symbols) and the names
pack's `../names/NAMES-GUIDE.md` (its "Converting IPA to misaki" section applies here too).

## Where you work
`lexicon-src/drugs/` in the repository (paths below are relative to it):
- `batches/in/dNNNN.json`: your input (50 rows). `batches/out/dNNNN.json`: your result.
- `tools/check_drugs.py`: the checker. Run it from the repository root:
  `python3 -I lexicon-src/drugs/tools/check_drugs.py lexicon-src/drugs/batches/out/dNNNN.json --table`
- Write only your own `batches/out/dNNNN.json` (the checker adds `dNNNN.checked.json`). Never run
  git, never edit other files, never rebuild the app.

## The input rows
- `word`, `kind`: the candidate, lower case (`generic`: a word of an active ingredient's name;
  `salt`: the salt or ester half of a generic name on a label, "besylate"; `brand`; `device`: an
  inhaler or pen name that is part of a brand, "Ellipta"). `display`: the spelling looked up.
- `today_us`, `today_gb`, `today_source`: how the app reads it now, recorded before the pack
  (`gold`/`cmudict` are dictionaries, `guesser` a small neural guess, `lexicon` a custom list).
- `examples`, `generic_of`: the products it comes from; `score`: 2024 US prescription volume.
- `zipf` (how common the lower-case spelling is in English text, 3.5+ is common),
  `dictionary_word` (in the system word list), `given_name` (a ranked given name),
  `other_lists` (another shipped list already has this spelling, with its reading).
- `evidence`: what the harvest found:
  - `medlineplus`: MedlinePlus Drug Information (NLM; ASHP's AHFS patient monographs).
    `aligned` is the respelling for this word, e.g. "a tore' va sta tin"; `pronounced` is the
    monograph's whole line (combination products list one group per ingredient, in title order).
    For a brand, the generic monograph it points to.
  - `dailymed`: respellings printed in FDA-approved labels (the maker's Medication Guide or
    Patient Information), e.g. `{"term": "ELIQUIS", "respelling": "ELL eh kwiss"}`. A term other
    than the row's word is a pronunciation of another word on that label (often the generic).
  - `wiktionary`: Wiktionary's IPA (`a=GA` US, `a=RP`/`UK` British).

## The intended reading
**How US clinicians and pharmacists say the name**, written for the US voice in `us`; `gb` is
the same name as British clinicians say it (British vowels, and British stress where a source
gives it). These are the readings patients hear at the pharmacy counter, so they are right for
everyone; there is no separate lay reading.
- **Brands:** the maker's own pronunciation (the label respelling, the maker's website or TV
  advertising as written on a page) is the reading. Brand names are coined; spelling rules don't
  settle them.
- **Generics:** the USAN/ASHP reading MedlinePlus gives, unless dictionaries agree on something
  else (put the other in `alternatives`). Where sources disagree on which of two stressed
  syllables is the main one (atorvastatin: MedlinePlus "a tore' va sta tin", Merriam-Webster
  ə-ˌtȯr-və-ˈsta-tᵊn), keep both stresses (`ˈ` and `ˌ`) and follow MedlinePlus for which is
  primary in `us`, the British source for `gb`; note it.
- **Stem families read alike** (-statin stat-in, -pril pril, -sartan SAR-tan, -olol oh-lol,
  -azole uh-zole, -prazole PRAY-zole, -mab mab, -gliflozin gli-FLOH-zin, -gliptin GLIP-tin,
  -glutide GLOO-tide, -tidine tih-deen, -dipine dih-peen, -cycline SY-kleen, -floxacin FLOX-uh-sin,
  -vir veer). Check a word against its family; a family pattern alone is `low` confidence.
- **Same reading, different unstressed vowels, is still right.** Today's reading is already the
  intended one when the stressed syllables, their vowels and the consonants match and only
  unstressed vowels differ in reduction (ə, ɪ). Don't churn readings for that.

## Converting a respelling to misaki
MedlinePlus (ASHP) style: syllables separated by spaces, an apostrophe after the stressed one.
Label style: hyphens or spaces, the stressed syllable in capitals.

| Respelling | misaki | e.g. |
|---|---|---|
| a (open, unstressed), uh, e/i/u in an unstressed open syllable | `ə` | a tore' → `ətˈɔɹ` |
| a, ah (stressed closed: "stat", "pak") | `æ` (GB `a`) | sta tin → `stˌætᵊn` |
| ah, o (as in "lot": "rox", "pom") | `ɑ` (GB `ɒ`) | rox' een → `ɹˈɑksin` |
| ay, ai | `A` | pray zole → `pɹˈAzOl` |
| ee, e (open, stressed) | `i` (GB `iː`) | lee voe → `lˌivO` |
| e, eh (closed or stressed: "met", "pen", ELL); unstressed "eh" is `ə` | `ɛ` | met for' min → `mɛtfˈɔɹmɪn` |
| i (closed: "tin", "pril", "sil") | `ɪ` | |
| eye, ye, ie, y ("lye", "thye", "mye") | `I` | lyse in' oh pril → `lIsˈɪnəpɹɪl` |
| oh, oe, o (open: "voe", "toe", "loe") | `O` (GB `Q`) | |
| oo, u (open: "soo") | `u` (GB `uː`) | |
| yoo, yu, u ("byoo") | `ju` (GB `juː`) | |
| aw, au, or ("tore", "for") | `ɔ`; "or" = `ɔɹ` (GB `ɔː`) | |
| ow | `W`; oy | `Y` |
| er, ur (unstressed) | `əɹ` (GB `ə`); stressed `ɜɹ` (GB `ɜː`) | |
| zh, sh, ch, j, th (thin), dh (this), ng | `ʒ ʃ ʧ ʤ θ ð ŋ` | |
| x | `ks`; kw = `kw` | |
| final -tin, -ton, -den after a stressed vowel | `tᵊn`, `dᵊn` (as gold's "statin" stˈætᵊn) | |

- **Unstressed syllables reduce** as clinicians say them: unstressed "a", "e", "u" in an open
  syllable → `ə`; "i" → `ɪ` (or `ə`); keep "oh", "ee", "eye", "oo", "ay" full (`O i I u A`).
- **Secondary stress:** words of four or more syllables usually carry one `ˌ` on a full vowel
  two syllables away from the main stress (`lˌivOθIɹˈɑksin`). A final syllable with a full vowel
  after an unstressed one (-ine "een", -ide "ide", -ole "ole") usually takes `ˌ` in American
  speech (`æmlˈOdəpˌin`, `ɡlˈɪpəzˌId`).
- Stress marks go right before the vowel (misaki), not before the syllable as in IPA or the
  respelling. Every word of two or more syllables has exactly one `ˈ`.
- Write `gb` whenever `us` has `æ O ᵻ T` or an `ɹ` after a vowel (the checker insists), and
  whenever British vowels differ (`iː uː ɑː ɔː ɜː`, LOT `ɒ`).

Worked examples:
- **atorvastatin** (generic; today `ˌAtəɹvˈæstAtɪn`, guesser). MedlinePlus "a tore' va sta tin";
  Wiktionary US /əˈtɔːɹvəˌstætɪn/ and /əˌtɔːɹvəˈstætɪn/, UK /əˌtɔːvəˈstætɪn/. US `ətˈɔɹvəstˌætᵊn`,
  GB `ətˌɔːvəstˈatᵊn`, "uh-TOR-vuh-stat-in". High.
- **metformin** (today `mˈɛtfˌɔɹmɪn`, guesser: MET-for-min). MedlinePlus "met for' min";
  Wiktionary GA /mɛtˈfɔɹ.mɪn/. US `mɛtfˈɔɹmɪn`, GB `mɛtfˈɔːmɪn`. High.
- **levothyroxine** (today `lˌɛvəθˈIɹɑksin`: LEV-uh-THY-rox-een). MedlinePlus "lee voe thye
  rox' een"; Wiktionary GA /ˌli.voʊ.θaɪˈɹɑkˌsin/. US `lˌivOθIɹˈɑksin`, GB `lˌiːvQθIɹˈɒksiːn`.
  High.
- **Eliquis** (brand; today from the guesser). Label "ELIQUIS (ELL eh kwiss)": US and GB
  `ˈɛləkwɪs`, "ELL-uh-kwiss". High.
- **Jardiance** (brand). Label "(jar DEE ans)": US `ʤɑɹdˈiəns`, GB `ʤɑːdˈiːəns`. High.

## Evidence, in order of preference
1. **The maker's own pronunciation for a brand**: the label respelling in `evidence.dailymed`,
   the maker's website ("pronounced ..."), the prescribing information.
2. **MedlinePlus** (ASHP) for a generic; **Merriam-Webster** (Medical) and other dictionaries;
   **Wiktionary** IPA; USP/USAN pronunciation guides.
3. Pharmacy and nursing references that print a respelling (drug guides, pharmacology
   pronunciation lists, Drugs.com's "Pronunciation" line), a news story or ad transcript that
   says how the maker pronounces a brand.
4. The stem family and the spelling: `low` at most, and say so.

You may search the web (`WebSearch`, `WebFetch`) for rows with no harvested evidence, especially
brands. Record facts only (a respelling, an IPA string, which page), never copied paragraphs.
Never use a dictation round trip as evidence.

- `evidence`: `[{"source": "MedlinePlus (ASHP)", "says": "a tore' va sta tin", "url": "..."}]`,
  one item per source you relied on.
- `confidence`: `high` when an authoritative source (1 or 2) gives this exact word and nothing
  contradicts it; `medium` for one secondary source (3), or an authoritative source you had to
  interpret (a stress the respelling leaves open); `low` when it rests on the family and the
  spelling (say why in `notes`). When you'd be guessing, the disposition is `unresolved`.

## Dispositions
| disposition | when | needs |
|---|---|---|
| `corrected` | the intended reading differs from today's | `spelling`, `match`, `us` (+ `gb`), `respelling`, `evidence`, `confidence` |
| `already-correct` | today's reading is the intended one | `evidence`, `confidence`; leave `us`/`gb` empty or equal to today's |
| `covered` | another shipped list (`other_lists`) already reads it the intended way | `notes` |
| `ordinary-word` | the spelling is an ordinary English word, name or phrase in everyday text (Refresh, Heather, Armour, Tears, Iron), so a general entry would change ordinary prose | `notes`; the drug reading in `us` if it differs from the word's |
| `not-a-drug` | junk from the ranking: a descriptor, a fragment, a cut-off word with no drug of its own | `notes` |
| `unresolved` | evidence thin or conflicting | `notes` (what you found); `us` only if you have a candidate |

**Never shadow ordinary words.** An entry changes every occurrence of its spelling. If the
spelling is a word or a given name a reader meets in other contexts (look at `zipf`,
`dictionary_word`, `given_name`), and the drug reading differs from the everyday one, use
`ordinary-word` and don't ship it. If the drug reading is the same as the everyday one, nothing
needs shipping either: `already-correct` or `ordinary-word`. Only when the word's other meaning
is rare or technical and the drug is what readers meet may you correct it; then say why in
`notes`, and use `"match": "case-sensitive"` with the brand's capitalisation when the lower-case
word is the everyday one.

## Spelling and matching
- `spelling`: how the entry should match: generics lower case (`atorvastatin`); brands as the
  maker writes them (`Eliquis`, `NovoLog`, `KwikPen`, `Pepto-Bismol`). A candidate cut short by
  the claims file (`umeclidin`) gets its full spelling (`umeclidinium`) and a note.
- `match`: `case-insensitive` for nearly everything (it also catches ELIQUIS on a label);
  `case-sensitive` only to protect a lower-case ordinary word (above).
- A candidate that is a phrase ("Plan B", "Night Nurse") gets one entry for the whole phrase,
  usually `already-correct` because its words read normally.

## Steps for a batch
1. Read `batches/in/dNNNN.json`.
2. For each row: decide the disposition and, for drug names, the reading, from the evidence;
   search where it's missing or contradictory.
3. Write `batches/out/dNNNN.json`: a JSON array, one entry per row, each with `rank`, `word`
   and `kind` copied from the row:
   ```json
   {"rank": 1, "word": "atorvastatin", "kind": "generic", "spelling": "atorvastatin",
    "match": "case-insensitive", "disposition": "corrected",
    "us": "ətˈɔɹvəstˌætᵊn", "gb": "ətˌɔːvəstˈatᵊn", "respelling": "uh-TOR-vuh-stat-in",
    "evidence": [{"source": "MedlinePlus (ASHP)", "says": "a tore' va sta tin",
                  "url": "https://medlineplus.gov/druginfo/meds/a600045.html"},
                 {"source": "Wiktionary", "says": "US /əˈtɔːɹvəˌstætɪn/, /əˌtɔːɹvəˈstætɪn/; UK /əˌtɔːvəˈstætɪn/",
                  "url": "https://en.wiktionary.org/wiki/atorvastatin"}],
    "confidence": "high", "alternatives": [], "notes": "GB keeps the UK main stress on 'stat'."}
   ```
4. Run the checker; fix every ERROR and answer every WARN (fix the entry, or explain in `notes`).
5. Finish with the checker exiting 0. Report the counts by disposition and confidence, the
   unresolved rows and anything a reviewer should look at.
