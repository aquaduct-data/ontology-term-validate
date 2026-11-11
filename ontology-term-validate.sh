#!/usr/bin/env bash
# ontology-term-validate — identifier/label validation for ontology-backed terms.
#
#   ontology-term-validate.sh [options] <path> [<path>...]
#
# WHY THIS EXISTS
#   ga4gh/phenopacket-schema#451: the urothelial-carcinoma example writes
#   `ontologyClass("NCIT:C5189", "Radical Cystoprostatectomy")`. NCIT:C5189 is
#   a real, syntactically valid identifier — it just means "Breast Extraskeletal
#   Osteosarcoma". The intended term is NCIT:C51899. Nothing in the build catches
#   that, because the identifier parses and the label is only a string.
#   Upstream maintainer cmungall asked, in that issue, for exactly this check:
#   "add identifier/label validation for ontology-backed example terms so
#   unrelated but syntactically valid identifiers are caught automatically."
#
# WHAT IT DOES
#   Finds (CURIE, label) pairs in a source tree, resolves each CURIE against
#   EBI OLS4, and classifies each pair:
#     MISMATCH   — CURIE resolves, to a DIFFERENT label than the one written
#     UNRESOLVED — lookup failed / term not found / prefix not in OLS4
#                  This is CANNOT-DETERMINE. It is never folded into OK.
#     OBSOLETE   — resolves and matches, but the term is deprecated (warning)
#     OK         — written label matches the current ontology label, or an
#                  exact synonym of it (SYNONYM is reported distinctly)
#
# EXIT CODES  (precedence: 2 > 3 > 1 > 4 > 0)
#   0  every pair checked and clean (>=1 pair scanned, no MISMATCH, no UNRESOLVED)
#   1  at least one MISMATCH            <- the #451 defect class
#   2  usage / environment error (no python3, bad path, bad option)
#   3  EMPTY SCAN — zero pairs found. UNKNOWABLE, not clean.
#   4  no MISMATCH but at least one UNRESOLVED — CANNOT-DETERMINE
#      (--tolerate-unresolved downgrades 4 to 0; the pairs are still printed
#       as UNRESOLVED, they are never reprinted or recounted as OK)
#
# FAIL-CLOSED
#   A network failure, an HTTP error, an unparseable response, an unknown
#   prefix, and an empty scan all have their own spelling. None of them can
#   ever be mistaken for "I checked and it is fine".
#
# DATA CLASS
#   Reads source trees only. No patient-derived data. Network egress is to
#   EBI OLS4 (https://www.ebi.ac.uk/ols4/api), a free public read-only API:
#   no credentials, no cost.
#
# READ-ONLY
#   Never writes into the tree it scans.

set -uo pipefail
# NOTE: no `set -e`. And deliberately no `grep -q` on any pipe anywhere in this
# file or its selftest: grep exits at the first match, the producer takes
# SIGPIPE, and under `pipefail` a genuine match reads as a failure. This repo
# has fixed that same bug four times. Write to a file, then scan the file.

VERSION="1.0.0"

usage() {
  cat >&2 <<'USAGE'
usage: ontology-term-validate.sh [options] <path> [<path>...]

  <path>                  file or directory to scan (paths are reported
                          relative to the scan root, so no host paths leak)

options:
  --json <file>           also write a machine-readable JSON report
  --offline-map <file>    resolve from a local TSV (CURIE<TAB>label[<TAB>synonym|...])
                          instead of the network. Hermetic; used by the selftest.
  --no-network            make every lookup fail. Proves fail-closed behaviour.
  --tolerate-unresolved   downgrade exit 4 to 0. UNRESOLVED pairs are still
                          printed and counted as UNRESOLVED.
  --timeout <seconds>     per-request timeout (default 25)
  --version               print version and exit
  -h, --help              this text
USAGE
}

