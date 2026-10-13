# Aloud 10k lexicon: batch guide

Aloud is a Mac app that reads text aloud (Kokoro-82M v1.0 voice) and types what you dictate (NVIDIA Parakeet).
This lexicon does two jobs:
1. **Reading:** tells the voice exactly how to say a term (phonemes), checked before the normal pronunciation stack
   (misaki gold dictionary → CMUdict → a small neural guesser).
2. **Dictation (reverse):** when the dictation engine writes "super base", Aloud types **Supabase**.

Paths below are relative to the lexicon folder `techlex10k/`. Python: `../.venv/bin/python` (run tools from `tools/`, e.g.
`cd tools && ../../.venv/bin/python check_batch.py ../batches/out/b012.json`).

## Policy (owner's decisions)
- **Most common wins.** Use the pronunciation most commonly used by English-speaking practitioners in that field.
  If the creator/official pronunciation differs, still use the common one and put the official one in `alternatives`.
- If a term appears in `research/disputed.json`, use its decision.
- Owner's own usage, for reference: GIF with a hard g (like "gift"), P-N-G, S-Q-L, "web-P".
- Keep the candidate's spelling unless it's wrong. `word` must be the exact canonical spelling and casing (Next.js, iOS, PyTorch, scikit-learn).
- People's names: how the person says it themselves (interviews, their own videos), anglicised the way English speakers who know them say it.

## Entry format (write a JSON array to `batches/out/bNNN.json`)
```json
{
  "word": "Supabase",
  "match": "case-insensitive",
  "us": "sˈupəbˌAs",
  "gb": "sˈuːpəbˌAs",
  "category": "company",
  "respelling": "SOO-puh-bayss",
  "source": "Co-founder Paul Copplestone says 'soo-puh-base' in launch videos",
  "url": "https://...",
  "confidence": "high",
  "alternatives": "",
  "spoken_variants": ["super base", "superbase", "supa base"],
  "dictation": "always",
  "dictation_note": ""
}
```
- `match`:
  - `case-insensitive`: most terms.
  - `case-sensitive`: the term clashes with an ordinary word or name in another casing (Linear, Notion, Slack, Rust, Go, Swift, Miro, CAC, SOC, Inter, ARR, char).
  - `exact`: keys containing punctuation that must match exactly (1:1, TL;DR).
- `category`: one of engineering, ai, cloud, data, security, hardware, company, product, design, typography, business, finance, person, science, media, general.
- `confidence`:
  - `high`: official, dictionary or universal usage.
  - `medium`: good secondary evidence.
  - `low`: a guess. Say why in `source`.
- `url`: include it when you relied on a source.

## Phoneme notation (misaki / Kokoro v1.0). Read `research/EN_PHONES.md`.
- Only misaki symbols. US-only: `æ O ᵻ T`. GB-only: `a Q ɒ ː`. Diphthongs are single letters: `A`=ay, `I`=eye, `O`=US oh, `Q`=UK oh, `W`=ow, `Y`=oy.
  Use `ʤ` (j), `ʧ` (ch), `ɡ` (U+0261, not g), `ɹ` (r), `j` = the "y" sound.
- **Stress marks go immediately before the stressed vowel, not before the syllable:** `fˈɪɡmə` (Figma), `kˌubəɹnˈɛTiz` (Kubernetes),
  `ɡˈɪthˌʌb` (GitHub). Every multi-syllable entry needs exactly one primary `ˈ`; secondary `ˌ` as needed.
- **US flap** (butter, Lottie) is written `T` in this final form, never `ɾ`: `lˈɑTi`. Syllabic l/n: `ᵊl`, `ᵊn` (`pˈɪksᵊl`).
- **`gb` is required** whenever `us` contains a US-only symbol (`æ O ᵻ T`) or US r-colouring after a vowel. Write the British form: `æ`→`a`,
  `O`→`Q`, `T`→`t`, drop post-vowel `ɹ` and lengthen (`ɑɹ`→`ɑː`, `ɔɹ`→`ɔː`, `ɜɹ`→`ɜː`, `əɹ`→`ə`), `u`→`uː`, `i`→`iː` where long, `ɑ` in "lot" words → `ɒ`.
- **Shorthands** (the tools resolve them; prefer them when they fit):
  - `"@L:PNG"` spells the letters exactly the way misaki does.
  - `"@engine x"` phonemizes ordinary words with the stack. Good for expansions ("@year over year") and respellings made of real words. For letter parts inside a longer term, write phonemes by hand.
  - Mixed forms: write the phonemes, or combine by hand (e.g. `nˈOd ʤˌAˈɛs` for Node.js).
- Copy the patterns in `../techlex/tech-lexicon.json` (the reviewed first 100 terms).

## Dictation fields
- `spoken_variants`: lowercase strings a speech-to-text engine is likely to write when someone SAYS the term. Exclude the canonical spelling itself; the tools add that.
  - Split compounds: "git hub", "super base", "post gres q l", "postgres sequel", "next js", "next dot js", "k eights", "kates".
  - Phonetic spellings: "kube control", "cube control", "cube cuttle", "engine x", "jason" (JSON), "yaml"→"yammel".
  - Add what the round-trip test actually produced (see below) when it differs from the canonical spelling.
- `dictation` (how safely Aloud may rewrite a variant into the canonical term):
  - `always`: no variant is an ordinary English word, phrase or common name ("super base", "cube control", "git hub", "engine x"), so it's safe to rewrite anywhere.
  - `context`: some variant is an ordinary word, phrase or name ("jason"→JSON, "view"→Vue, "linear"→Linear, "notion", "slack", "rust", "swift", "stripe", "next"). Rewrite only when the dictation is clearly about tech. List only variants that need it.
  - `never`: the canonical term is itself an ordinary word that dictation already writes correctly (cache, kerning, gestalt). The entry exists for pronunciation only.
- `dictation_note`: optional one-liner on risks (e.g. "P and G = Procter & Gamble; only in file-format context").

## Steps for a batch
1. Read your input file `batches/in/bNNN.json` (candidates; `baseline_us`/`baseline_gb` = what the stack already says).
2. For every candidate: decide spelling/casing and `match`, then work out the most common pronunciation.
   - **Research when you're not sure:** web search for official pronunciation pages, FAQs, the creator's or company's own videos, Wikipedia IPA, dictionaries (Merriam-Webster, Cambridge, Oxford, Dictionary.com), and polls for disputed terms.
   - Don't burn time researching ordinary dictionary words.
   - If the baseline is already right, copy it: the entry still matters for spelling and dictation. A candidate that doesn't belong (not a real term, or a duplicate in a different spelling) can be dropped. Note drops in your summary.
3. Write `batches/out/bNNN.json`. Run `check_batch.py ../batches/out/bNNN.json` and fix every ERROR until it exits 0.
4. Run `roundtrip.py ../batches/out/bNNN.resolved.json`. It speaks each term with YOUR phonemes and transcribes it with Aloud's dictation model. Then:
   - If a non-acronym comes back as something unrelated or garbled, your phonemes may be wrong (or just a hard name). Re-check those.
   - Add the transcriptions that differ from the canonical spelling (lowercased) to `spoken_variants`, unless they're nonsense.
   - Re-run `check_batch.py` (the asr file is kept separately).
5. Finish with check_batch exiting 0 and `bNNN.asr.json` present.
