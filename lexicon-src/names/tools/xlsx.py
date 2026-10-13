"""A minimal .xlsx reader (standard library only): sheet names, and each sheet's rows as lists
of cell values (str, float or None). Enough for the statistics offices' tables; no styles,
dates or formulas beyond their cached values.

The files are untrusted: XML with a DOCTYPE or entity declaration is refused before parsing
(an .xlsx never needs one), which rules out entity-expansion attacks on older expat."""
import re, zipfile
import xml.etree.ElementTree as ET

NS = {"m": "http://schemas.openxmlformats.org/spreadsheetml/2006/main",
      "r": "http://schemas.openxmlformats.org/officeDocument/2006/relationships",
      "pr": "http://schemas.openxmlformats.org/package/2006/relationships"}


def _xml(z, name):
    data = z.read(name)
    if b"<!DOCTYPE" in data or b"<!ENTITY" in data:
        raise ValueError(f"{name}: refusing XML with a DOCTYPE or ENTITY declaration")
    return ET.fromstring(data)


def _col(ref):
    n = 0
    for ch in re.match(r"[A-Z]+", ref).group(0):
        n = n * 26 + ord(ch) - 64
    return n - 1


class Workbook:
    def __init__(self, path):
        self.z = zipfile.ZipFile(path)
        wb = _xml(self.z, "xl/workbook.xml")
        rels = _xml(self.z, "xl/_rels/workbook.xml.rels")
        target = {r.get("Id"): r.get("Target") for r in rels.findall("pr:Relationship", NS)}
        self.sheets = {}
        for s in wb.findall("m:sheets/m:sheet", NS):
            t = target[s.get("{%s}id" % NS["r"])]
            t = t.lstrip("/")
            self.sheets[s.get("name")] = t if t.startswith("xl/") else "xl/" + t
        self.strings = []
        if "xl/sharedStrings.xml" in self.z.namelist():
            for si in _xml(self.z, "xl/sharedStrings.xml").findall("m:si", NS):
                self.strings.append("".join(t.text or "" for t in si.iter("{%s}t" % NS["m"])))

    def rows(self, sheet):
        root = _xml(self.z, self.sheets[sheet])
        for row in root.iter("{%s}row" % NS["m"]):
            out = []
            for c in row.findall("m:c", NS):
                i = _col(c.get("r")) if c.get("r") else len(out)
                while len(out) < i:
                    out.append(None)
                t = c.get("t")
                v = c.find("m:v", NS)
                if t == "s" and v is not None:
                    val = self.strings[int(v.text)]
                elif t == "inlineStr":
                    val = "".join(x.text or "" for x in c.iter("{%s}t" % NS["m"]))
                elif t in ("str", "e") and v is not None:
                    val = v.text
                elif v is not None and v.text is not None:
                    try:
                        val = float(v.text)
                    except ValueError:
                        val = v.text
                else:
                    val = None
                out.append(val)
            yield out
