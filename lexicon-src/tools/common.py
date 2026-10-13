"""Shared helpers for the 10k lexicon. Light by default: the heavy stack (misaki+torch) loads only when needed."""
import os, sys, json, re
L = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
P = os.path.dirname(L)
sys.path.insert(0, os.path.join(P, "techlex")); sys.path.insert(0, P)
os.environ.setdefault("HF_HUB_OFFLINE", "1"); os.environ.setdefault("TRANSFORMERS_OFFLINE", "1")
_V = json.load(open(os.path.join(L, "tools", "vocab.json"), encoding="utf-8"))
US_OK, GB_OK, KOKORO = set(_V["US_OK"]), set(_V["GB_OK"]), set(_V["KOKORO"])
VOWELS = frozenset('AIOQWYaiuæɑɒɔəɛɜɪʊʌᵻ')
US_ONLY, GB_ONLY = set("æOᵻT"), set("aQɒː")
SAY, AGAIN = "sˈA", "əɡˈɛn"
CATEGORIES = {"engineering", "ai", "cloud", "data", "security", "hardware", "company", "product", "design",
              "typography", "business", "finance", "person", "science", "media", "general"}
DICTATION = {"always", "context", "never"}
CACHE = os.path.join(L, "baseline_cache.json")
_stack = None

def stack():
    global _stack
    if _stack is None:
        import stack as s
        _stack = s
    return _stack

def resolve(spec, british):
    """"@L:WORD" = spell the letters (misaki convention); "@some words" = phonemize those words with the stack."""
    if not spec: return None
    if spec.startswith("@L:"):
        ps, _ = stack().g2p(british).lexicon.get_NNP(spec[3:]); return ps
    if spec.startswith("@"):
        ps, _ = stack().phonemize(spec[1:], british); return ps.strip().rstrip(".").strip()
    return spec

_cache = None
def baseline(term, british):
    """What the stack alone says for `term` (cached; computes and stores misses)."""
    global _cache
    if _cache is None:
        _cache = json.load(open(CACHE, encoding="utf-8")) if os.path.exists(CACHE) else {}
    k = ("gb:" if british else "us:") + term
    if k not in _cache:
        _cache[k] = stack().term_baseline(term, british)[0]
        try:
            disk = json.load(open(CACHE, encoding="utf-8")) if os.path.exists(CACHE) else {}
            disk[k] = _cache[k]; tmp = CACHE + f".{os.getpid()}"
            json.dump(disk, open(tmp, "w", encoding="utf-8"), ensure_ascii=False); os.replace(tmp, CACHE)
        except Exception: pass
    return _cache[k]

def bad_symbols(ps, british):
    ok = GB_OK if british else US_OK
    return sorted({c for c in ps if c not in ok or (c not in " ˈˌT" and c not in KOKORO)})

def norm(ps, keep_stress=True):
    ps = ps.replace("ᵊ", "ə").replace("ᵻ", "ɪ").replace("ɾ", "T").replace("T", "t").replace(" ", "").replace("-", "")
    return ps if keep_stress else ps.replace("ˈ", "").replace("ˌ", "")

def lev(a, b):
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]

def primary_syllable_index(ps):
    n = 0
    for c in ps:
        if c == "ˈ": return n
        if c in VOWELS: n += 1
    return None

def auto_verdict(base, custom):
    if not base or "❓" in base: return "wrong", "no output"
    if norm(base) == norm(custom): return "right", "identical"
    a, b = norm(base, False), norm(custom, False)
    if a == b:
        if primary_syllable_index(norm(base)) == primary_syllable_index(norm(custom)):
            return "right", "same sounds, only secondary-stress differences"
        return "partial", "right sounds, wrong stress"
    d = lev(a, b)
    if d <= 1 and len(b) >= 4: return "partial", f"{d} phoneme off"
    return "wrong", f"{d} phonemes off"