JSON_OUT=""
OFFLINE_MAP=""
NO_NETWORK=0
TOLERATE=0
TIMEOUT=25
ROOTS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --json)                 JSON_OUT="${2:-}"; shift 2 || { usage; exit 2; } ;;
    --offline-map)          OFFLINE_MAP="${2:-}"; shift 2 || { usage; exit 2; } ;;
    --no-network)           NO_NETWORK=1; shift ;;
    --tolerate-unresolved)  TOLERATE=1; shift ;;
    --timeout)              TIMEOUT="${2:-}"; shift 2 || { usage; exit 2; } ;;
    --version)              echo "ontology-term-validate ${VERSION}"; exit 0 ;;
    -h|--help)              usage; exit 0 ;;
    --*)                    echo "ontology-term-validate: unknown option: $1" >&2; usage; exit 2 ;;
    *)                      ROOTS+=("$1"); shift ;;
  esac
done

if [ "${#ROOTS[@]}" -eq 0 ]; then usage; exit 2; fi
command -v python3 >/dev/null 2>&1 || { echo "ontology-term-validate: python3 not found" >&2; exit 2; }
for r in "${ROOTS[@]}"; do
  [ -e "$r" ] || { echo "ontology-term-validate: no such path: $r" >&2; exit 2; }
done

# A bad --timeout is a USAGE error (exit 2). Left to Python it raised an
# uncaught ValueError and exited 1, which this tool reserves for MISMATCH.
if ! [[ "${TIMEOUT}" =~ ^[0-9]+([.][0-9]+)?$ ]] || ! awk -v t="${TIMEOUT}" 'BEGIN { exit !(t > 0) }'; then
  echo "ontology-term-validate: --timeout must be a positive number of seconds, got: '${TIMEOUT}'" >&2
  usage; exit 2
fi

if [ -n "${OFFLINE_MAP}" ] && [ ! -f "${OFFLINE_MAP}" ]; then
  echo "ontology-term-validate: --offline-map file not found: ${OFFLINE_MAP}" >&2; exit 2
fi

export OTV_VERSION="${VERSION}"
export OTV_JSON="${JSON_OUT}"
export OTV_OFFLINE_MAP="${OFFLINE_MAP}"
export OTV_NO_NETWORK="${NO_NETWORK}"
export OTV_TOLERATE="${TOLERATE}"
export OTV_TIMEOUT="${TIMEOUT}"

python3 - "${ROOTS[@]}" <<'PY'
import json, os, re, sys, time, urllib.error, urllib.parse, urllib.request

VERSION      = os.environ["OTV_VERSION"]
JSON_OUT     = os.environ.get("OTV_JSON") or ""
OFFLINE_MAP  = os.environ.get("OTV_OFFLINE_MAP") or ""
NO_NETWORK   = os.environ.get("OTV_NO_NETWORK") == "1"
TOLERATE     = os.environ.get("OTV_TOLERATE") == "1"
TIMEOUT      = float(os.environ.get("OTV_TIMEOUT") or 25)
OLS_BASE     = "https://www.ebi.ac.uk/ols4/api"

EXIT_OK, EXIT_MISMATCH, EXIT_USAGE, EXIT_EMPTY, EXIT_UNRESOLVED = 0, 1, 2, 3, 4

# --json is opened BEFORE anything is printed, and written BEFORE the VERDICT
# line. An unwritable path used to print "VERDICT OK — exit 0", then throw,
# then exit 1: the report and the exit code disagreed. Now it is exit 2, with
# no VERDICT line at all.
JSON_FH = None
if JSON_OUT:
    try:
        JSON_FH = open(JSON_OUT, "w", encoding="utf-8")
    except OSError as e:
        sys.stderr.write("ontology-term-validate: cannot write --json file %s: %s\n"
                         % (JSON_OUT, e.strerror or type(e).__name__))
        sys.exit(EXIT_USAGE)


def write_json(obj, **kw):
    if JSON_FH is None:
        return
    try:
        json.dump(obj, JSON_FH, **kw)
        JSON_FH.close()
    except (OSError, TypeError, ValueError) as e:
        sys.stderr.write("ontology-term-validate: failed writing --json file %s: %s\n"
                         % (JSON_OUT, type(e).__name__))
        sys.stderr.write("ontology-term-validate: no VERDICT issued — exit %d\n" % EXIT_USAGE)
        sys.exit(EXIT_USAGE)

