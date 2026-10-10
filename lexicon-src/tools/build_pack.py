"""Build a field pack's shipped list (Lexicons/<pack>.json) from its master source file.

Usage (python3, standard library only, from the repository root):
  python3 -I lexicon-src/tools/build_pack.py messaging            # writes Lexicons/messaging.json
  python3 -I lexicon-src/tools/build_pack.py academic --check     # exit 1 if the shipped file is stale

The source is lexicon-src/<pack>/<pack>.source.json: every entry with its evidence (reading,
respelling, source, the stack's reading before the pack); the shipped file keeps only what the
app reads: word, match, us, gb, pack_only and the dictation fields. A source with
"default_on": true (the pack is heard by everyone until packs get a Settings switch) may not
hold pack_only entries, which nobody would hear."""
import json, os, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SHIPPED = ("word", "match", "us", "gb", "pack_only", "dictation", "evidence", "spoken", "spoken_context_only")


def build(pack):
    doc = json.load(open(os.path.join(ROOT, "lexicon-src", pack, f"{pack}.source.json"), encoding="utf-8"))
    seen, rows = set(), []
    for e in doc["entries"]:
        key = (e["word"] if e["match"] != "case-insensitive" else e["word"].lower(), e["match"] != "case-insensitive")
        if key in seen:
            sys.exit(f"{e['word']}: listed twice")
        seen.add(key)
        if e.get("pack_only") and doc.get("default_on"):
            sys.exit(f"{e['word']}: the {pack} pack is on by default; pack_only would hide it")
        if not isinstance(e.get("pack_only"), bool):
            sys.exit(f"{e['word']}: pack_only must be true or false")
        rows.append({k: e[k] for k in SHIPPED if k in e and e[k] not in (None, "", [])})
    return "[\n" + ",\n".join(json.dumps(r, ensure_ascii=False, separators=(",", ":")) for r in rows) + "\n]\n"


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if len(args) != 1:
        sys.exit(__doc__)
    pack = args[0]
    path = os.path.join(ROOT, "Lexicons", f"{pack}.json")
    text = build(pack)
    if "--check" in sys.argv:
        current = open(path, encoding="utf-8").read() if os.path.exists(path) else ""
        if current != text:
            sys.exit(f"Lexicons/{pack}.json is out of date: run lexicon-src/tools/build_pack.py {pack}")
        print(f"Lexicons/{pack}.json is up to date")
        return
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)
    print(f"{text.count(chr(10)) - 2} entries written to Lexicons/{pack}.json")


if __name__ == "__main__":
    main()
