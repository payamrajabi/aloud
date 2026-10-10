"""Polite, cached HTTP for the drug-names pack's tools (FIN-893).

Every response is kept under <cache>/http/<host>/<sha1 of the URL> with a small JSON
sidecar (URL, status, bytes, SHA-256, time), so a rerun reads the cache instead of the
network and a rebuild can see exactly what was fetched. At most one request a second per host
(request starts are spaced across threads). Downloads are untrusted data: they are only parsed, never
executed. Plain python3, standard library only."""
import hashlib, json, os, threading, time, urllib.error, urllib.parse, urllib.request

UA = "Mozilla/5.0 (Macintosh) aloud-drugs-research/1.0 (+https://aloudformac.com)"
DEFAULT_CACHE = os.path.expanduser("~/Library/Caches/aloud-drugs")
_last = {}
_lock = threading.Lock()
OFFLINE = False   # True: answer from the cache only; a miss is (0, b"")


def _paths(cache, url):
    host = urllib.parse.urlsplit(url).netloc or "local"
    key = hashlib.sha1(url.encode("utf-8")).hexdigest()
    d = os.path.join(cache, "http", host)
    return d, os.path.join(d, key), os.path.join(d, key + ".json")


def cached(cache, url):
    """(status, body) from the cache, or None."""
    _, body_path, meta_path = _paths(cache, url)
    if os.path.exists(meta_path):
        meta = json.load(open(meta_path, encoding="utf-8"))
        body = open(body_path, "rb").read() if os.path.exists(body_path) else b""
        return meta.get("status", 0), body
    return None


def get(cache, url, refresh=False, min_interval=1.0, tries=3, timeout=60):
    """(status, body). 404 and other HTTP errors are cached too (status, b"")."""
    if not refresh:
        hit = cached(cache, url)
        if hit is not None:
            return hit
    if OFFLINE:
        return 0, b""
    d, body_path, meta_path = _paths(cache, url)
    os.makedirs(d, exist_ok=True)
    host = urllib.parse.urlsplit(url).netloc
    status, body, last_err = 0, b"", None
    for i in range(tries):
        with _lock:   # space request starts per site, across threads
            start = max(time.time(), _last.get(host, 0) + min_interval)
            _last[host] = start
        if start > time.time():
            time.sleep(start - time.time())
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=timeout) as r:
                status, body = r.status, r.read()
            break
        except urllib.error.HTTPError as e:
            status, body = e.code, b""
            if e.code in (400, 403, 404, 410):
                break
            last_err = e
        except Exception as e:  # network trouble: back off and retry
            last_err = e
            status = 0
        time.sleep(3 * (i + 1))
    if status == 0:
        raise RuntimeError(f"{url}: {last_err}")
    with open(body_path, "wb") as f:
        f.write(body)
    with open(meta_path, "w", encoding="utf-8") as f:
        json.dump({"url": url, "status": status, "bytes": len(body),
                   "sha256": hashlib.sha256(body).hexdigest(),
                   "fetched": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}, f)
    return status, body