# ── prefixes we know how to resolve ──────────────────────────────────────────
# Curated on purpose. A pair whose prefix is NOT here is reported as UNRESOLVED
# (reason=unknown-prefix) — visible, never silently dropped, never counted OK.
# value = OLS4 ontology id; None = "same as lowercased prefix".
PREFIX_ONTOLOGY = {
    "HP": "hp", "MONDO": "mondo", "NCIT": "ncit", "UBERON": "uberon",
    "EFO": "efo", "GENO": "geno", "SO": "so", "ECO": "eco", "CHEBI": "chebi",
    "CL": "cl", "PATO": "pato", "UO": "uo", "MAXO": "maxo", "GO": "go",
    "MP": "mp", "DOID": "doid", "NCBITAXON": "ncbitaxon", "SNOMED": "snomed",
    "OBI": "obi", "OGMS": "ogms", "VO": "vo",
    "ORDO": "ordo", "OMIT": "omit", "SYMP": "symp", "HANCESTRO": "hancestro",
    "CHMO": "chmo", "IAO": "iao", "BFO": "bfo", "RO": "ro", "OPMI": "opmi",
    "BTO": "bto", "CMO": "cmo", "SCTID": "snomed", "OBA": "oba", "FMA": "fma",
    "MMO": "mmo", "VT": "vt", "ZP": "zp", "XAO": "xao", "OGG": "ogg",
}
# Some prefixes are written one way and indexed in OLS4 under another.
CURIE_PREFIX_ALIAS = {"SCTID": "SNOMED", "NCBITAXON": "NCBITaxon"}
FILE_EXTS = (".java", ".rst", ".yaml", ".yml", ".json", ".md", ".txt", ".py",
             ".proto", ".kt", ".ts", ".js")
SKIP_DIRS = {".git", "target", "build", "node_modules", ".gradle", ".idea",
             "__pycache__", ".mvn", "dist", "venv", ".venv"}

CURIE_RE = r"[A-Za-z][A-Za-z0-9]*[:_][A-Za-z0-9][A-Za-z0-9\.\-]*"

# Java:  ontologyClass("NCIT:C5189", "Radical Cystoprostatectomy")
RE_ONTCLASS = re.compile(r'\(\s*"(' + CURIE_RE + r')"\s*,\s*"([^"]{1,200})"\s*\)')
# Java builder: .setId("X") ... .setLabel("Y")
RE_SETIDLBL = re.compile(r'setId\(\s*"(' + CURIE_RE + r')"\s*\)'
                         r'(?:\s*\.\s*)?\s*\.?\s*setLabel\(\s*"([^"]{1,200})"\s*\)')
# YAML / RST literal blocks:  id: "NCIT:C5189"  then a nearby  label: "..."
RE_YAML_ID  = re.compile(r'^\s*["\']?id["\']?\s*:\s*["\']?(' + CURIE_RE + r')["\']?\s*,?\s*$')
RE_YAML_LBL = re.compile(r'^\s*["\']?label["\']?\s*:\s*["\']?(.*?)["\']?\s*,?\s*$')

_ID_TOKEN_RE = re.compile(r'"(' + CURIE_RE + r')"')


def norm(s):
    return re.sub(r"[^a-z0-9]", "", (s or "").lower())


def iter_files(roots):
    seen = []
    for root in roots:
        if os.path.isfile(root):
            seen.append((os.path.dirname(os.path.abspath(root)) or ".", root))
            continue
        base = os.path.abspath(root)
        for dirpath, dirnames, filenames in os.walk(base):
            dirnames[:] = sorted(d for d in dirnames if d not in SKIP_DIRS)
            for fn in sorted(filenames):
                if fn.endswith(FILE_EXTS):
                    seen.append((base, os.path.join(dirpath, fn)))
    return seen


def extract_json(path, text, rel, out):
    """JSON is parsed STRUCTURALLY, never by regex.

    A Java-shaped regex ("id", next quoted string) applied to JSON matches the
    KEY "label" instead of its value and invents mismatches wholesale. Don't.
    """
    try:
        doc = json.loads(text)
    except Exception:
        return False
    lines = text.splitlines()

    def lineno_for(curie):
        for i, ln in enumerate(lines, 1):
            if curie in ln:
                return i
        return 0

    def walk(o):
        if isinstance(o, dict):
            i, l = o.get("id"), o.get("label")
            if isinstance(i, str) and isinstance(l, str) and re.fullmatch(CURIE_RE, i):
                out.append((i.replace("_", ":"), l.strip(), rel, lineno_for(i)))
            for v in o.values():
                walk(v)
        elif isinstance(o, list):
            for v in o:
                walk(v)

    walk(doc)
    return True


