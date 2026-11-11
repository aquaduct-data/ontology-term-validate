#!/usr/bin/env bash
# ontology-term-validate — identifier/label validation for ontology-backed terms.
#
#   ontology-term-validate.sh [options] <path> [<path>...]
#
# WHY THIS EXISTS
#   ga4gh/phenopacket-schema#451: the urothelial-carcinoma example wrote
#   `ontologyClass("NCIT:C5189", "Radical Cystoprostatectomy")`. NCIT:C5189 is
#   a real, syntactically valid identifier — it just means "Breast Extraskeletal
#   Osteosarcoma". The intended term is NCIT:C51899. Nothing in the build catches
#   that, because the identifier parses and the label is only a string.
#   That issue, filed by cmungall, suggests this check: "It may also be useful
#   to add identifier/label validation for ontology-backed example terms so
#   unrelated but syntactically valid identifiers are caught automatically."
#
# WHAT IT DOES
#   Finds (CURIE, label) pairs in a source tree (Java, Kotlin, Rust, YAML,
#   reStructuredText, JSON and more), resolves each CURIE against
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

VERSION="1.1.0"

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
             ".proto", ".kt", ".ts", ".js", ".rs")
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


# ── Rust ─────────────────────────────────────────────────────────────────────
# Rust source writes terms in shapes none of the extractors above can see, and
# the live phenopacket tooling is Rust. Two extractors, both deliberately narrow.
#
# The identifier here must be COLON form. The underscore form the other
# extractors accept (HP_0001250) would turn every transcript accession in Rust
# source -- "NM_000138.5" -- into a pair with an unknown prefix.
RS_CURIE_RE = r"[A-Za-z][A-Za-z0-9]*:[A-Za-z0-9][A-Za-z0-9\.\-]*"
# A string literal on one line. The lookbehind skips the OPENING quote of raw
# and byte strings (r"..", r#".."#, b".."), so a term written in one is not
# read -- and nothing reports that: the blind-spot section lists unknown
# PREFIXES only. Worse, this is a pattern and not a lexer, so a raw string's
# closing quote, a '"' char literal, or the last line of a multi-line string can
# be taken as an opening quote, and pairs later ON THAT LINE are then lost
# silently. Damage is confined to the line. A real lexer would remove this.
RE_RS_STR = re.compile(r'(?<![A-Za-z0-9_#])"((?:[^"\\\n]|\\.)*)"')
_RS_WRAP = r'(?:&\s*)?(?:(?:Some|String::from)\s*\(\s*)?'
_RS_TAIL = r'(?:\s*\.\s*(?:to_string|to_owned|into)\(\s*\))?\s*\)?'
# What may sit between two literals for them to count as ADJACENT ARGUMENTS:
# an optional .to_string(), an optional closing paren of Some(..), one comma,
# an optional Some( / String::from( / & opener. Nothing else -- not a field
# name, not `).expect(`, not the `), (` between two tuples. That last one is
# what stops a label being borrowed from the neighbouring tuple.
RE_RS_BETWEEN = re.compile(_RS_TAIL + r'\s*,\s*' + _RS_WRAP + r'\Z')
RE_RS_FIELD_ID = re.compile(
    r'(?<![A-Za-z0-9_])([A-Za-z0-9_]*?)_?id\s*:\s*' + _RS_WRAP + r'"(' + RS_CURIE_RE + r')"')

def _rs_label_ok(s):
    s = s.strip()
    return (0 < len(s) <= 200 and re.search(r"[A-Za-z]", s) is not None
            and not re.fullmatch(RS_CURIE_RE, s) and s not in ("label", "id", "type"))


def _rs_inline_span(line, pos):
    """(open, close) of the innermost { .. } around `pos` that both opens and
    closes on this line, or None. Braces are counted as characters, so a brace
    inside a string literal can mislead it; that is a stated limit."""
    depth, start = 0, None
    for i in range(pos, -1, -1):
        ch = line[i]
        if ch == "}":
            depth += 1
        elif ch == "{":
            if depth == 0:
                start = i
                break
            depth -= 1
    if start is None:
        return None
    depth = 0
    for j in range(pos, len(line)):
        ch = line[j]
        if ch == "{":
            depth += 1
        elif ch == "}":
            if depth == 0:
                return (start, j)
            depth -= 1
    return None


