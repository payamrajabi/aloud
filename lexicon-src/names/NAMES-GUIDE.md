# People's names: research guide (FIN-906, phase 3)

Aloud reads text aloud with an English voice (Kokoro-82M v1.0, misaki phonemes). The names pack
tells it how to say people's given names. Phases 1 and 2 (`README.md`) ranked 100,000 names and
recorded how the app reads each one today. This phase researches the reading each name should
have. Your job, per batch: one entry for every name in the input batch, with its intended
reading, the evidence for it and a disposition, checked by `check_names.py`.

Notation is the same as the rest of Aloud's lexicons: `../GUIDE.md` (phoneme rules),
`../PACKS-GUIDE.md` (packs) and `../decisions/EN_PHONES.md` (the misaki symbols). The short
version is under [Converting IPA to misaki](#converting-ipa-to-misaki).

## Where you work
`~/Library/Caches/aloud-names/research/`, a durable folder outside any git worktree:
- `in/n0001.json` …: the batches (150 names each), `queue.json`: the order.
- `out/`: your results, `out/<id>.json`, plus what the checker writes next to it.
- `tools/`: `check_names.py` (and the `common.py` and `vocab.json` it imports), this guide, and
  `example-batch.json` (five worked entries).

The checker asks a fixed build of the app how it reads each name today. Don't rebuild it.

## Steps for a batch
1. Read `in/<id>.json`. Each row has:
   - `rank`, `name`: the exact spelling. Never change it.
   - `bucket` and `task`: why the name is here and how much work it needs ([below](#by-task)).
   - `today_us`, `today_gb`, `today_source`: how the app reads it now, and what read it (`gold`
     and `cmudict` are dictionaries, `guesser` is a small neural guess, `lexicon` a custom list,
     `none` nothing). `today_us_in_sentence` appears when the reading changes inside a sentence.
   - Who carries the name: `usage` (`english` when the spelling is mostly an English-speaking
     countries' name, else `other`), `anglo_share` (share of the estimated bearers who live in
     English-speaking countries), `countries` (registers, then the top Wikidata countries),
     `evidence` (raw counts: `US=` births since 1925, `wd=IR:19` notable bearers by country),
     `origin` (the name's language per Wikidata) and `native` (its native-script spelling).
   - `collision` (`word`: also an ordinary English word), `word_freq`, `lexicon`, `script`.
2. For each name, work out the intended reading and its evidence, and pick a disposition.
3. Write `out/<id>.json` (a JSON array, one entry per input row, any order) and run:
   ```sh
   cd ~/Library/Caches/aloud-names/research && python3 -I tools/check_names.py out/<id>.json
   ```
   Fix every ERROR until it exits 0, and read every WARN. Add `--table` to see today's reading,
   yours and the verdict for every name. It writes `out/<id>.checked.json`.
4. Optional: `--audio 10` renders today's reading and yours for the first 10 corrected names into
   `out/<id>.audio/` and transcribes both with the app's dictation model. Use it only to catch
   garbled phonemes or a lost syllable. It is never evidence that a reading is right: an English
   dictation model hears "Jesus" for both JEE-zus and hay-SOOS.
5. Finish with the checker exiting 0. Report the counts by disposition, the unresolved names and
   any decision someone should review.

## The intended reading
**How the name's own speakers say it, anglicised only as far as an English voice must.** The voice
has only English sounds, so a sound English lacks becomes its nearest English sound, the one a
careful English speaker uses for this name (see the table below). Everything else stays: the
bearers' vowels, consonants and stress. Not a spelling pronunciation, and not the stereotyped
English mangling.

**Several established readings.** Many spellings are said differently by language or region.
Choose the reading of the most common bearer population, judged from the row's `usage`,
`anglo_share`, `countries` and `evidence`; put the others in `alternatives` with their context.
- `usage: english` (most bearers per head live in English-speaking countries): the English
  reading, unless your evidence says those bearers say it otherwise.
- `usage: other`: look at where the bearers are. `anglo_share` 0.10 means about 90% of the
  estimated bearers live outside English-speaking countries.
- Compare readings, not countries: add up the bearers who say it each way. When they are spread
  over several languages that say it differently and the English reading is the largest single
  group, English wins (Joseph: anglo_share 0.08, but German YO-zef, French zho-ZEF and Dutch
  YO-sef each have fewer bearers than English JOH-sef).
- The estimate outside the registers is rough: it scales notable people on Wikidata (`wd=`) by
  population. Trust the register counts (`US=`, `GB-EAW=`, `FR=`, `ES=` ...) more.
- **Andrea** (`other`, anglo_share 0.10; IT, ES, DE, HU): Italian /anˈdrɛ.a/, Spanish /anˈdɾea/
  and German /anˈdʁeːa/ agree on an-DRAY-uh, which is also the English male reading
  /ænˈdɹeɪə/ (Wiktionary): `ændɹˈAə` / GB `andɹˈAə`. Alternatives: English AN-dree-uh
  (`ˈændɹiə` / `ˈandɹiə`, "English-speaking countries, mostly women") and Hungarian ON-dreh-ah.
- **Jean**: French zhahn (/ʒɑːn/, men) against English jeen (/d͡ʒiːn/, women, Wiktionary). It is
  also the word "jean", so it is a protect-word triage first (below).
- **Michele** (`english`, anglo_share 0.18): English mi-SHELL is today's reading and the
  spelling's main English-speaking use; Italian mee-KEH-leh (men) goes in alternatives.
- **Jesús** (Spanish spelling): hay-SOOS, corrected (worked example below). **Jesus** without the
  accent: its bearers are mostly Hispanic, so the name reading is hay-SOOS too, but see the next
  point.

**A spelling that means someone else in English text.** An entry changes every capitalised
occurrence. When the spelling's everyday use in English is not a bearer of the given name and is
read differently (Jesus for Jesus of Nazareth, Israel the country), don't let the name reading
replace it: use `protect-word`, put the name reading in `us`/`gb`, and say why in `notes`.

**Same reading, different unstressed vowels, is still right.** Today's reading is already the
intended one when the stressed syllable, the consonants and the stressed vowel match and only
unstressed vowels differ in reduction (ə, ɪ, a full vowel). Mohammed, read mOhˈæmɪd, against
the dictionary's /məˈhæməd/ is already right. Don't churn readings for that.

## Evidence
Work from sources, in this order of preference:
1. **Pronunciation dictionaries** that list names: Merriam-Webster (biographical names), Oxford,
   Cambridge, Collins, Longman, Dictionary.com, the BBC's pronunciation guidance.
2. **Wiktionary** IPA for the name in its language (the page for the spelling, or for the
   native-script form in `native`: پیام for Payam).
3. **Wikipedia** IPA for a notable bearer of this spelling (the lead sentence's pronunciation, both
   the English and the native IPA).
4. **Native-speaker audio sites** (Forvo and similar): you can't listen, so use only what the page
   says in text: the speaker's language and country, any IPA or respelling.
5. **Behind the Name** and other name sites' pronunciation fields (a reference only; never copy
   their text).
6. **The language's spelling rules**, only for regular, phonemic orthographies (Spanish, Italian,
   Turkish, Finnish, Indonesian, Swahili...) where the spelling fixes the sounds and stress:
   medium confidence at most, and say which rule in `source`.

Never use a dictation round trip as evidence, and never invent certainty. Record facts only (an IPA
string, a respelling, which bearer), not copied paragraphs.

- `source`: what you relied on and what it says, short: "Wiktionary, Spanish Jesús: /xeˈsus/".
- `url`: the page you relied on.
- `confidence`: `high` when a dictionary or Wiktionary/Wikipedia IPA covers this exact spelling
  in the chosen language and nothing contradicts it; `medium` for one secondary source, a name site,
  a regular-orthography reading, or a convention this guide sets (Chinese stress below); `low` for
  a reading you'd defend but can't source well (say why). When you'd be guessing, the disposition
  is `unresolved`.

## Converting IPA to misaki
1. Take the IPA for the name in the chosen language (`ipa` holds it as the source wrote it).
2. Replace each sound with misaki's symbol, or with the nearest English sound (tables below).
3. Move the stress: IPA marks the start of the syllable (`pæˈjɒːm`), misaki marks the vowel
   (`pæjˈɑm`). Every word of two or more syllables needs exactly one primary `ˈ`; add secondary
   `ˌ` where English would. A hyphenated name is one word (`ʤˈinpˌɪɹ`, Jean-Pierre); a name with
   spaces needs a primary in each word.
4. Write `us`. Then write `gb` (required when `us` has `æ O ᵻ T` or an `ɹ` after a vowel and not
   before one; worth writing whenever British differs): `æ`→`a`, `O`→`Q`, `T`→`t`, drop the `ɹ`
   after a vowel and lengthen (`ɑɹ`→`ɑː`, `ɔɹ`→`ɔː`, `ɜɹ`→`ɜː`, `ɪɹ`→`ɪə`, `ɛɹ`→`ɛː`, `əɹ`→`ə`),
   long `i` `u`→`iː` `uː`, an "ah" `ɑ`→`ɑː`, a "lot" `ɑ`→`ɒ`. The app's British readings often
   turn a foreign "ah" into "lot" (Khalid kˈɒlɪd, Juan wˈɒn): a GB-only fix is a correction.
5. Add a plain `respelling` (pah-YAHM, capitals for the stressed syllable).

**Symbols.** Consonants `b d f h k l m n p s t v w z`, `ɡ` (U+0261, not g), `ŋ`, `ɹ` (any r), `ʃ`
(sh), `ʒ` (zh), `θ` (thin), `ð` (this), `ʧ` (ch), `ʤ` (j), `j` (the y sound). Vowels `i` (ee), `ɪ`
(bit), `ɛ` (bed), `æ` (US cat; GB `a`), `ɑ` (spa), `ɒ` (GB lot), `ɔ` (law), `ʊ` (book), `u` (oo),
`ʌ` (cup), `ə` (schwa), `ɜ` (her, US always `ɜɹ`), `ᵊ` (syllabic: `ᵊl`, `ᵊn`). Diphthongs are one
letter: `A` (ay), `I` (eye), `W` (ow), `Y` (oy), `O` (US oh), `Q` (GB oh). GB only: `ː` (length).
Nothing else: no `e o a x r g ɾ ɐ ʔ`, no tie bars, no tone marks.

**Ordinary sounds.**

| IPA | misaki | e.g. |
|---|---|---|
| a (Spanish, Italian, Arabic) stressed | `ɑ` / GB `ɑː` | Ahmad |
| a unstressed, final -a | `ə` | Maria |
| æ (Persian a) | `æ` / GB `a` | Payam |
| e, eː | `A` (open syllable), `ɛ` (closed) | Jesús `hAsˈus`, Fernando `fɛɹnˈɑndO` |
| ɛ | `ɛ` | Michele (Italian) |
| final unstressed -e (Italian) | `A` | Daniele `dænjˈɛlA` |
| i, iː | `i` / GB `iː` | |
| o, oː | `O` / GB `Q` | José `hOzˈA` |
| ɔ | `ɔ` | |
| u, uː | `u` / GB `uː` | |
| ai, au, ei, oi | `I`, `W`, `A`, `Y` | |
| r, ɾ, ʁ, ʀ | `ɹ` (GB drops it before a consonant or at the end) | |
| ɲ (ñ, gn) | `nj` | Begoña `bəɡˈOnjə` |
| ʎ (Spanish ll) | `j` | Guillermo `ɡijˈɛɹmO` |
| ts, dz | `ts`, `dz` | |
| aspirated pʰ tʰ kʰ, dental t̪ d̪ | `p t k`, `t d` | |
| geminates (Arabic mm, Italian tt) | single | |

**Sounds English lacks.** Use what careful English speakers use for that name, and say so in
`notes`:

| Sound | Use | e.g. |
|---|---|---|
| x (Spanish j, Arabic/Persian kh, German ch) | `h` for Spanish, `k` for Arabic and Persian kh, `k` for German ch | Jesús `hAsˈus`, Khalid `kˈɑlɪd` |
| ɣ (Arabic gh) | `ɡ` | Ghada |
| ʁ, ʀ (French, German r) | `ɹ` | |
| ʕ (Arabic ʿayn), ʔ (hamza, ʻokina) | nothing (keep the vowels apart) | ʿAbd `ˈɑbd` |
| ħ (Arabic ḥ) | `h` | Ḥāmid |
| q (Arabic q) | `k` | Qasim |
| y, ʏ (ü), ø, œ, ɶ (ö, ø) | `u`/`ju` for ü; for ö and ø the vowel English sources give (often `ɜɹ`/`ɜː`, sometimes `ɔ`/`ɒ`) | Søren `sˈɔɹən` |
| ɕ, ʂ (Mandarin x, sh), tɕ, ʈʂ (j, zh), tɕʰ (q) | `ʃ`, `ʤ`, `ʧ` | Xiaoping `ʃjˌWpˈɪŋ` |
| ɯ, ɨ (Korean eu, Turkish ı) | `ə` (unstressed), `ʊ` | |
| nasal vowels | the oral vowel, plus `n` where English speakers add one (French); none for Portuguese -ão (`W`) | Jean (French) `ʒˈɑn`, João `ʒuˈW` |
| tones (Mandarin, Cantonese, Vietnamese, Yoruba, Thai) | drop them; stress as English speakers do. If no English source gives it, put primary on the last syllable of a two-syllable Chinese given name and secondary on the first (confidence medium at most) | |
| vowel length (Arabic ā, Japanese ō, Finnish aa) | none in US; the matching long vowel in GB | |

**Stress** follows the language unless English sources consistently shift it: Persian and Turkish
mostly final, Polish penultimate, Finnish, Hungarian and Czech initial, Spanish and Italian as
written or by the penultimate rule, French names final in English, Japanese names usually
penultimate in English (Haruki `həɹˈuki`).

### Worked examples
- **Payam** (Persian; today pˈAəm, "PAY-um", guessed). Wiktionary پیام: Iranian [pʰæ.jɒ́ːm],
  final stress. æ stays (GB `a`); Persian â [ɒː] has no English match, English "ah" is the usual
  approximation; stress moves from before `j` to before the vowel: US `pæjˈɑm`, GB `pajˈɑːm`,
  "pah-YAHM". `corrected`, high.
- **Mohammed** (English spelling of the Arabic name; usage english; today mOhˈæmɪd, CMUdict).
  Wiktionary gives /məˈhæməd/ and /mʊəˈhɑːməd/: today's reading differs only in unstressed vowels,
  so it is `already-correct` (leave `us` and `gb` empty; the checker fills in today's).
  Alternative: `mʊhˈɑməd` / `mʊhˈɑːməd`, "closer to Arabic Muḥammad". This is the control: the
  checker must report it as right/right.
- **Jesús** (Spanish; today ʤˈizəs, the English Jesus). /xeˈsus/: x→`h`, e in an open syllable→`A`:
  US `hAsˈus`, GB `hAsˈuːs`, "hay-SOOS". Alternative: `ʤˈizəs` / `ʤˈiːzəs`, "the English name of
  Jesus of Nazareth".
- **Søren** (Danish; today skɹˈɛn, guessed). Danish [ˈsɶːɐn] has a front rounded vowel; Wikipedia's
  English IPA for Kierkegaard is /ˈsɒrən/: US `sˈɔɹən`, GB `sˈɒɹən`, "SORR-en". Medium.
- **Khalid** (Arabic; today US kˈɑlɪd right, GB kˈɒlɪd "KOL-id"). [ˈxaːlid]: kh→`k`, ā→"ah":
  `corrected` with US `kˈɑlɪd` and GB `kˈɑːlɪd`. The checker shows US right, GB wrong: a GB-only
  fix, which is fine.
- **Andrea**: see above. **Jean** (French men): /ʒɑːn/, US `ʒˈɑn`, GB `ʒˈɑːn`.

`tools/example-batch.json` has the Payam, Mohammed, Jesús, Søren and Will entries in full.

## Dispositions
| disposition | when | needs |
|---|---|---|
| `corrected` | the intended reading differs from today's | `ipa`, `us`, `language`, `source`, `confidence`; `gb` where British differs; `respelling`, `url` |
| `already-correct` | today's reading is the intended one (the checker shows it). Don't override it | `language`, `source`, `confidence`; `ipa`; leave `us`/`gb` empty or equal to today's |
| `protect-word` | the name is an ordinary English word (Rose, May, Will, Grace, Hope, Mark, Bill, Pat, Can, In), or a spelling whose everyday English use is someone else (Jesus) | `notes`. When the name's reading differs from the word's, put the name reading in `us`/`gb` and say so (Can, Turkish: `ʤˈɑn`, "jahn") |
| `not-a-name` | junk in the ranking: a word, a title, a register artefact, a fragment | `notes` |
| `unresolved` | the evidence is thin or conflicting | `notes` (what you found, what's missing); `us` only if you have a candidate |

Protect-word entries are never shipped as general entries: a name like Will must not change "I
will". Where `word_freq` is `rare` and the word is archaic or technical while the name is common
(the name is what readers meet), you may treat it as a normal name instead and say why in
`notes`.

## Matching
- An entry matches its exact, case-sensitive spelling: the capitalised name only. "Rose" never
  touches "rose", and "ROSE" in all caps is left alone.
- Diacritic and transliteration variants are separate names, each researched for its own bearers:
  Jesús and Jesus, Zoë and Zoe, Muhammad, Mohammed, Mohamed and Muḥammad. One entry per input
  row, spelled exactly as the row spells it.
- Multiword rows in the queue (Abd al-Rahman, Ji-hoon, María del Carmen) get one entry for the
  whole spelling. Compounds made only of names already on the list were left out of the queue:
  their parts cover them.

## By task
- `research` (`guesser-reading`, `dictionary-reading-needs-check`, `lexicon-term-reading`):
  today's reading is a guess (about half wrong), or a dictionary reading that may be anglicised
  (about half wrong), or a tech-list term's reading (Pir spelled P-I-R). Research each. For a
  tech-list clash, research the name reading; the clash is settled when the pack is merged.
- `verify` (`covered-by-lexicon`): a custom list (`irish-names`, or a tech-list person) reads it
  on purpose. Usually `already-correct`; if it's wrong, `corrected` with evidence and a note naming
  the list.
- `protect-word triage` (`collision-word`): usually `protect-word`; see the rule above.
- `light verification` (`dictionary-reading-likely-right`): English-usage names read from a
  dictionary, right about 75% of the time. Confirm quickly; correct the misses (Pearse read
  "purse").
- `transliteration note` (`unsupported-script`): names in another script (Александр, 偉) that the
  voice can't read today. Write `unresolved`, `language` and `transliteration` (the usual Latin
  spelling, e.g. Aleksandr), and anything useful in `notes`. No phonemes needed.

## Entry format
```json
{
  "rank": 3437,
  "name": "Payam",
  "language": "Persian",
  "region": "Iran",
  "disposition": "corrected",
  "ipa": "pæˈjɒːm",
  "us": "pæjˈɑm",
  "gb": "pajˈɑːm",
  "respelling": "pah-YAHM",
  "source": "Wiktionary, Persian پیام (payâm): Iran formal [pʰæ.jɒ́ːm]; stress on the last syllable",
  "url": "https://en.wiktionary.org/wiki/%D9%BE%DB%8C%D8%A7%D9%85",
  "confidence": "high",
  "alternatives": [],
  "notes": "Persian â [ɒː] has no English match: English 'ah' is the usual approximation."
}
```
- `language`: the language of the reading you chose; `region`: where its bearers are (optional).
- `ipa`: the source's IPA, as written there (not misaki).
- `alternatives`: `[{"ipa", "us", "gb", "context"}]`, the other established readings, each with
  who says it that way. Same notation rules as `us`/`gb`.
- `transliteration`: only for unsupported-script names.

## What the checker tells you
- Today's US and GB readings and their source, from the app, for every name.
- `verdict_us`/`verdict_gb` in `<id>.checked.json`: `right` (same sounds and stress), `partial`
  (right sounds, wrong stress, or one phoneme off) or `wrong`, comparing your reading with today's.
- ERROR (fails the batch): a missing required field, a symbol outside misaki, a stress mark that
  isn't right before a vowel, a missing or extra primary stress, a missing `gb`, an
  `already-correct` entry whose reading differs from today's, a name missing from or not in the
  input batch, a duplicate.
- WARN: a `corrected` entry that already matches today's reading (it should be `already-correct`),
  no `gb` where British usually differs, no `respelling` or `url`.