def extract(files):
    pairs = []          # (curie, label, relpath, lineno)
    id_tokens = set()   # every CURIE-shaped token seen, for the blind-spot count
    read = 0
    for base, path in files:
        try:
            with open(path, encoding="utf-8", errors="replace") as fh:
                text = fh.read()
        except Exception:
            continue
        read += 1
        rel = os.path.relpath(os.path.abspath(path), base)
        for m in _ID_TOKEN_RE.finditer(text):
            id_tokens.add(m.group(1).replace("_", ":"))

        if path.endswith(".json") and extract_json(path, text, rel, pairs):
            continue

        lines = text.splitlines()
        for idx, line in enumerate(lines):
            for rx in (RE_ONTCLASS, RE_SETIDLBL):
                for m in rx.finditer(line):
                    lbl = m.group(2).strip()
                    if lbl and lbl not in ("label", "id", "type"):
                        pairs.append((m.group(1).replace("_", ":"), lbl, rel, idx + 1))
            mi = RE_YAML_ID.match(line)
            if mi:
                # Pair `id:` with a `label:` at the SAME indentation, within 3
                # lines, and stop at any other `id:` at that indent. Without the
                # indentation guard the scan walks out of its own mapping and
                # borrows a sibling block's label — e.g. in docs/evidence.rst it
                # paired `id: "PMID:30962759"` (whose sibling key is
                # `description:`, not `label:`) with the ECO label two lines up.
                ind = len(line) - len(line.lstrip())
                found = None
                for direction in (1, -1):
                    for step in range(1, 4):
                        j = idx + direction * step
                        if not (0 <= j < len(lines)):
                            break
                        cand = lines[j]
                        if not cand.strip():
                            continue
                        if len(cand) - len(cand.lstrip()) != ind:
                            break
                        if RE_YAML_ID.match(cand):
                            break
                        ml = RE_YAML_LBL.match(cand)
                        if ml and ml.group(1).strip():
                            found = ml.group(1).strip()
                            break
                    if found:
                        break
                if found:
                    pairs.append((mi.group(1).replace("_", ":"), found, rel, idx + 1))

    # multi-line Java: setId(...) on one line, setLabel(...) on the next
    for base, path in files:
        if not path.endswith(".java"):
            continue
        try:
            with open(path, encoding="utf-8", errors="replace") as fh:
                text = fh.read()
        except Exception:
            continue
        rel = os.path.relpath(os.path.abspath(path), base)
        flat = re.sub(r"\s+", " ", text)
        for m in RE_SETIDLBL.finditer(flat):
            pairs.append((m.group(1).replace("_", ":"), m.group(2).strip(), rel, 0))

    # Dedup per (CURIE, label, FILE) — NOT per (CURIE, label). The same wrong
    # pair appearing in four files is four sites to fix, and issue #451 names
    # four affected locations; collapsing them to one would hide three of them.
    dedup = {}
    for c, l, f, n in pairs:
        key = (c, l, f)
        prev = dedup.get(key)
        if prev is None or (prev[3] == 0 and n > 0):
            dedup[key] = (c, l, f, n)
    return sorted(dedup.values()), id_tokens, read


# ── resolution ───────────────────────────────────────────────────────────────
_CACHE = {}          # CURIE -> (status, label, synonyms, detail)  — per-run cache
_LOOKUPS = [0]


def load_offline_map(path):
    m = {}
    with open(path, encoding="utf-8") as fh:
        for raw in fh:
            raw = raw.rstrip("\n")
            if not raw.strip() or raw.lstrip().startswith("#"):
                continue
            parts = raw.split("\t")
            curie = parts[0].strip()
            label = parts[1].strip() if len(parts) > 1 else ""
            syns = [s for s in (parts[2].split("|") if len(parts) > 2 else []) if s]
            if label == "__NOTFOUND__":
                m[curie] = ("NOTFOUND", "", [], "term-not-found")
            elif label == "__ERROR__":
                m[curie] = ("ERROR", "", [], "simulated-lookup-failure")
            else:
                m[curie] = ("FOUND", label, syns, "")
    return m


