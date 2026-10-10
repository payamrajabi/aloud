"""Download the ranking sources for the drug-names pack (FIN-893).

Usage (from the repository root):
  python3 -I lexicon-src/drugs/tools/fetch.py [--cache ~/Library/Caches/aloud-drugs] [--refresh]

Files land in <cache>/sources/ (outside the repository; untrusted data, only parsed by
rank.py). Their URL, size and SHA-256 go to lexicon-src/drugs/sources.lock.json, so a
rebuild can check it ranks the same bytes. Plain python3, standard library only."""
import argparse, hashlib, json, os, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import net  # noqa: E402

DRUGS = os.path.dirname(HERE)

# All public: ClinCalc publishes its MEPS-derived Top 300 openly (cited as a source, the
# list itself is used only to rank); the CMS files are US government works.
SOURCES = {
    "clincalc_top300_2024.html": {
        "url": "https://clincalc.com/DrugStats/Top300Drugs.aspx",
        "what": "ClinCalc DrugStats Database, The Top 300 of 2024 (from AHRQ MEPS 2024 prescribed medicines; "
                "US outpatient prescriptions, all ages and payers)"},
    "cms_partd_2024.csv": {
        "url": "https://data.cms.gov/sites/default/files/2026-06/98218f98-166c-4723-8438-c344a4ef96a6/DSD_PTD_RY26_P04_V10_DY24_BGM.csv",
        "what": "CMS Medicare Part D Spending by Drug, 2020-2024 (claims by brand and generic name; Medicare outpatient)"},
    "cms_medicaid_2024.csv": {
        "url": "https://data.cms.gov/sites/default/files/2026-06/ae1c5e06-957d-42dd-b783-e7fe598c01c9/DSD_MCD_RY26_P06_V20_D24_BGM.csv",
        "what": "CMS Medicaid Spending by Drug, 2020-2024 (claims by brand and generic name; covers OTC drugs too)"},
    "cms_partb_2024.csv": {
        "url": "https://data.cms.gov/sites/default/files/2026-06/6616fc91-eb70-404c-9f27-1448e47a3a73/DSD_PTB_RY26_P06_V10_DYT24_HCPCS-%20260602.csv",
        "what": "CMS Medicare Part B Spending by Drug, 2020-2024 (infused and clinic-given drugs: biologics, cancer drugs)"},
}


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--cache", default=net.DEFAULT_CACHE)
    ap.add_argument("--refresh", action="store_true")
    args = ap.parse_args()
    out_dir = os.path.join(args.cache, "sources")
    os.makedirs(out_dir, exist_ok=True)
    lock_path = os.path.join(DRUGS, "sources.lock.json")
    lock = json.load(open(lock_path, encoding="utf-8")) if os.path.exists(lock_path) else {}
    files = lock.setdefault("files", {})
    for name, src in SOURCES.items():
        path = os.path.join(out_dir, name)
        if os.path.exists(path) and not args.refresh:
            body = open(path, "rb").read()
        else:
            status, body = net.get(args.cache, src["url"], refresh=True, timeout=600)
            if status != 200 or not body:
                sys.exit(f"{name}: HTTP {status}")
            with open(path, "wb") as f:
                f.write(body)
        sha = hashlib.sha256(body).hexdigest()
        old = files.get(name, {})
        files[name] = {"url": src["url"], "what": src["what"], "bytes": len(body), "sha256": sha,
                       "fetched": old.get("fetched") if old.get("sha256") == sha else
                       time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
        print(f"{name}: {len(body):,} bytes {sha[:12]}")
    with open(lock_path, "w", encoding="utf-8") as f:
        json.dump(lock, f, indent=1, sort_keys=True, ensure_ascii=False)
        f.write("\n")


if __name__ == "__main__":
    main()
