# Field packs: research guide

Field packs are pronunciation lists for one field each (finance, medicine, drug names, law, academic
writing, messaging, life sciences, …), built the same way as the tech lexicon (`GUIDE.md`) with a few
additions. FIN-888 holds the plan; each pack has its own Linear issue.

Aloud reads text aloud (Kokoro-82M v1.0 voice) and types what you dictate (NVIDIA Parakeet). A pack
does the same two jobs as the tech lexicon:
1. **Reading:** how the voice says a term (phonemes), checked before the normal pronunciation stack
   (misaki gold dictionary → CMUdict → a small neural guesser).
2. **Dictation (reverse):** when the dictation engine writes "a tor va statin", Aloud types **atorvastatin**.

## How packs fit together
- **Core** (rules in `TextNormalizer`, always on) reads units, money, numbers, dates, addresses, titles
  and everyday shorthand for a general listener. Don't put those in a pack: "mg", "kg", "$5M", "Dr.",
  "Lt.", "w/", "§" belong to Core. A pack may still list a unit with a *field* meaning Core doesn't
  give it (finance "bps" = basis points, aviation "nm" = nautical miles); mark it `pack_only`.
- **A pack reads like an insider.** Use the pronunciation most common among English-speaking
  practitioners of *this field* (clinicians, pharmacists, lawyers, traders, researchers). Abbreviations
  are read the way they say them: letters ("BID" → B-I-D, "PRN" → P-R-N), a word ("REIT" → reet,
  "CAGR" → KAY-ger) or an expansion only when practitioners really say it in full. If an official or
  creator pronunciation differs, it goes in `alternatives`.
- **Two kinds of entry.**
  - Most entries are words the general stack simply doesn't know (atorvastatin, certiorari, EBITDA).
    They're right for everyone, so they apply always: `pack_only: false`.
  - `pack_only: true` marks an entry whose spelling has a *different everyday reading*. It applies only
    when the pack is switched on. Examples: "BID" (the word bid), "PO" (purchase order), "wound"
    (woond, not wownd), "lead" (the metal), "OR" (the word or), "bps" (bits per second in tech),
    "nm" (nanometres elsewhere), "fine" (FEE-nay in music). When in doubt, ask: would a general
    reader who isn't in this field be surprised or misled by this reading? If yes, `pack_only`.
- **One reading per spelling.** Before adding a term, check whether it's already in the tech lexicon
  (`Lexicons/tech-lexicon.json`) or another pack's finished batches. If it is and the reading agrees,
  drop it. If your field reads it differently, keep it as `pack_only` and add a line to
  `conflicts.json` (below). Never silently disagree.
- People's names: how the person says it themselves, anglicised the way English speakers who know
  them say it.

