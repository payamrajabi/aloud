#!/usr/bin/env python3
"""Builds the pronunciation data Aloud's phonemizer reads (Vendor/g2p by default).

Every input is pinned to an exact version and checksum:
  - misaki 0.9.4 "gold" lexicons, US and GB (Apache-2.0). The "silver" lexicons are
    deliberately left out: they were generated with eSpeak NG.
  - CMUdict 0.7a as packaged by NLTK (BSD-2-Clause style licence); first
    pronunciation of each word only.
  - cisco-ai/mini-bart-g2p (Apache-2.0), cisco's own ONNX export, quantised to int8
    with ONNX Runtime (same output as fp32 on 98% of a 1,500-word sample, equal
    accuracy against CMUdict, a quarter of the size).
The quantised model also depends on the onnx and onnxruntime versions, so the Python
packages are pinned too (REQUIREMENTS), and every output file is checked against
OUTPUT_SHA256, the data Aloud ships: a build that comes out different fails.

Needs Python 3.9-3.12 with REQUIREMENTS installed (scripts/setup.sh makes a venv for it).
Usage: python3 scripts/make-g2p-data.py [output-dir]
       python3 scripts/make-g2p-data.py --verify <dir>   check built data (build-app.sh does)
       python3 scripts/make-g2p-data.py --requirements   the pinned packages, for pip
"""
import hashlib, io, json, os, shutil, sys, tempfile, urllib.request, zipfile

VERSION = 1  # bump when the format or sources change (--verify checks it)

# The packages (and their dependencies) that built the shipped data, under Python 3.9.
REQUIREMENTS = [
    "onnx==1.19.1", "onnxruntime==1.19.2", "numpy==2.0.2", "protobuf==6.33.6", "ml_dtypes==0.5.4",
    "flatbuffers==25.12.19", "coloredlogs==15.0.1", "humanfriendly==10.0", "packaging==26.3",
    "sympy==1.14.0", "mpmath==1.3.0", "typing_extensions==4.16.0",
]

# Every file the build produces (besides manifest.json), as shipped since Aloud 1.6.
# Change these only on purpose, together with the sources and VERSION.
OUTPUT_SHA256 = {
    "us_gold.json": "dc414872a49a28ae6c141463d502fd945f3b2fde040484fdc47d00cc4612686f",
    "gb_gold.json": "29e62f4b60261c88f7f3c2c7811ca3825978948090b72d2b27d565b729282f71",
    "cmudict.tsv": "3ce58644bc85cbb91adaa8007192823f5acfe0e0cc76501c56d3fe699c5ce7d5",
    "minibart-encoder.onnx": "ff1592a0926e80817dc7500ea4523b5f2e792bda444307e9c311f2dca8a0b4c4",
    "minibart-decoder.onnx": "81cb67ba6440c59bad68da3a4e3989d32635847df623fe056fd5c9ed771f19c4",
    "minibart-vocab.json": "f479c8da34a4e98ab61d56caa05d260a36211c9e40c767ad366cd426970d928a",
    "licenses/misaki-LICENSE.txt": "c71d239df91726fc519c6eb72d318ec65820627232b2f796219e87dcf35d0ab4",
    "licenses/cmudict-README.txt": "b0556be7a2b12bea6a667277b75864f802dd4854480657ce298c62e6897e766b",
    "licenses/mini-bart-g2p-LICENSE.txt": "43070e2d4e532684de521b885f385d0841030efa2b1a20bafb76133a5e1379c1",
}

MISAKI = ("https://files.pythonhosted.org/packages/82/ec/0ee4110ddb54278b8f21c40a140370ae8f687036c4edf578316602697c56/misaki-0.9.4-py3-none-any.whl",
          "90e2eeb169786c014c429e5058d2ea6bcd02d651f2a24450ba6c9ffc0f8da15a")
