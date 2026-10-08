"""Round-trip: Kokoro speaks "Say <term> again." with OUR phonemes (US Heart + US Michael), Parakeet (Aloud's dictation model)
transcribes it. Writes <name>.asr.json: {word: {"heart": ..., "michael": ..., "ok": bool}}. Light (no torch).
Usage: roundtrip.py batches/out/b012.resolved.json   [run AFTER check_batch passes]"""
import sys, os, json, re
import numpy as np
from scipy.signal import resample_poly
from common import SAY, AGAIN, L, P  # noqa
import fcntl, time
# Machine-wide queue: at most SLOTS round-trips run at once (the Mac has 10 cores and many agents share it).
SLOTS = 8
_lockdir = os.path.join(L, ".roundtrip_slots"); os.makedirs(_lockdir, exist_ok=True)
_slot = None
while _slot is None:
    for i in range(SLOTS):
        fh = open(os.path.join(_lockdir, f"slot{i}"), "w")
        try:
            fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB); _slot = fh; break
        except OSError:
            fh.close()
    if _slot is None:
        print("waiting for a free round-trip slot (machine-wide queue of 8)... run with a long timeout or in the background", flush=True)
        time.sleep(5)
import onnxruntime as ort
import synth, sherpa_onnx
def _sess1():
    if synth._sess is None:
        o = ort.SessionOptions(); o.intra_op_num_threads = 1; o.inter_op_num_threads = 1
        synth._sess = ort.InferenceSession(os.path.join(synth.D, "model.onnx"), o, providers=["CPUExecutionProvider"])
    return synth._sess
synth.sess = _sess1
M = os.path.expanduser("~/Library/Application Support/ReadAloud/models/sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8")
rec = sherpa_onnx.OfflineRecognizer.from_transducer(
    encoder=f"{M}/encoder.int8.onnx", decoder=f"{M}/decoder.int8.onnx", joiner=f"{M}/joiner.int8.onnx",
    tokens=f"{M}/tokens.txt", num_threads=1, sample_rate=16000, feature_dim=80,
    decoding_method="greedy_search", model_type="nemo_transducer")
def asr(a24):
    s = rec.create_stream(); s.accept_waveform(16000, resample_poly(a24, 2, 3).astype(np.float32)); rec.decode_stream(s)
    return s.result.text.strip()
def middle(t):
    t = re.sub(r"^\s*say[\s,.]*", "", t, flags=re.I); return re.sub(r"[\s,.]*again[\s.!?]*$", "", t, flags=re.I).strip(" .,")
def same(a, b):
    n = lambda s: re.sub(r"[\s\-.'’]", "", s.lower()); return n(a) == n(b)
path = sys.argv[1]
entries = json.load(open(path, encoding="utf-8"))
res, ok = {}, 0
for e in entries:
    r = {}
    r["heart"] = middle(asr(synth.synth_ps(f"{SAY} {e['us']} {AGAIN}.", "af_heart")))
    if same(r["heart"], e["word"]):
        r["michael"] = r["heart"]          # first voice already transcribed exactly; skip the second to save time
    else:
        r["michael"] = middle(asr(synth.synth_ps(f"{SAY} {e['us']} {AGAIN}.", "am_michael")))
    r["ok"] = same(r["heart"], e["word"]) or same(r["michael"], e["word"]); ok += r["ok"]; res[e["word"]] = r
    print(f"{e['word']!r:30} heart={r['heart']!r:30} michael={r['michael']!r}", flush=True)
op = re.sub(r"(\.resolved)?\.json$", ".asr.json", path)
json.dump(res, open(op, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
print(f"{ok}/{len(entries)} transcribed exactly as the canonical spelling; wrote {op}")