## What to include and drop
Include: terms of the field the stack gets wrong; terms it gets right but that dictation needs
(spelling the dictation engine won't produce: "atorvastatin", "EBITDA", "voir dire"); the field's
abbreviations; eponyms, Latin and loanwords; brand and product names central to the field.

Drop: ordinary English words the stack reads right and dictation already writes right ("patient",
"blood", "invoice"); duplicates; things Core handles. Note drops in your summary.

## Entry format (write a JSON array to `batches/out/<id>.json`)
```json
{
  "word": "atorvastatin",
  "match": "case-insensitive",
  "us": "ətˌɔɹvəstˈætᵊn",
  "gb": "ətˌɔːvəstˈatᵊn",
  "pack": "drugs",
  "category": "drug-generic",
  "pack_only": false,
  "respelling": "uh-TOR-vuh-STAT-in",
  "source": "Merriam-Webster medical; pharmacist pronunciation videos",
  "url": "https://...",
  "confidence": "high",
  "alternatives": "",
  "spoken_variants": ["a tor va statin", "atorva statin"],
  "dictation": "always",
  "dictation_note": "",
  "evidence": true
}
```
- `pack`: the pack id given in your batch input (`finance`, `medicine`, `drugs`, `law`, `academic`,
  `messaging`, `lifesci`).
- `category`: a short kebab-case sub-area inside the pack (`drug-generic`, `drug-brand`, `anatomy`,
  `dosing`, `latin`, `citation`, `crypto`, `accounting`, `gene`, `species`, …). Keep the set small and
  consistent within a pack.
- `match`, `confidence`, `respelling`, `source`, `url`, `alternatives`: as in `GUIDE.md`.
  `case-sensitive` when another casing is an ordinary word or name ("BID" vs bid, "PO" vs po).
  `exact` for keys with punctuation that must match exactly ("q.i.d.", "F.3d").
- `pack_only`: see above. Required (true or false).
- `evidence`: true when seeing this term in a dictation is good evidence the speaker is talking about
  this field (distinctive jargon: "EBITDA", "atorvastatin", "certiorari"). false for terms that turn up
  in everyday messages ("loan", "Visa", "lol", "ASAP") or that belong to several fields.
- Keys may contain spaces ("voir dire", "prima facie", "basis point"): write a single space.

## Phoneme notation
Exactly as in `GUIDE.md` (misaki / Kokoro v1.0 symbols, `research/EN_PHONES.md`). The short version:
- US-only `æ O ᵻ T`; GB-only `a Q ɒ ː`. Diphthongs are single letters: `A` ay, `I` eye, `O` US oh,
  `Q` UK oh, `W` ow, `Y` oy. Use `ʤ ʧ ɡ ɹ`, and `j` for the "y" sound.
- Stress marks go **immediately before the stressed vowel**: `fˈɪɡmə`. Every multi-syllable entry
  needs exactly one primary `ˈ`.
- US flap written `T`; syllabic `ᵊl`, `ᵊn`.
- `gb` is required whenever `us` has a US-only symbol or r-colouring after a vowel.
- Shorthands: `"@L:PNG"` spells letters the misaki way; `"@engine some words"` phonemizes ordinary
  words with the stack (good for expansions and respellings made of real words).
- Copy patterns from `Lexicons/tech-lexicon.json` when unsure.

## Dictation fields
As in `GUIDE.md`. `spoken_variants` are lowercase strings the dictation engine is likely to write when
someone says the term. `dictation` is `always` (no variant is an ordinary word or phrase), `context`
(some variant is: rewrite only when the dictation is clearly about *this field*), or `never`
(pronunciation only). A `pack_only` term is at least `context`.

## Conflicts
When your field reads a spelling differently from the tech lexicon, Core or another pack, add an
object to `batches/out/<id>.conflicts.json`:
`{"word": "bps", "pack": "finance", "reading": "basis points", "other": "tech: B-P-S (bits per second)", "why": "..."}`

## Steps for a batch
Run tools from `tools/` with `../../.venv/bin/python`.
1. Read your input `batches/in/<id>.json`: the pack, the category and the candidate terms.
2. For each candidate: decide spelling, casing and `match`; work out the insider pronunciation
   (research when unsure: official pronunciation pages, Merriam-Webster and other medical, legal or
   financial dictionaries, Wikipedia IPA, practitioner videos, the drug maker's own ads and websites);
   decide `pack_only`, `evidence` and the dictation fields. Don't spend time researching ordinary
   dictionary words. If the stack is already right, copy its reading (`tools/baseline.py "term"`).
3. Write `batches/out/<id>.json`. Run `check_batch.py ../batches/out/<id>.json` and fix every ERROR
   until it exits 0.
4. Run `roundtrip.py ../batches/out/<id>.resolved.json` (it queues for a free slot; give it a long
   timeout). It speaks each term with your phonemes and transcribes it with Aloud's dictation model.
   Re-check terms that come back garbled; add differing transcriptions to `spoken_variants` unless
   they're nonsense; re-run `check_batch.py`.
5. Finish with check_batch exiting 0 and `<id>.asr.json` present.
