# Core readings: decisions for the implementers (FIN-889)

This folder is the spec behind Tests/g2p/core-readings.json: one file per area (rules with trigger, reads_as,
risks and where; open_questions; review_notes), and cross.json (the order the rules run in, conflict resolutions,
who owns what). It was written by one agent per area, attacked by a reviewer, then cross-checked (2026-10-08).

Owner decisions (Payam): "$4.99" reads "four ninety-nine"; Core reads for a general listener and never guesses an
expansion when the text doesn't settle it; packs read like insiders. My call: £ and € keep the currency audible
("four pounds ninety-nine").

Every area's `open_questions` recommendation is ADOPTED, except where this file says otherwise. Every resolution in
cross.json (`conflicts`, `rule_order`, `notes`) is ADOPTED.

Overrides and clarifications:
1. Price per time unit: money reads "a"/"an" ("$9.99/mo" -> "nine ninety-nine a month", "$20/hr" -> "twenty dollars an
   hour"); rates of units read "per" ("300 kWh/yr" -> "three hundred kilowatt hours per year", "mg/kg/day").
2. British "and" in numbers is out of scope: don't add "and" to GB years (2001-2009) or GB cardinals; the GB voice keeps
   today's number reading. Adjust any GB expectation that assumes "and".
3. "™" and "®" are silent; "©" before a year reads "copyright", otherwise silent.
4. Numeric dates: the voice decides the order of an ambiguous date (US month first, GB day first); a part over 12
   settles it. "9/11/2001" is US-only in the tests.
5. Addresses: no 32,000-place gazetteer. A curated list of major places plus the "ZIP code follows" rule; unlisted
   towns with no ZIP stay as letters.
6. Titles: a bare "Lt." reads "L T"; "Lt." before a colour after "Color:"/"Colour:" (and the listed colours) reads
   "light".
7. Roman: the "LIV Golf" case is dropped (it needs a lexicon entry, not a Core rule).
8. ISBN: reading the digit groups is fine; cases may keep the label "ISBN" on both sides.
9. Every rule writes number words WITHOUT hyphens (or leaves digits for the number reader); the harness folds hyphens
   in expected readings.
10. Every new pass that runs before the custom lexicon stays behind `normalizes` (the reference pipeline must not
    change: `--g2p-test` compares against it).

Main has FIN-886 (structure-aware narration), merged at efd4f4b:
- Also run and keep green: `--test-narration Tests/narration/cases.json` (110 cases, including `~~` strike and `**`
  emphasis) and `--test-narration Tests/narration/smoke.json`.
- Shorthand's TextPrep.speechText change (keeping "#", "~" and a keypad "*") touches three plain-text cases pinned
  in smoke.json: "plain: shell comments aren't headings" ("# Install the dependencies npm install" speaks without
  the "#"), "plain: '# of seats' isn't a heading" ("of seats: ..." today) and "plain: '>50%' isn't a quote". If Core
  now reads "# of seats" as "number of seats", that is better: update that expectation deliberately, with the reason
  in the commit message; never loosen a check. A shell comment's "#" stays silent.
- TextPrep.chunks is per-block chunking now (TextPrep.legacyChunks is the 1.6.0 path); the phonemizer honours
  `[words](+1)` stress links, held before the Core passes and restored after normalize.

Tests: Tests/g2p/core-readings.json (speech_cases by area; frozen_cases store today's phonemes per voice and must stay
identical unless deliberately re-frozen with a reason in the commit message). Also keep green: --g2p-test
Tests/g2p/regression.json; --test-dictation Tests/dictation/regression.json and app-lexicon.json; --speech-test
Tests/g2p/pack-readings.json; --test-dictation Tests/dictation/packs.json; the two narration suites.
