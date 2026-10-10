"""Build Lexicons/messaging.json (FIN-896) from messaging.source.json.

Usage (python3, standard library only, from the repository root):
  python3 -I lexicon-src/messaging/build.py            # writes Lexicons/messaging.json
  python3 -I lexicon-src/messaging/build.py --check    # exit 1 if the shipped file is stale

The source holds every entry with its evidence (reading, respelling, source, the stack's reading
before the pack); the shipped file keeps only what the app reads: word, match, us, gb, and the
dictation fields. Every entry is general (pack_only false): the pack is on by default, and none
of its spellings has another everyday reading. The pack's context-dependent readings (emoji,
emoticons, hashtags, @mentions, u/ur) are code: Sources/Phonemizer/Packs/MessagingPass.swift."""
import json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
SOURCE = os.path.join(HERE, "messaging.source.json")
PACK = os.path.join(ROOT, "Lexicons", "messaging.json")
SHIPPED = ("word", "match", "us", "gb", "pack_only", "dictation", "evidence", "spoken", "spoken_context_only")


def build():
    doc = json.load(open(SOURCE, encoding="utf-8"))
    seen, rows = set(), []
    for e in doc["entries"]:
        key = (e["word"] if e["match"] != "case-insensitive" else e["word"].lower(), e["match"] != "case-insensitive")
        if key in seen:
            sys.exit(f"{e['word']}: listed twice")
        seen.add(key)
        if e.get("pack_only"):
            sys.exit(f"{e['word']}: the messaging pack is on by default; pack_only would hide it")
        rows.append({k: e[k] for k in SHIPPED if k in e and e[k] not in (None, "", [])})
    return "[\n" + ",\n".join(json.dumps(r, ensure_ascii=False, separators=(",", ":")) for r in rows) + "\n]\n"


def main():
    text = build()
    if "--check" in sys.argv:
        current = open(PACK, encoding="utf-8").read() if os.path.exists(PACK) else ""
        if current != text:
            sys.exit("Lexicons/messaging.json is out of date: run lexicon-src/messaging/build.py")
        print("Lexicons/messaging.json is up to date")
        return
    with open(PACK, "w", encoding="utf-8") as f:
        f.write(text)
    print(f"{text.count(chr(10)) - 2} entries written to {os.path.relpath(PACK, ROOT)}")


if __name__ == "__main__":
    main()