def _rs_blank_inline(s):
    """`s` with every balanced { .. } on the line replaced by spaces."""
    out, stack = list(s), []
    for i, ch in enumerate(s):
        if ch == "{":
            stack.append(i)
        elif ch == "}" and stack:
            a = stack.pop()
            if not stack:
                for k in range(a, i + 1):
                    out[k] = " "
    return "".join(out)


# Rust identifiers with a resolvable prefix: every one seen, and every one that
# was paired with a label somewhere in the scan. The difference is printed as
# NOT checked, so a clean verdict is never read as "every identifier was looked
# at". Sets, across the whole scan -- a per-file sum counted the same
# identifier once per file and still called the total "distinct".
RS_SEEN, RS_PAIRED = set(), set()


def _rs_unescape(s):
    return s.replace('\\"', '"').replace("\\\\", "\\")


def extract_rust(text, rel, out):
    """Two shapes, measured on real Rust phenopacket tooling rather than guessed.

    1. Adjacent string-literal arguments, in EITHER order:
           HpoTermData::from_str("HP:0000574", "Thick eyebrow", "excluded")
           HpoTermDuplet::new("Delayed ability to sit", "HP:0025336")
           ("HP:0000006", "Autosomal dominant inheritance"),
           #[case("Y-linked inheritance", "HP:0001450")]
       The literal AFTER the identifier is preferred, matching every other
       extractor here. When there are plausible labels on both sides the order
       is genuinely ambiguous, so the pair passes if EITHER is the term's label
       and is reported against the following one otherwise.
    2. Struct fields sharing a stem: `hpo_id:` with `hpo_label:`, `disease_id:`
       with `disease_label:`, bare `id:` with `label:` -- on the same line, or
       within three lines at the same indentation.
    """
    first_new = len(out)
    starts = [0]
    for m in re.finditer(r"\n", text):
        starts.append(m.end())

    def lineno(off):
        lo, hi = 0, len(starts) - 1
        while lo < hi:
            mid = (lo + hi + 1) // 2
            if starts[mid] <= off:
                lo = mid
            else:
                hi = mid - 1
        return lo + 1

    toks = [(m.start(), m.end(), _rs_unescape(m.group(1))) for m in RE_RS_STR.finditer(text)]

    def adjacent(i, j):
        return RE_RS_BETWEEN.match(text[toks[i][1]:toks[j][0]]) is not None

    # A CHAIN is a maximal run of adjacent literals: one argument list, one
    # tuple, one flat array. Order is decided per chain, never per file.
    chains, cur = [], []
    for i in range(len(toks)):
        if cur and not adjacent(cur[-1], i):
            chains.append(cur); cur = []
        cur.append(i)
    if cur:
        chains.append(cur)

    for chain in chains:
        vals = [toks[i][2] for i in chain]
        is_id = [re.fullmatch(RS_CURIE_RE, v) is not None for v in vals]
        if not any(is_id):
            continue
        n = len(chain)
        alternating = n % 2 == 0 and all(is_id[k] != is_id[k + 1] for k in range(n - 1))
        if alternating:
            # A table. The first literal decides the order for ALL of it:
            #   ["HP:1", "Seizure", "HP:1", "Marfan syndrome"]   identifier first
            #   ["Seizure", "HP:1", "Marfan syndrome", "MONDO:2"] label first
            # Without this, the second identifier of the first table would find
            # "Seizure" on its other side and be excused -- a real mismatch
            # reported clean. Found in independent review before release.
            off = 0 if is_id[0] else 1
            for k in range(0, n, 2):
                idv, lab = vals[k + off], vals[k + 1 - off]
                if _rs_label_ok(lab):
                    out.append((idv, lab.strip(), rel, lineno(toks[chain[k + off]][0]), None))
            continue
        # Not a table: each identifier takes the literal AFTER it. A literal
        # already taken that way is never offered again as someone's "other side".
        taken = set()
        for k in range(n):
            if is_id[k] and k + 1 < n and not is_id[k + 1] and _rs_label_ok(vals[k + 1]):
                taken.add(k + 1)
        for k in range(n):
            if not is_id[k]:
                continue
            nxt = vals[k + 1].strip() if (k + 1) in taken else None
            prv = (vals[k - 1].strip() if k > 0 and not is_id[k - 1] and (k - 1) not in taken
                   and _rs_label_ok(vals[k - 1]) else None)
            line_no = lineno(toks[chain[k]][0])
            if nxt is not None:
                # `prv` rides on THIS occurrence only. It used to be stored per
                # (identifier, label, file), which let one ambiguous call excuse
                # an unambiguous mismatch elsewhere in the same file.
                out.append((vals[k], nxt, rel, line_no, prv))
            elif prv is not None:
                out.append((vals[k], prv, rel, line_no, None))

    lines = text.splitlines()
    for idx, line in enumerate(lines):
        for m in RE_RS_FIELD_ID.finditer(line):
            stem, curie = m.group(1), m.group(2)
            pat = re.escape(stem) + (r'_?' if stem else r'')
            rx = re.compile(r'(?<![A-Za-z0-9_])' + pat + r'label\s*:\s*' + _RS_WRAP
                            + r'"((?:[^"\\]|\\.)*)"')
            rx_lead_id = re.compile(r'(?:pub\s+)?' + pat + r'id\s*:')

            def label_in(s):
                ml = rx.search(s)
                if ml and _rs_label_ok(_rs_unescape(ml.group(1))):
                    return _rs_unescape(ml.group(1)).strip()
                return None

            found = None
            span = _rs_inline_span(line, m.start())
            if span is not None:
                # An inline struct -- `Ref { id: "..", label: ".." }`, opened and
                # closed on this line -- keeps its fields to itself. It never
                # looks at another line, and structs nested inside it are
                # blanked so their labels are not read as its own.
                inner = line[span[0] + 1:span[1]]
                found = label_in(_rs_blank_inline(inner))
            else:
                found = label_in(_rs_blank_inline(line))
                if found is None:
                    ind = len(line) - len(line.lstrip())
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
                            # Inline structs on a neighbouring line are blanked
                            # first: neither their label nor their id is ours.
                            flat = _rs_blank_inline(cand)
                            # A line that LEADS with an id of the same stem is a
                            # sibling and owns what follows. An id nested inside
                            # an inline struct further along the line is not a
                            # sibling -- stopping there dropped the outer pair
                            # and let the nested id take the outer label, a real
                            # mismatch reported clean. Found in review too.
                            if rx_lead_id.match(flat.lstrip()):
                                break
                            found = label_in(flat)
                            if found:
                                break
                        if found:
                            break
            if found:
                out.append((curie, found, rel, idx + 1, None))

    RS_PAIRED.update(row[0] for row in out[first_new:])
    RS_SEEN.update(v for _, _, v in toks
                   if re.fullmatch(RS_CURIE_RE, v) and v.split(":", 1)[0].upper() in PREFIX_ONTOLOGY)


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
        if path.endswith(".rs"):
            # Rust gets ONLY the Rust extractors. The Java-shaped patterns below
            # accept underscore identifiers, which in Rust source are accessions.
            extract_rust(text, rel, pairs)
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
    # A fifth field, used by the Rust extractor only: the literal on the OTHER
    # side of an identifier whose order is ambiguous. It is part of the key, so
    # an ambiguous occurrence and an unambiguous one never merge.
    dedup = {}
    for row in pairs:
        c, l, f, n = row[:4]
        alt = row[4] if len(row) > 4 else None
        key = (c, l, f, alt)
        prev = dedup.get(key)
        if prev is None or (prev[3] == 0 and n > 0):
            dedup[key] = (c, l, f, n, alt)
    return sorted(dedup.values(), key=lambda r: (r[0], r[1], r[2], r[3], r[4] or "")), id_tokens, read


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
_unl = len(RS_SEEN - RS_PAIRED)
if _unl:
    print("unlabelled ids : %d distinct Rust identifier%s with no label beside %s — NOT checked"
          % (_unl, "" if _unl == 1 else "s", "it" if _unl == 1 else "them"))
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
for curie, label, rel, lineno, alt in pairs:
    status, cur, syns, detail = resolve(curie)

    def judge(written):
        if status == "UNRESOLVED":
            return "UNRESOLVED", detail
        if norm(cur) == norm(written):
            return ("OBSOLETE" if status == "OBSOLETE" else "OK"), detail
        if any(norm(s) == norm(written) for s in syns):
            return "SYNONYM", "exact synonym of %r" % cur
        return "MISMATCH", detail

    verdict, note = judge(label)
    if verdict == "MISMATCH" and alt is not None:
        # A label sat on BOTH sides of THIS occurrence. Order is not knowable
        # from syntax, so it passes if either one is the term's label.
        v2, n2 = judge(alt)
        if v2 != "MISMATCH":
            label, verdict, note = alt, v2, n2
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
