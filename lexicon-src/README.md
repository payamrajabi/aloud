# Tech lexicon: source data

`Lexicons/tech-lexicon.json` (the file the app ships) is generated from this folder.

- `tech-lexicon-10k.source.json` holds every term with its research: pronunciation (`us`, `gb`, misaki phonemes), a respelling, the source and URL used, confidence, alternatives, the spoken variants used for dictation, and the dictation mode. It also keeps what the default pronunciation stack said before (`baseline_us`), its verdict, and what Aloud's dictation model heard when the voice said the term (`asr_heard`).
- `GUIDE.md` is the brief each research batch followed: policy, notation and fields.
- `decisions/`
  - `disputed.json`: researched calls on contested terms (GIF, SQL, kubectl…).
  - `overrides.json`: owner-level overrides that win over any batch.
  - `ordinary-variants.json`: spoken variants judged everyday English, either dropped or limited to tech sentences.
  - `case-clashes.json`: terms whose lowercase or plural form is an ordinary word or name, so they match their exact spelling only.
  - `strict-variant-review.json`: the pre-release second pass. Two judges looked at every variant made only of dictionary words, and the more careful verdict won.
  - `developer-tools.json`: company and product terms that count as software-development context for dictation, alongside every engineering, cloud, data, AI and security term.
  - `merge-report.json`: statistics from the last build.
  - `conflicts.json`: spellings that two lists read differently on purpose (finance "bps" is basis points, tech "bps" is B-P-S): `{"word", "packs": [...], "readings": {pack: "what it says"}, "why"}`. A pack batch's own `<id>.conflicts.json` lines end up here when the pack is merged.
- `tools/` holds the overnight pipeline scripts: batch checker, round-trip test (voice → dictation model), and merge. They expect the research workspace layout (`batches/out/bNNN*.json`) and a Python environment with misaki, wordfreq, onnxruntime and sherpa-onnx, so treat them as reference rather than a one-command build.
- `tools/check_packs.py` needs nothing but python3. Run it before a pack lands in `Lexicons/`: it fails on a spelling that two files read differently and `decisions/conflicts.json` doesn't list, and on a `pack_only` entry in the tech list (which is always on). `python3 lexicon-src/tools/check_packs.py`

Field packs (`PACKS-GUIDE.md`): every file in `Lexicons/` is a pack named after the file (`finance.json` is "finance"; `tech-lexicon.json` is "tech"). The app reads them all. A pack's general entries apply always; its `pack_only: true` entries only while the pack is switched on (never in the tech list, which is always on). Dictation context is per pack: a finance term that needs context needs a finance term nearby.

Runtime flags written by `merge.py`:
- `evidence: false`: the term never makes a dictation count as talk about its field (tech, for this list). This covers consumer brands and anything spelled like an ordinary word.
- `unit: true`: applies only right after a number ("16 GB", "9 AM").
- `caps_word: true`: skipped in all-caps sentences.

Policy: the most common pronunciation among English-speaking practitioners wins. The official or creator pronunciation goes in `alternatives` when it differs.
