#!/usr/bin/env python3
"""Builds the pronunciation data Aloud's phonemizer reads (Vendor/g2p by default).

Every input is pinned to an exact version and checksum, so the output is reproducible:
  - misaki 0.9.4 "gold" lexicons, US and GB (Apache-2.0). The "silver" lexicons are
    deliberately left out: they were generated with eSpeak NG.
  - CMUdict 0.7a as packaged by NLTK (BSD-2-Clause style licence); first
    pronunciation of each word only.
  - cisco-ai/mini-bart-g2p (Apache-2.0), cisco's own ONNX export, quantised to int8
    with ONNX Runtime (same output as fp32 on 98% of a 1,500-word sample, equal
    accuracy against CMUdict, a quarter of the size).

Needs Python 3 with `onnx` and `onnxruntime` (scripts/setup.sh makes a venv for it).
Usage: python3 scripts/make-g2p-data.py [output-dir]
"""
import hashlib, io, json, os, shutil, sys, tempfile, urllib.request, zipfile

OUT = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "..", "Vendor", "g2p"))
VERSION = 1  # bump when the format or sources change; the app checks it

MISAKI = ("https://files.pythonhosted.org/packages/82/ec/0ee4110ddb54278b8f21c40a140370ae8f687036c4edf578316602697c56/misaki-0.9.4-py3-none-any.whl",
          "90e2eeb169786c014c429e5058d2ea6bcd02d651f2a24450ba6c9ffc0f8da15a")
MISAKI_LICENSE = ("https://raw.githubusercontent.com/hexgrad/misaki/main/LICENSE", None)
CMUDICT = ("https://raw.githubusercontent.com/nltk/nltk_data/gh-pages/packages/corpora/cmudict.zip",
           "d07cca47fd72ad32ea9d8ad1219f85301eeaf4568f8b6b73747506a71fb5afd6")
MINIBART_REV = "0fbbf8c590f9db920939a2bc4befbaac26eebc4c"
MINIBART = "https://huggingface.co/cisco-ai/mini-bart-g2p/resolve/" + MINIBART_REV + "/"
MINIBART_SHA = {
    "onnx/encoder_model.onnx": "5df81746fe1872b63aa120205ce267ed44163b7894a54e931a1d4b4b09568faa",
    "onnx/decoder_model.onnx": "2c199ceaa241186259167a8e79c5ff3498609ee8fc01c28c8a3d76a351d33c3d",
    "vocab.json": "96194cee6243ba9abf5481957cf40342789978a9259d517a7ee48dd0e23dd6ad",
    "LICENSE": "43070e2d4e532684de521b885f385d0841030efa2b1a20bafb76133a5e1379c1",
}


def fetch(url, sha=None):
    with urllib.request.urlopen(url) as r:
        data = r.read()
    if sha and hashlib.sha256(data).hexdigest() != sha:
        sys.exit(f"Checksum mismatch for {url}")
    return data


def main():
    import onnx  # noqa: F401  (quantize_dynamic needs it)
    from onnxruntime.quantization import quantize_dynamic, QuantType

    tmp = tempfile.mkdtemp()
    stage = os.path.join(tmp, "g2p")
    os.makedirs(os.path.join(stage, "licenses"))
    sources = {}

    print("misaki gold lexicons...")
    wheel = zipfile.ZipFile(io.BytesIO(fetch(*MISAKI)))
    for name in ("us_gold.json", "gb_gold.json"):
        data = wheel.read("misaki/data/" + name)
        json.loads(data)  # sanity check
        open(os.path.join(stage, name), "wb").write(data)
    lic = [n for n in wheel.namelist() if n.endswith("LICENSE") or n.endswith("LICENSE.txt")]
    open(os.path.join(stage, "licenses", "misaki-LICENSE.txt"), "wb").write(
        wheel.read(lic[0]) if lic else fetch(MISAKI_LICENSE[0]))
    sources["misaki"] = {"url": MISAKI[0], "sha256": MISAKI[1]}

    print("CMUdict...")
    z = zipfile.ZipFile(io.BytesIO(fetch(*CMUDICT)))
    raw = z.read("cmudict/cmudict").decode("latin-1")
    first = {}
    for line in raw.splitlines():
        parts = line.split()
        if len(parts) < 3 or line.startswith(";;;"):
            continue
        word = parts[0].lower()
        if word not in first:  # NLTK keeps alternatives in file order; Aloud uses the first
            first[word] = " ".join(parts[2:])
    with open(os.path.join(stage, "cmudict.tsv"), "w", encoding="utf-8") as f:
        for w in sorted(first):
            f.write(f"{w}\t{first[w]}\n")
    open(os.path.join(stage, "licenses", "cmudict-README.txt"), "wb").write(z.read("cmudict/README"))
    sources["cmudict"] = {"url": CMUDICT[0], "sha256": CMUDICT[1], "entries": len(first)}

    print("mini-bart-g2p (ONNX, quantising to int8)...")
    for part in ("encoder", "decoder"):
        src = os.path.join(tmp, f"{part}.onnx")
        open(src, "wb").write(fetch(MINIBART + f"onnx/{part}_model.onnx", MINIBART_SHA[f"onnx/{part}_model.onnx"]))
        quantize_dynamic(src, os.path.join(stage, f"minibart-{part}.onnx"), weight_type=QuantType.QInt8)
    vocab = json.loads(fetch(MINIBART + "vocab.json", MINIBART_SHA["vocab.json"]))
    json.dump(vocab, open(os.path.join(stage, "minibart-vocab.json"), "w"), indent=0, sort_keys=True)
    open(os.path.join(stage, "licenses", "mini-bart-g2p-LICENSE.txt"), "wb").write(fetch(MINIBART + "LICENSE", MINIBART_SHA["LICENSE"]))
    sources["mini-bart-g2p"] = {"repo": "cisco-ai/mini-bart-g2p", "revision": MINIBART_REV}

    json.dump({"version": VERSION, "sources": sources}, open(os.path.join(stage, "manifest.json"), "w"), indent=2)
    if os.path.exists(OUT):
        shutil.rmtree(OUT)
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    shutil.move(stage, OUT)
    shutil.rmtree(tmp, ignore_errors=True)
    total = sum(os.path.getsize(os.path.join(r, f)) for r, _, fs in os.walk(OUT) for f in fs)
    print(f"Pronunciation data ready at {OUT} ({total / 1e6:.1f} MB)")


if __name__ == "__main__":
    main()