OFFLINE = load_offline_map(OFFLINE_MAP) if OFFLINE_MAP else None


def resolve(curie):
    if curie in _CACHE:
        return _CACHE[curie]
    res = _resolve_uncached(curie)
    _CACHE[curie] = res
    return res


def _resolve_uncached(curie):
    prefix = curie.split(":", 1)[0]
    if prefix.upper() not in PREFIX_ONTOLOGY:
        return ("UNRESOLVED", "", [], "unknown-prefix:%s" % prefix)
    if OFFLINE is not None:
        hit = OFFLINE.get(curie)
        if hit is None:
            return ("UNRESOLVED", "", [], "not-in-offline-map")
        if hit[0] == "NOTFOUND":
            return ("UNRESOLVED", "", [], "term-not-found-in-ols4")
        if hit[0] == "ERROR":
            return ("UNRESOLVED", "", [], "simulated-lookup-failure")
        return ("FOUND", hit[1], hit[2], "offline-map")
    if NO_NETWORK:
        return ("UNRESOLVED", "", [], "network-disabled")

    ont = PREFIX_ONTOLOGY[prefix.upper()] or prefix.lower()
    local = curie.split(":", 1)[1]
    lookup_curie = "%s:%s" % (CURIE_PREFIX_ALIAS.get(prefix.upper(), prefix), local)
    url = "%s/ontologies/%s/terms?obo_id=%s" % (
        OLS_BASE, ont, urllib.parse.quote(lookup_curie, safe=""))
    _LOOKUPS[0] += 1
    if _LOOKUPS[0] % 10 == 0:
        time.sleep(0.4)                       # be polite to a free public API
    try:
        req = urllib.request.Request(
            url, headers={"User-Agent": "ontology-term-validate/%s" % VERSION})
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            body = json.load(r)
    except urllib.error.HTTPError as e:
        # 404 from OLS4 means "no such term", which is a determinate negative;
        # every other HTTP status is an indeterminate lookup failure. Both are
        # UNRESOLVED — they are only spelled differently so the reader can tell
        # a missing term from a broken service.
        if e.code == 404:
            return ("UNRESOLVED", "", [], "term-not-found-in-ols4")
        return ("UNRESOLVED", "", [], "lookup-failed:HTTP%s" % e.code)
    except Exception as e:
        return ("UNRESOLVED", "", [], "lookup-failed:%s" % type(e).__name__)
    try:
        terms = body.get("_embedded", {}).get("terms", [])
    except Exception:
        return ("UNRESOLVED", "", [], "unparseable-response")
    if not terms:
        return ("UNRESOLVED", "", [], "term-not-found-in-ols4")
    defining = [t for t in terms if t.get("is_defining_ontology")] or terms
    t = defining[0]
    lbl = t.get("label") or ""
    if not lbl:
        return ("UNRESOLVED", "", [], "term-has-no-label")
    syns = [s for s in (t.get("synonyms") or []) if isinstance(s, str)]
    return (("OBSOLETE" if t.get("is_obsolete") else "FOUND"), lbl, syns, ont)


# ── main ─────────────────────────────────────────────────────────────────────
roots = sys.argv[1:]
files = iter_files(roots)
pairs, id_tokens, files_read = extract(files)

src = ("offline-map" if OFFLINE is not None
       else ("disabled(--no-network)" if NO_NETWORK else OLS_BASE))
print("ontology-term-validate %s" % VERSION)
print("scan roots     : %d" % len(roots))
print("files read     : %d" % files_read)
print("pairs found    : %d" % len(pairs))
print("distinct CURIEs: %d" % len({p[0] for p in pairs}))
print("resolver       : %s" % src)
print("")

