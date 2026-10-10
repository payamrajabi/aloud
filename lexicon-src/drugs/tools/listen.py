"""Before/after listening page for the drugs pack (FIN-893).

Usage (from the repository root, after assemble.py; needs the voice installed):
  python3 -I lexicon-src/drugs/tools/listen.py [--binary .build/release/ReadAloud]
      [--out ~/Library/Caches/aloud-drugs/listen] [--seed 893]

1. Draws the listening sample from drugs.source.json and writes it to listen-sample.json
   (kept in the repository, so the sample is fixed before anyone listens). The strata:
   the 40 most-prescribed changed generic words, the 30 most-prescribed changed brands,
   salts and devices (6), every low-confidence shipped reading (up to 25), already-right
   controls (8, the reading must not move) and must-not-change controls (8 ordinary words
   that are also drug names or brands, held back from the pack). A sample that already
   exists is reused unless --redraw is given.
2. Renders each one with the app's own voice, before (the reading recorded before the pack)
   and after (the pack's), alone and in "Ask your pharmacist about ___ today."
3. Writes a self-contained page (audio inlined) to <out>/drugs-listening.html.
Plain python3 (standard library) and macOS afconvert."""
import argparse, base64, html, json, os, random, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
DRUGS = os.path.dirname(HERE)
ROOT = os.path.dirname(os.path.dirname(DRUGS))
CARRIER = ("Ask your pharmacist about ", " today.")


def draw(rows, seed):
    rnd = random.Random(seed)
    shipped = [r for r in rows if r.get("shipped")]
    by = lambda kinds: sorted([r for r in shipped if r["kind"] in kinds], key=lambda r: r["rank"])
    pick = []
    def add(group, label, n=None, sample=False):
        g = [r for r in group if r["word"] not in {p["word"] for p in pick}]
        if sample and n is not None and len(g) > n:
            g = rnd.sample(g, n)
        for r in (g if n is None else g[:n]):
            pick.append({"word": r["word"], "kind": r["kind"], "stratum": label})
    add(by({"generic"}), "top generic", 40)
    add(by({"brand"}), "top brand", 30)
    add(by({"salt", "device"}), "salt or device", 6, sample=True)
    add([r for r in shipped if r.get("confidence") == "low"], "low confidence", 25)
    add(sorted([r for r in rows if r.get("disposition") == "already-correct"], key=lambda r: r["rank"])[:40],
        "already right (control)", 8, sample=True)
    add(sorted([r for r in rows if r.get("disposition") == "ordinary-word" or (r.get("held") and r.get("disposition") == "corrected")],
               key=lambda r: r["rank"]), "must not change (control)", 8, sample=True)
    return pick


def phon(binary, lines):
    r = subprocess.run([binary, "--phonemize"], input="\n".join(lines) + "\n", capture_output=True, text=True, timeout=900).stdout
    return {row.split("\t")[0]: row.split("\t")[1].strip() for row in r.splitlines() if "\t" in row}


