# Tech lexicon: source data

`Lexicons/tech-lexicon.json` (the file the app ships) is generated from this folder.

- `tech-lexicon-10k.source.json` holds every term with its research: pronunciation (`us`, `gb`, misaki phonemes), a respelling, the source and URL used, confidence, alternatives, the spoken variants used for dictation, and the dictation mode. It also keeps what the default pronunciation stack said before (`baseline_us`), its verdict, and what Aloud's dictation model heard when the voice said the term (`asr_heard`).
- `GUIDE.md` is the brief each research batch followed: policy, notation and fields.
- `decisions/`
  - `disputed.json`: researched calls on contested terms (GIF, SQL, kubectl…).
  - `overrides.json`: owner-level overrides that win over any batch.
  - `ordinary-variants.json`: spoken variants judged everyday English, either dropped or limited to tech sentences.
  - `case-clashes.json`: terms whose lowercase or plural form is an ordinary word or name, so they match their exact spelling only.
  - `merge-report.json`: statistics from the last build.
- `tools/` holds the overnight pipeline scripts: batch checker, round-trip test (voice → dictation model), and merge. They expect the research workspace layout (`batches/out/bNNN*.json`) and a Python environment with misaki, wordfreq, onnxruntime and sherpa-onnx, so treat them as reference rather than a one-command build.

Policy: the most common pronunciation among English-speaking practitioners wins. The official or creator pronunciation goes in `alternatives` when it differs.
