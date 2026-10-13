# Core readings: who owns what (FIN-889)

Rebuilt on 2026-10-09 from the skeleton commit (574e893) and its report; the original was lost with a scratch folder.
No area edits another area's files. Shared helpers (Sources/Phonemizer/Core/Shared*.swift) may gain additions,
never changes to existing behaviour.

| Area | Owns | May also edit |
|---|---|---|
| money | Core/MoneyPass.swift | Lexicon.getNumber's "$" branch (price style), Lexicon.currencies, currencyPlurals, SharedNames.CurrencyNames, the "-$" and "~"/"≈" before money |
| phone | Core/PhonePass.swift | (keypad "*" handling lives in shorthand's TextPrep change) |
| addresses | Core/AddressPass.swift | readStreets and Ave./Blvd./Mt. (moved into its hooks), its `sentenceContinues` hook (Tokenizer.titleContinues asks it) |
| titles | Core/TitlePass.swift | the title rule, Jr./Sr./Esq. (owner of both), its `sentenceContinues` hook |
| shorthand | Core/ShorthandPass.swift, Core/ShorthandRules.swift | Lexicon.symbols (™ ® silent), TextPrep.speechText (keep "#", "~", keypad "*"), §/¶, the abbreviations list, its `sentenceContinues` hook, "#" readings (number / pound / hash) |
| dimensions | Core/MeasuresPass.swift | feet and inches, inch marks, sizes with x/×, multipliers (moved Heights and Inches rules) |
| roman | Core/RomanPass.swift | the FIN-877 Roman reader and WW2 (moved), Lexicon.isShoutedWord |
| units | Core/UnitRules.swift | the units tables, area and power rules, unit ranges, `UnitRules.readsMarkedTerm` |
| dates | Core/DateRules.swift | the ISO rule, "Jan 5", "Feb." (moved), SharedNames.CalendarNames, quarter-year split |

Moved code still runs where it ran, through each area's `legacyRules` / `readAfterUnshout` hooks; when an area's pass
takes a rule over, it makes that hook return [] in its own file. TextNormalizer builds one rule list per voice, once
(`makeRules(british:)`), with each area's hooks at its rule_order step (cross.json).
