"""Download the given-name sources into a cache folder (FIN-906, phase 1).

Usage: python3 -I fetch.py --cache ~/Library/Caches/aloud-names/run-YYYYMMDD [--only id,id]

Everything downloaded is untrusted data: it lands in its own folder under --cache, is never
executed, and is only parsed by rank.py (run with python3 -I, from this folder). Each file's
URL, size and SHA-256 go to <cache>/<source>/fetch-log.json (rank.py gathers them into
../sources.lock.json), so a rebuild can check it got the same bytes. The Wikidata answers come from the QLever endpoint, which follows Wikidata
live: a later fetch gives slightly different counts (the log records the index date).

Plain python3, standard library only."""
import argparse, hashlib, json, os, sys, time, urllib.parse, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
UA = "Mozilla/5.0 (Macintosh) aloud-names-research/1.0 (+https://aloudformac.com)"
QLEVER = "https://qlever.dev/api/wikidata"

# The SSA's own server answers 403 to some networks (it did to ours on 2026-10-08). The
# fallback is a public mirror of the same yobYYYY.txt files kept in Git LFS, pinned to one
# commit; each file is checked against the SHA-256 in its LFS pointer.
SSA_MIRROR_REPO = "dcadata/name-finder"
SSA_MIRROR_COMMIT = "7991ac3634b18672cc2940526fd8f9363c99462d"
SSA_YEARS = range(1880, 2025)

SOURCES = {
    "us_ssa": {"urls": {"names.zip": "https://www.ssa.gov/oact/babynames/names.zip"}},
    "gb_ew_ons": {"urls": {"babynames1996to2025.xlsx": "https://www.ons.gov.uk/file?uri=/peoplepopulationandcommunity/birthsdeathsandmarriages/livebirths/datasets/babynamesinenglandandwalesfrom1996/1996to2025/babynames1996to2025.xlsx"}},
    "gb_sct_nrs": {"urls": {"full-list-1974-2024.zip": "https://www.nrscotland.gov.uk/media/hlmdqoat/full-list-1974-2024.zip"}},
    "ie_cso": {"urls": {
        "VSA50.json": "https://ws.cso.ie/public/api.restful/PxStat.Data.Cube_API.ReadDataset/VSA50/JSON-stat/2.0/en",
        "VSA60.json": "https://ws.cso.ie/public/api.restful/PxStat.Data.Cube_API.ReadDataset/VSA60/JSON-stat/2.0/en"}},
    "ca_statcan": {"urls": {"17100147-eng.zip": "https://www150.statcan.gc.ca/n1/tbl/csv/17100147-eng.zip"}},
    "fr_insee": {"urls": {"prenoms-2025-nat_csv.zip": "https://www.insee.fr/fr/statistiques/fichier/8595130/prenoms-2025-nat_csv.zip"}},
    "es_ine": {"urls": {"nombres_por_edad_media.xlsx": "https://www.ine.es/daco/daco42/nombyapel/nombres_por_edad_media.xlsx"}},
    "no_ssb": {"post": {"10501.json": ("https://data.ssb.no/api/v0/en/table/10501", {
        "query": [{"code": "Fornavn", "selection": {"filter": "all", "values": ["*"]}},
                  {"code": "Tid", "selection": {"filter": "top", "values": ["1"]}}],
        "response": {"format": "json-stat2"}})}},
    "wikidata": {"sparql": ["wd_given_names", "wd_bearers", "wd_countries"]},
}


def get(url, data=None, headers=None, tries=3, timeout=900):
    h = {"User-Agent": UA}
    h.update(headers or {})
    last = None
    for i in range(tries):
        try:
            req = urllib.request.Request(url, data=data, headers=h)
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return r.read()
        except Exception as e:  # network errors, HTTP errors: retry, then report
            last = e
            if getattr(e, "code", None) in (403, 404):
                break
            time.sleep(5 * (i + 1))
    raise last


def save(path, body, url, log):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(body)
    log[os.path.relpath(path, log["_cache"])] = {
        "url": url, "bytes": len(body), "sha256": hashlib.sha256(body).hexdigest(),
        "fetched": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
    print(f"  {os.path.relpath(path, log['_cache'])}: {len(body):,} bytes", flush=True)


def fetch_ssa_mirror(folder, log):
    raw = f"https://raw.githubusercontent.com/{SSA_MIRROR_REPO}/{SSA_MIRROR_COMMIT}/data/names/"
    media = f"https://media.githubusercontent.com/media/{SSA_MIRROR_REPO}/{SSA_MIRROR_COMMIT}/data/names/"
    for year in SSA_YEARS:
        name = f"yob{year}.txt"
        pointer = get(raw + name).decode("ascii", "replace")
        oid = next((l.split(":", 1)[1].strip() for l in pointer.splitlines() if l.startswith("oid sha256:")), None)
        body = get(media + name)
        if oid is None or hashlib.sha256(body).hexdigest() != oid:
            raise SystemExit(f"SSA mirror: {name} does not match its LFS pointer")
        save(os.path.join(folder, "mirror", name), body, media + name, log)


def fetch_sparql(name, folder, log):
    query = open(os.path.join(HERE, "queries", name + ".rq"), encoding="utf-8").read()
    body = get(QLEVER, data=urllib.parse.urlencode({"query": query}).encode(),
               headers={"Accept": "text/tab-separated-values",
                        "Content-Type": "application/x-www-form-urlencoded"})
    save(os.path.join(folder, name + ".tsv"), body, QLEVER + " (queries/" + name + ".rq)", log)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--cache", required=True)
    ap.add_argument("--only", default="")
    args = ap.parse_args()
    cache = os.path.abspath(os.path.expanduser(args.cache))
    only = set(filter(None, args.only.split(",")))
    for sid, spec in SOURCES.items():
        if only and sid not in only:
            continue
        print(sid, flush=True)
        folder = os.path.join(cache, sid)
        os.makedirs(folder, exist_ok=True)
        log = {"_cache": folder}
        for fname, url in spec.get("urls", {}).items():
            try:
                save(os.path.join(folder, fname), get(url), url, log)
            except Exception as e:
                if sid != "us_ssa":
                    raise
                print(f"  official SSA download failed ({e}); using the pinned mirror", flush=True)
                fetch_ssa_mirror(folder, log)
        for fname, (url, query) in spec.get("post", {}).items():
            save(os.path.join(folder, fname), get(url, data=json.dumps(query).encode(),
                 headers={"Content-Type": "application/json"}), url, log)
        for q in spec.get("sparql", []):
            fetch_sparql(q, folder, log)
        if sid == "wikidata":
            stats = get(QLEVER + "?cmd=stats")
            save(os.path.join(folder, "qlever-stats.json"), stats, QLEVER + "?cmd=stats", log)
        del log["_cache"]
        with open(os.path.join(folder, "fetch-log.json"), "w") as f:
            json.dump(log, f, indent=1, sort_keys=True)
            f.write("\n")


if __name__ == "__main__":
    main()