MISAKI_LICENSE = ("https://raw.githubusercontent.com/hexgrad/misaki/main/LICENSE", None)
# nltk_data's commit, not its moving gh-pages branch.
CMUDICT = ("https://raw.githubusercontent.com/nltk/nltk_data/5f09e470fe339e1a119dd174ca284129a3c7a5bb/packages/corpora/cmudict.zip",
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


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def differences(directory):
    """How the files in `directory` differ from OUTPUT_SHA256 (an empty list if they don't)."""
    found = {os.path.relpath(os.path.join(r, f), directory)
             for r, _, fs in os.walk(directory) for f in fs if not f.startswith(".")}
    found.discard("manifest.json")
    problems = []
    for name in sorted(found | set(OUTPUT_SHA256)):
        if name not in OUTPUT_SHA256:
            problems.append(f"{name}: not part of the pinned data")
        elif name not in found:
            problems.append(f"{name}: missing")
        else:
            got = sha256(os.path.join(directory, name))
            if got != OUTPUT_SHA256[name]:
                problems.append(f"{name}: different (sha256 {got})")
    return problems


def verify(directory):
    """--verify: exits with the differences unless `directory` holds exactly the pinned data."""
    if not os.path.isdir(directory):
        sys.exit(f"The pronunciation data is missing ({directory}); build it with ./scripts/setup.sh")
    problems = differences(directory)
    try:
        version = json.load(open(os.path.join(directory, "manifest.json")))["version"]
    except (OSError, ValueError, KeyError):
        version = None
    if version != VERSION:
        problems.insert(0, f"manifest.json: version {version}, expected {VERSION}" if version is not None
                        else "manifest.json: missing or unreadable")
    if problems:
        sys.exit(f"The pronunciation data in {directory} isn't the pinned build:\n  " + "\n  ".join(problems)
                 + f"\nRebuild it: rm -rf {directory} && ./scripts/setup.sh")
    print(f"Pronunciation data: {directory} matches its pinned checksums")


def check_requirements():
    """Stops before downloading anything unless exactly REQUIREMENTS is installed."""
    from importlib.metadata import version, PackageNotFoundError
    wrong = []
    for req in REQUIREMENTS:
        name, want = req.split("==")
        try:
            have = version(name)
        except PackageNotFoundError:
            have = "not installed"
        if have != want:
            wrong.append(f"{name} {have} (needs {want})")
    if wrong:
        sys.exit("make-g2p-data.py needs its pinned Python packages: " + ", ".join(wrong)
                 + "\nInstall them in a Python 3.9-3.12 venv: pip install $(python3 scripts/make-g2p-data.py --requirements)")


def main(out):
    check_requirements()
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

    problems = differences(stage)
    if problems:
        sys.exit("The build doesn't match the pinned data (OUTPUT_SHA256):\n  " + "\n  ".join(problems)
                 + f"\nNothing was replaced; the new files are in {stage}."
                 + "\nIf the change is intended, update OUTPUT_SHA256 and VERSION.")
    json.dump({"version": VERSION, "sources": sources, "requirements": REQUIREMENTS, "sha256": OUTPUT_SHA256},
              open(os.path.join(stage, "manifest.json"), "w"), indent=2)
    if os.path.exists(out):
        shutil.rmtree(out)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    shutil.move(stage, out)
    shutil.rmtree(tmp, ignore_errors=True)
    total = sum(os.path.getsize(os.path.join(r, f)) for r, _, fs in os.walk(out) for f in fs)
    print(f"Pronunciation data ready at {out} ({total / 1e6:.1f} MB), matching its pinned checksums")


if __name__ == "__main__":
    default = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Vendor", "g2p")
    args = sys.argv[1:]
    if args[:1] == ["--requirements"]:
        print("\n".join(REQUIREMENTS))
    elif args[:1] == ["--verify"]:
        verify(args[1] if len(args) > 1 else os.path.normpath(default))
    else:
        main(os.path.abspath(args[0] if args else default))