if not pairs:
    print("EMPTY SCAN — zero (CURIE, label) pairs were found.")
    print("This is UNKNOWABLE, not clean: an empty scan proves nothing about the")
    print("tree. Check the scan root, the file extensions, and the extractors.")
    print("")
    print("SUMMARY ok=0 synonym=0 mismatch=0 unresolved=0 obsolete=0 pairs=0")
    sys.stdout.flush()
    write_json({"version": VERSION, "verdict": "EMPTY-SCAN", "pairs": [],
                "counts": {"ok": 0, "synonym": 0, "mismatch": 0,
                           "unresolved": 0, "obsolete": 0}}, indent=2)
    print("VERDICT EMPTY-SCAN (UNKNOWABLE) — exit %d" % EXIT_EMPTY)
    sys.exit(EXIT_EMPTY)

rows = []
for curie, label, rel, lineno in pairs:
    status, cur, syns, detail = resolve(curie)
    if status == "UNRESOLVED":
        verdict, note = "UNRESOLVED", detail
    elif norm(cur) == norm(label):
        verdict = "OBSOLETE" if status == "OBSOLETE" else "OK"
        note = detail
    elif any(norm(s) == norm(label) for s in syns):
        verdict, note = "SYNONYM", "exact synonym of %r" % cur
    else:
        verdict, note = "MISMATCH", detail
    rows.append({"curie": curie, "written": label, "ontology": cur,
                 "verdict": verdict, "note": note, "file": rel, "line": lineno})

rows.sort(key=lambda r: (r["verdict"], r["curie"], r["file"], r["line"]))
c = {k: 0 for k in ("OK", "SYNONYM", "MISMATCH", "UNRESOLVED", "OBSOLETE")}
for r in rows:
    c[r["verdict"]] += 1


def block(title, verdict, fmt):
    sel = [r for r in rows if r["verdict"] == verdict]
    if not sel:
        return
    print("%s (%d):" % (title, len(sel)))
    for r in sel:
        print(fmt(r))
        print("      at %s:%s" % (r["file"], r["line"] or "?"))
    print("")


block("MISMATCH — CURIE resolves to a DIFFERENT term than the label written",
      "MISMATCH",
      lambda r: '  %s  written=%r  ontology=%r' % (r["curie"], r["written"], r["ontology"]))
block("UNRESOLVED — CANNOT-DETERMINE (this is NOT a pass)", "UNRESOLVED",
      lambda r: '  %s  written=%r  reason=%s' % (r["curie"], r["written"], r["note"]))
block("OBSOLETE — label matches, but the term is deprecated (warning, non-gating)",
      "OBSOLETE",
      lambda r: '  %s  written=%r' % (r["curie"], r["written"]))

unknown_prefixes = sorted({t.split(":", 1)[0] for t in id_tokens
                           if t.split(":", 1)[0].upper() not in PREFIX_ONTOLOGY})
if unknown_prefixes:
    print("BLIND SPOT — CURIE-shaped tokens with prefixes this tool cannot resolve:")
    print("  %s" % ", ".join(unknown_prefixes[:40]))
    print("  (tokens of these prefixes that were paired with a label appear above")
    print("   as UNRESOLVED/unknown-prefix; unpaired ones were never checked)")
    print("")

print("SUMMARY ok=%d synonym=%d mismatch=%d unresolved=%d obsolete=%d pairs=%d"
      % (c["OK"], c["SYNONYM"], c["MISMATCH"], c["UNRESOLVED"], c["OBSOLETE"], len(rows)))

if c["MISMATCH"]:
    code, verdict = EXIT_MISMATCH, "MISMATCH"
elif c["UNRESOLVED"]:
    if TOLERATE:
        code, verdict = EXIT_OK, "OK-WITH-UNRESOLVED (--tolerate-unresolved)"
    else:
        code, verdict = EXIT_UNRESOLVED, "CANNOT-DETERMINE"
else:
    code, verdict = EXIT_OK, "OK"
sys.stdout.flush()
write_json({"version": VERSION, "verdict": verdict, "exit": code,
            "resolver": src,
            "counts": {"ok": c["OK"], "synonym": c["SYNONYM"],
                       "mismatch": c["MISMATCH"],
                       "unresolved": c["UNRESOLVED"],
                       "obsolete": c["OBSOLETE"], "pairs": len(rows)},
            "rows": rows}, indent=2, sort_keys=True)
print("VERDICT %s — exit %d" % (verdict, code))
sys.exit(code)
PY