def render(binary, ps, path):
    if os.path.exists(path):
        return
    wav = path[:-4] + ".wav"
    subprocess.run([binary, "--render-phonemes", ps, "--out", wav], capture_output=True, timeout=180)
    subprocess.run(["afconvert", "-f", "m4af", "-d", "aac", "-b", "40000", wav, path], capture_output=True)
    if os.path.exists(wav):
        os.remove(wav)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--binary", default=os.path.join(ROOT, ".build", "release", "ReadAloud"))
    ap.add_argument("--out", default=os.path.expanduser("~/Library/Caches/aloud-drugs/listen"))
    ap.add_argument("--seed", type=int, default=893)
    ap.add_argument("--redraw", action="store_true")
    ap.add_argument("--version", default="")
    args = ap.parse_args()
    src = json.load(open(os.path.join(DRUGS, "drugs.source.json"), encoding="utf-8"))
    rows = {(r["word"], r["kind"]): r for r in src["rows"]}
    sample_path = os.path.join(DRUGS, "listen-sample.json")
    if os.path.exists(sample_path) and not args.redraw:
        sample = json.load(open(sample_path, encoding="utf-8"))["sample"]
    else:
        sample = draw(list(rows.values()), args.seed)
        with open(sample_path, "w", encoding="utf-8") as f:
            json.dump({"about": f"Drugs pack listening sample (FIN-893), drawn with seed {args.seed} by tools/listen.py "
                                "before listening; strata in tools/listen.py.", "sample": sample}, f, ensure_ascii=False, indent=1)
            f.write("\n")
    os.makedirs(os.path.join(args.out, "clips"), exist_ok=True)
    items = []
    spell = lambda r: r.get("spelling") or r["word"]
    sentences = phon(args.binary, [CARRIER[0] + spell(rows[(s["word"], s["kind"])]) + CARRIER[1] for s in sample])
    edge = phon(args.binary, [CARRIER[0].strip(), CARRIER[1].strip()])
    for n, s in enumerate(sample, 1):
        r = rows[(s["word"], s["kind"])]
        before = r["today_us"]
        after = r["us"] if r.get("shipped") else before
        sa = sentences.get(CARRIER[0] + spell(r) + CARRIER[1], "")
        sb = sa.replace(after, before, 1) if after in sa else f"{edge.get(CARRIER[0].strip(), '')} {before} {edge.get(CARRIER[1].strip(), '')}"
        if not r.get("shipped"):
            sb = sa
        items.append({"n": n, "name": spell(r), "stratum": s["stratum"], "say": r.get("respelling", ""),
                      "conf": r.get("confidence", "") if r.get("shipped") else "", "same": before == after,
                      "before": before, "after": after, "sb": sb, "sa": sa,
                      "note": r.get("notes", "") or "; ".join(r.get("held", [])),
                      "src": "; ".join(f"{e.get('source')}: {e.get('says', '')}" for e in r.get("evidence", []) if isinstance(e, dict))[:400],
                      "url": next((e.get("url") for e in r.get("evidence", []) if isinstance(e, dict) and e.get("url")), "")})
    for it in items:
        base = os.path.join(args.out, "clips", f"{it['n']:03d}")
        for kind, b, a in (("alone", it["before"], it["after"]), ("sentence", it["sb"], it["sa"])):
            render(args.binary, b, f"{base}.{kind}.before.m4a")
            if a == b:
                if not os.path.exists(f"{base}.{kind}.after.m4a"):
                    subprocess.run(["cp", f"{base}.{kind}.before.m4a", f"{base}.{kind}.after.m4a"])
            else:
                render(args.binary, a, f"{base}.{kind}.after.m4a")
        print(it["n"], it["name"], flush=True)
    with open(os.path.join(args.out, "manifest.json"), "w", encoding="utf-8") as f:
        json.dump(items, f, ensure_ascii=False, indent=1)
    page(items, args.out, args.version)


def uri(out, n, kind, when):
    p = os.path.join(out, "clips", f"{n:03d}.{kind}.{when}.m4a")
    return "data:audio/mp4;base64," + base64.b64encode(open(p, "rb").read()).decode() if os.path.exists(p) else ""


def page(items, out, version):
    data = [{"n": it["n"], "name": it["name"], "say": it["say"], "same": it["same"], "conf": it["conf"],
             "stratum": it["stratum"], "note": it["note"], "src": it["src"], "url": it["url"],
             "a": {k: uri(out, it["n"], k.split("_")[0], k.split("_")[1])
                   for k in ("alone_before", "alone_after", "sentence_before", "sentence_after")}} for it in items]
    changed = sum(1 for x in data if not x["same"])
    tpl = open(os.path.join(HERE, "listen_template.html"), encoding="utf-8").read()
    body = (tpl.replace("__DATA__", json.dumps(data, ensure_ascii=False))
               .replace("__META__", html.escape(f"{version} · {len(data)} names · {changed} change · {len(data) - changed} stay the same")))
    path = os.path.join(out, "drugs-listening.html")
    with open(path, "w", encoding="utf-8") as f:
        f.write(body)
    print(path, os.path.getsize(path) // 1024, "KB")


if __name__ == "__main__":
    main()
