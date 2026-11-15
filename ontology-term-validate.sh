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
# SIGPIPE, and under `pipefail` a genuine match reads as a failure. That bug
# has been made and fixed more than once. Write to a file, then scan the file.

VERSION="1.3.0"

usage() {
  cat >&2 <<'USAGE'
usage: ontology-term-validate.sh [options] <path> [<path>...]

  <path>                  file or directory to scan (paths are reported
                          relative to the scan root, so no host paths leak)

options:
  --json <file>           also write a machine-readable JSON report
  --offline-map <file>    resolve from a local TSV (CURIE<TAB>label[<TAB>synonym|...[<TAB>obsolete]])
                          a 4th column reading `obsolete` sets the term's OLS4 is_obsolete flag
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
import bisect, json, os, re, sys, time, urllib.error, urllib.parse, urllib.request

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
    # Food, environment, microbiology, plants and ecology. Added after a run on a
    # culture-media knowledge base left 2,795 pairs unjudged for want of them.
    # Each was read back from OLS4 as a served ontology before being added.
    "FOODON": "foodon", "ENVO": "envo", "MICRO": "micro", "PO": "po",
    "AGRO": "agro", "PCO": "pco", "ECOCORE": "ecocore",
}
# Some prefixes are written one way and indexed in OLS4 under another.
CURIE_PREFIX_ALIAS = {"SCTID": "SNOMED", "NCBITAXON": "NCBITaxon"}
FILE_EXTS = (".java", ".rst", ".yaml", ".yml", ".json", ".md", ".txt", ".py",
             ".proto", ".kt", ".ts", ".js", ".rs", ".tsx", ".jsx", ".mjs", ".cjs",
             ".mts", ".cts", ".mdx", ".markdown")
SKIP_DIRS = {".git", "target", "build", "node_modules", ".gradle", ".idea",
             "__pycache__", ".mvn", "dist", "venv", ".venv"}

CURIE_RE = r"[A-Za-z][A-Za-z0-9]*[:_][A-Za-z0-9][A-Za-z0-9\.\-]*"

# Java:  ontologyClass("NCIT:C5189", "Radical Cystoprostatectomy")
RE_ONTCLASS = re.compile(r'\(\s*"(' + CURIE_RE + r')"\s*,\s*"([^"]{1,200})"\s*\)')
# Java builder: .setId("X") ... .setLabel("Y")
RE_SETIDLBL = re.compile(r'setId\(\s*"(' + CURIE_RE + r')"\s*\)'
                         r'(?:\s*\.\s*)?\s*\.?\s*setLabel\(\s*"([^"]{1,200})"\s*\)')
# YAML / RST literal blocks:  id: "NCIT:C5189"  then a nearby  label: "..."
# The key may be the first of a list item:  - id: "NCIT:C5189". That is the
# commonest YAML layout, and it was not read at all until a real file showed it
# (one public knowledge graph's source: 32,783 `- id:` lines against 225 plain ones).
RE_YAML_ID  = re.compile(r'^\s*(?:-\s+)?["\']?id["\']?\s*:\s*["\']?(' + CURIE_RE + r')["\']?\s*,?\s*$')
RE_YAML_LBL = re.compile(r'^\s*(?:-\s+)?["\']?label["\']?\s*:\s*(.*?)\s*$')
RE_YAML_NAME = re.compile(r'^\s*(?:-\s+)?["\']?name["\']?\s*:\s*(.*?)\s*$')
RE_YAML_ITEM_KEY = re.compile(r'^(\s*)-(\s+)["\']?[A-Za-z_][A-Za-z0-9_\-]*["\']?\s*:(?:\s|$)')
_YAML_DQ = re.compile(r'"((?:[^"\\]|\\.)*)"\s*,?\s*(?:#.*)?')
_YAML_SQ = re.compile(r"'((?:[^']|'')*)'\s*,?\s*(?:#.*)?")
_YAML_ESC = re.compile(r'\\(?:u([0-9A-Fa-f]{4})|U([0-9A-Fa-f]{8})|x([0-9A-Fa-f]{2})|(.))')
_YAML_ESC_CHAR = {"n": "\n", "t": "\t", "r": "\r", "0": "\0", " ": " ", "/": "/", '"': '"', "\\": "\\", "_": "\u00a0"}


def _yaml_scalar(v):
    """The value written after `key:`, as YAML reads it for the three plain cases.
    A double-quoted scalar loses its quotes and has its escapes decoded (\\u03B1
    is one character, not six); a single-quoted one loses its quotes and reads ''
    as one apostrophe; a comment after either is not part of the value. Anything
    else is left as the reader always left it: one stray quote and a trailing
    comma removed, nothing more."""
    m = _YAML_DQ.fullmatch(v)
    if m:
        def one(e):
            code = e.group(1) or e.group(2) or e.group(3)
            if code:
                try:
                    return chr(int(code, 16))
                except (ValueError, OverflowError):
                    return e.group(0)
            return _YAML_ESC_CHAR.get(e.group(4), e.group(0))
        return _YAML_ESC.sub(one, m.group(1))
    m = _YAML_SQ.fullmatch(v)
    if m:
        return m.group(1).replace("''", "'")
    return re.sub(r'^["\']?(.*?)["\']?\s*,?\s*$', r"\1", v)


def _yaml_key_col(line):
    """-> (column where the mapping's keys start, whether this line opens a list
    item). `-   id: X` has its keys at the column of `id`, and the keys that
    follow it sit at that column with no dash. A dash before a plain scalar
    (`- levonordefrin`) is not a key line; its indentation is what it looks like."""
    m = RE_YAML_ITEM_KEY.match(line)
    if m:
        return len(m.group(1)) + 1 + len(m.group(2)), True
    return len(line) - len(line.lstrip()), False


def _yaml_sibling(lines, idx, rx):
    """The value of the key `rx` reads, in the SAME mapping as the `id:` at
    lines[idx]: at the same key column, within 3 lines, after it first and then
    before it. Stops at another `id:`, at a line that starts another list item,
    and at any line at a different column. An `id:` that opens a list item is
    its first key, so nothing above it belongs to it."""
    ind, opens = _yaml_key_col(lines[idx])
    for direction in ((1,) if opens else (1, -1)):
        for step in range(1, 4):
            j = idx + direction * step
            if not (0 <= j < len(lines)):
                break
            cand = lines[j]
            if not cand.strip():
                continue
            if cand.strip() in ("---", "..."):
                break                       # another YAML document
            c_ind, c_opens = _yaml_key_col(cand)
            if c_ind != ind or RE_YAML_ID.match(cand):
                break
            if c_opens and direction == 1:
                break                       # the next list item: another mapping
            m = rx.match(cand)
            if m:
                v = _yaml_scalar(m.group(1)).strip()
                if v:
                    return v
            if c_opens:
                break                       # going up: this was the item's first key
    return None
# `label` shaped like a Biolink category: one CamelCase word ("Drug", "BiologicalProcess").
RE_CATEGORY = re.compile(r"[A-Z][a-z0-9]*(?:[A-Z][a-z0-9]*)*")

_ID_TOKEN_RE = re.compile(r'"(' + CURIE_RE + r')"')


def norm(s):
    return re.sub(r"[^a-z0-9]", "", (s or "").lower())


SKIPPED_DIRS = []      # (path relative to its scan root, count of files of a type we read)
LABEL_DEFERRED = [0]   # times a category-shaped `label` gave way to the `name` beside it


def _count_readable(top):
    n = 0
    for _dp, _dn, fns in os.walk(top):
        n += sum(1 for f in fns if f.endswith(FILE_EXTS))
    return n


def iter_files(roots):
    seen = []
    for root in roots:
        if os.path.isfile(root):
            seen.append((os.path.dirname(os.path.abspath(root)) or ".", root))
            continue
        base = os.path.abspath(root)
        for dirpath, dirnames, filenames in os.walk(base):
            # A skipped directory is not read, but it is COUNTED, so the summary
            # can say when it holds files of a type this tool reads (a project
            # may publish its data under build/).
            for d in sorted(d for d in dirnames if d in SKIP_DIRS):
                n = _count_readable(os.path.join(dirpath, d))
                if n:
                    SKIPPED_DIRS.append((os.path.relpath(os.path.join(dirpath, d), base), n))
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
            nm = o.get("name")
            deferred = False
            # `label` beside `name` and shaped like a Biolink category (one
            # CamelCase word: "Drug", "BiologicalProcess") is a category, not
            # the term's name; the name is in `name`. With no `name`, or a
            # `label` that is not category-shaped, `label` is read as before.
            if (isinstance(nm, str) and nm.strip() and isinstance(l, str)
                    and RE_CATEGORY.fullmatch(l.strip())):
                l = nm
                deferred = True
            if isinstance(i, str) and isinstance(l, str) and re.fullmatch(CURIE_RE, i):
                out.append((i.replace("_", ":"), l.strip(), rel, lineno_for(i)))
                if deferred:
                    LABEL_DEFERRED[0] += 1   # only where a pair is made, as the YAML path does
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
# ── Rust string lexer ───────────────────────────────────────────────────────
# Finds the string literals in Rust source the way the compiler does, so a quote
# the old per-line pattern did not model can no longer knock the reader out of
# step. Knows: plain "..." (escapes, multi-line, `\`-continued), raw r"..",
# r#".."#, r##".."## (no escapes), char literals ('"', '\'', '\n', '\u{..}')
# against lifetimes ('a), and line / nested block comments. Byte (b".."), raw
# byte (br".."), and C (c"..", cr"..") strings are SKIPPED, not misread: they
# are bytes, not text, and never become a token. Their SPANS are still recorded,
# with every other literal's, so an identifier inside one is counted (see the
# accounting pass at the end of extract_rust).
#
# Code inside comments is still read, as the other extractors do. Each comment
# is its own context: its strings pair only with each other, and a comment
# between two arguments is blank space to the code around it.
#
# FAIL-LOUD ON LOST SYNC. A quote with no closing quote used to cost one line.
# A lexer that guesses wrong can cost the rest of the file, so an unterminated
# string or block comment is counted in RS_LEX_WARN and printed in the header;
# the stray quote is then skipped and reading resumes after it.
RS_LEX_WARN = []          # "rel:line: what" -- one per place the lexer lost sync
_RS_IDENT = re.compile(r"\w+")   # unicode-aware, to agree with str.isalnum below
# An identifier wherever it sits in text, found by its PREFIX: letters, then a
# colon, then something that can start a local part. A letter or digit before the
# prefix means it is the tail of a longer word (`9HP:1`, `XHP:1`); an underscore
# does not (`term_HP:1`). Nothing is required AFTER the identifier: `HP:1_label`
# is `HP:1` followed by other text, and a lookahead there once made it vanish.
_RS_PREFIX_AT = re.compile(r"(?<![A-Za-z0-9])([A-Za-z][A-Za-z0-9]*):(?=[A-Za-z0-9])")
_RS_LOCAL = re.compile(r"[A-Za-z0-9][A-Za-z0-9\.\-]*")
# The underscore spelling (HP_0001250, and the tail of an OBO PURL). The pairing
# readers refuse it in Rust, because NM_000138.5 is a transcript and not a term,
# so it can never be judged here. It is still an identifier somebody wrote, so it
# is COUNTED, and only when the prefix is spelled exactly as a known ontology's.
# Nothing is required after it: `HP_0001250_label` is counted, as
# `HP:0001250_label` is.
_RS_UNDERSCORE = re.compile(r"(?<![A-Za-z0-9])([A-Za-z]+)_(\d[A-Za-z0-9]*)")
_RS_EXACT_PREFIX = None     # filled on first use: PREFIX_ONTOLOGY keys in their written spelling
_RS_PLAIN = re.compile(r'"[^"\\]*(?:\\.[^"\\]*)*"', re.S)
_RS_COLON = re.compile(r"[ \t\r\n]*:[ \t\r\n]*")
_RS_WS = re.compile(r"[ \t\r\n]*")
_RS_LABEL_KEYS = frozenset(("label", "name", "term", "title", "text", "description", "rdfs:label", "preferredlabel"))
_RS_RAWOPEN = re.compile(r'(#*)"')
_RS_STR_PREFIX_BYTES = ("b", "br", "c", "cr")


def _rs_lex(text, rel="?"):
    """-> (tokens, comment_spans). A token is (start, end, value, ctx, raw): ctx
    0 is code, any other number names the comment the string sits in."""
    toks, spans, kspans, ctx_counter = [], [], [], [0]
    lits = []          # (start, end) of EVERY string literal, any kind: plain, raw, byte, C
    n = len(text)

    lost = []          # offsets where the lexer lost sync (an unclosed string or comment)

    def warn(pos, what):
        lost.append(pos)
        RS_LEX_WARN.append("%s:%d: %s" % (rel, text.count("\n", 0, pos) + 1, what))

    def block_end(i, end):
        """Offset just past the (nested) block comment opening at i, or end."""
        depth, k = 0, i
        while k < end:
            if text.startswith("/*", k):
                depth += 1; k += 2
            elif text.startswith("*/", k):
                depth -= 1; k += 2
                if depth == 0:
                    return k, True
            else:
                k += 1
        return end, False

    def scan(i, end, mode, ctx):
        while i < end:
            ch = text[i]
            if mode == "code" and text.startswith("//", i):
                j = text.find("\n", i, end)
                j = end if j < 0 else j
                ctx_counter[0] += 1
                spans.append((i, j))
                scan(i + 2, j, "line", ctx_counter[0])
                i = j
                continue
            if mode != "line" and text.startswith("/*", i):
                j, closed = block_end(i, end)
                if not closed:
                    warn(i, "block comment never closes")
                ctx_counter[0] += 1
                c = ctx_counter[0]
                if mode == "code":
                    spans.append((i, j))
                scan(i + 2, j - 2 if closed else j, "block", c)
                i = j
                continue
            if ch == "'":
                # char literal or lifetime. '\x' -> closes at the next quote
                # after the escaped character; 'x' -> exactly one char.
                if i + 1 < end and text[i + 1] == "\\":
                    j = text.find("'", i + 3, min(end, i + 14))
                    if j >= 0 and "\n" not in text[i:j]:
                        i = j + 1
                        continue
                elif i + 2 < end and text[i + 1] != "\n" and text[i + 2] == "'":
                    i += 3
                    continue
                i += 1          # a lifetime / label: only the quote itself
                continue
            if ch == '"' or ch == "_" or ch.isalnum():
                kind, k, body_at = "plain", i, None
                if ch != '"':
                    m = _RS_IDENT.match(text, i, end)
                    word = m.group(0)
                    k = m.end()
                    raw = word in ("r", "br", "cr")
                    if raw and k < end:
                        mo = _RS_RAWOPEN.match(text, k, end)
                        if mo:
                            kind, body_at = "raw", mo
                    if kind != "raw":
                        if word in _RS_STR_PREFIX_BYTES and k < end and text[k] == '"':
                            kind = "bytes"
                        else:
                            i = k       # an ordinary identifier or number
                            continue
                    pre = word
                else:
                    pre = ""
                if kind == "raw":
                    hashes = body_at.group(1)
                    close = '"' + hashes
                    j = text.find(close, body_at.end(), end)
                    if j < 0:
                        if mode == "code":
                            warn(i, "raw string never closes")
                        i = body_at.end()
                        continue
                    lits.append((i, j + len(close)))
                    if pre == "r":
                        toks.append((i, j + len(close), text[body_at.end():j], ctx, True))
                        # The quoted strings INSIDE a raw string (an embedded
                        # JSON fixture) are read as candidates too, each blob
                        # in a context of its own, so a wrong pair in it is
                        # reported even when the same identifier is paired
                        # correctly elsewhere. Found in review.
                        ctx_counter[0] += 1
                        rc, p, key = -ctx_counter[0], body_at.end(), None
                        while True:
                            p = text.find('"', p, j)
                            if p < 0:
                                break
                            mm = _RS_PLAIN.match(text, p, j)
                            if not mm:
                                # No closing quote from here to the end of the blob.
                                # Any later quote is reached by this same scan in the
                                # same state, so it fails the same way: stop, rather
                                # than retry from every quote (quadratic on pasted
                                # escaped JSON).
                                break
                            val = _rs_unescape(mm.group(0)[1:-1])
                            colon = _RS_COLON.match(text, mm.end(), j)
                            if colon:
                                # A JSON key is a name, not a label. It is blanked
                                # (with its colon) so `"id": X, "label": Y` reads as
                                # two adjacent literals, and remembered so the value
                                # can be judged by it. Looked at by index: slicing the
                                # rest of the blob per string made big blobs quadratic.
                                kspans.append((p, colon.end()))
                                key = (val.lower(), colon.end())
                                p = colon.end()
                                continue
                            # Under a key, a string is a candidate only if it is an
                            # identifier or the key says it is a label; `"note": "x"`
                            # next to an id is not a pair.
                            if (key is not None and key[1] <= p
                                    and _RS_WS.fullmatch(text, key[1], p)
                                    and key[0] not in _RS_LABEL_KEYS
                                    and not key[0].endswith("label")
                                    and re.fullmatch(RS_CURIE_RE, val) is None):
                                key = None
                                p = mm.end()
                                continue
                            key = None
                            toks.append((p, mm.end(), val, rc, False))
                            p = mm.end()
                    i = j + len(close)
                    continue
                q = k if ch != '"' else i      # offset of the opening quote
                m = _RS_PLAIN.match(text, q, end)
                if not m:
                    if mode == "code":      # prose in a comment may hold a lone quote
                        warn(q, "string never closes")
                    i = q + 1
                    continue
                lits.append((i, m.end()))
                if kind == "plain":
                    toks.append((i, m.end(), _rs_unescape(m.group(0)[1:-1]), ctx, False))
                i = m.end()
                continue
            i += 1

    scan(0, n, "code", 0)
    return toks, spans, kspans, lits, (min(lost) if lost else None)


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
def _ids_in(text, a_, b_, exact):
    """Every identifier with a known prefix written in text[a_:b_].
    -> [(offset, text as written, identifier)]; `written` is None for the
    underscore spelling. exact=True wants the prefix spelled as the ontology
    spells it; False takes any case, which is right inside a string."""
    global _RS_EXACT_PREFIX
    if _RS_EXACT_PREFIX is None:
        _RS_EXACT_PREFIX = set(PREFIX_ONTOLOGY) | set(CURIE_PREFIX_ALIAS.values())
    heads = [m for m in _RS_PREFIX_AT.finditer(text, a_, b_)
             if (m.group(1) in _RS_EXACT_PREFIX if exact else m.group(1).upper() in PREFIX_ONTOLOGY)]
    found = []
    for n_, m in enumerate(heads):
        end = _RS_LOCAL.match(text, m.end(), b_).end()
        # `HP:1-HP:2` and `HP:1.HP:2`: the local part of the first must not
        # swallow the prefix of the second, or the second is never seen.
        if n_ + 1 < len(heads) and heads[n_ + 1].start() < end:
            end = heads[n_ + 1].start()
        written = text[m.start():end]
        found.append((m.start(), written, written.rstrip(".-")))
    for m in _RS_UNDERSCORE.finditer(text, a_, b_):
        if m.group(1) in _RS_EXACT_PREFIX:
            found.append((m.start(1), None, "%s:%s" % (m.group(1), m.group(2))))
    return found


RS_IDS = {"occurrences": 0, "paired": 0, "unchecked": 0}
RS_OCC = set()      # (file, offset, 0, identifier): one per occurrence NOT paired


_RS_ESC = re.compile(r'\\(?:\r?\n[ \t\r\n]*|(["\\\']))')


def _rs_unescape(s):
    """Backslash-quote, backslash-backslash and backslash-apostrophe lose their
    backslash; a backslash at the end of a line also drops the newline and the
    next line's indentation, as the compiler does. Nothing else is touched."""
    return _RS_ESC.sub(lambda m: m.group(1) or "", s)


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
    paired_off = set()      # offsets of identifier tokens that made a pair
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

    toks, spans, kspans, lits, lost_at = _rs_lex(text, rel)
    # Gaps between code tokens are read from the text with comments blanked, so
    # `"HP:1", /* note */ "Seizure"` is two adjacent arguments. Inside one
    # comment the raw text is used (its own commas are real).
    blank = list(text)
    for a, b in spans:
        for k in range(a, b):
            if blank[k] != "\n":
                blank[k] = " "
    blank = "".join(blank)
    # Inside a raw JSON blob only the KEYS (and their colons) are blanked, never
    # the surrounding comment: a blob in a commented-out line keeps its commas.
    keyblank = list(text)
    for a, b in kspans:
        for k in range(a, b):
            if keyblank[k] != "\n":
                keyblank[k] = " "
    keyblank = "".join(keyblank)

    def adjacent(i, j):
        c = toks[i][3]
        src = text if c > 0 else (keyblank if c < 0 else blank)
        return RE_RS_BETWEEN.match(src[toks[i][1]:toks[j][0]]) is not None

    # A CHAIN is a maximal run of adjacent literals: one argument list, one
    # tuple, one flat array. Order is decided per chain, never per file. Code
    # and each comment chain separately, so a string inside a comment never
    # sits between two arguments.
    chains, cur_by_ctx = [], {}
    for i in range(len(toks)):
        cur = cur_by_ctx.get(toks[i][3])
        if cur and not adjacent(cur[-1], i):
            chains.append(cur); cur = None
        if cur is None:
            cur = cur_by_ctx[toks[i][3]] = []
        cur.append(i)
    chains.extend(c for c in cur_by_ctx.values() if c)
    chains.sort(key=lambda c: c[0])

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
                    paired_off.add(toks[chain[k + off]][0])
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
                paired_off.add(toks[chain[k]][0])
            elif prv is not None:
                out.append((vals[k], prv, rel, line_no, None))
                paired_off.add(toks[chain[k]][0])

    field_off = set()       # offset, in the text, of each identifier the struct-field reader paired
    lines = text.splitlines()
    line_at, _o = [], 0     # where each of those lines starts, by the same splitting
    for _l in text.splitlines(keepends=True):
        line_at.append(_o)
        _o += len(_l)
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
                field_off.add(line_at[idx] + m.start(2))

    # ── ACCOUNTING, one pass, by position ──────────────────────────────────────
    # Every identifier with a known prefix that sits inside ANY string literal
    # (plain, raw, byte, C) or ANY comment is an occurrence. It ends in exactly
    # one place: PAIRED, if it is the whole value of a token that a reader above
    # paired with a label; otherwise UNCHECKED, and printed as NOT checked.
    #
    # This replaces two loops that asked, shape by shape, "was this one already
    # handled?". Five review rounds each found a shape for which the answer was
    # wrongly yes: a JSON key, escaped JSON, an id at the start of a longer
    # string, raw byte strings, raw C strings. The question is no longer asked.
    # An occurrence is found by a search of the text, independent of how the
    # readers tokenise, and is paired only by an exact positional match. A shape
    # nobody has thought of yet is therefore counted, not dropped.
    #
    # Not found, because the text does not contain it as written: an identifier
    # split across two lines; one glued to a letter or digit before it.
    # Where the lexer lost its place, everything after that point is searched.
    regions = lits + spans
    if lost_at is not None:
        # The lexer lost its place (a string or comment that never closes). From
        # there to the end of the file it cannot say what is a string, so all of
        # it is searched: an identifier after the break is counted, not dropped.
        regions = regions + [(lost_at, len(text))]
    regions = sorted(regions)
    merged = []
    for a_, b_ in regions:
        if merged and a_ <= merged[-1][1]:
            merged[-1][1] = max(merged[-1][1], b_)
        else:
            merged.append([a_, b_])
    # Where each token's VALUE starts in the text, for tokens that are an identifier
    # and nothing else. A raw string's value starts after r, its hashes and the quote.
    id_at = {}
    for t in toks:
        if re.fullmatch(RS_CURIE_RE, t[2]) is None:
            continue
        v0 = t[0] + 1
        if t[4]:
            while text[v0 - 1] != '"':
                v0 += 1
        id_at[v0] = t
    for a_, b_ in merged:
        seen_here = []
        for at, written, c in _ids_in(text, a_, b_, False):
            tk = id_at.get(at)
            # PAIRED, by position and nothing looser: the chain readers paired the
            # token whose value starts exactly here (id_at holds only tokens that
            # are an identifier and nothing else), or the struct-field reader
            # matched the identifier at exactly this offset. The token's value is
            # NOT compared with the text as written: they differ only when the
            # identifier is broken by a backslash at the end of a line, and that
            # one is judged as a pair, so it is paired here too and not printed a
            # second time as a cut-off, unchecked identifier.
            # The underscore spelling (written is None) is never paired.
            paired = written is not None and (
                (tk is not None and tk[0] in paired_off) or at in field_off)
            seen_here.append((at, c, paired))
        for off, c, paired in seen_here:
            RS_IDS["occurrences"] += 1
            if paired:
                RS_IDS["paired"] += 1
            else:
                RS_IDS["unchecked"] += 1
                RS_OCC.add((rel, off, 0, c))

# ── JavaScript / TypeScript, and Markdown ────────────────────────────────────
# Written after a run on a real TypeScript project read 187 files and found no
# pair, where a reading by hand found 37 and four of them wrong. The shapes are
# the ones in that project, and each is bounded on purpose:
#
#   object literal     { id: 'HP:0001250', label: 'Seizure', selected: false }
#                      hpoId: '...' with hpoLabel: '...' anywhere in the SAME object
#   call arguments     ontologyClass('HP:0001250', 'Seizure')
#   builder chain      .setId('HP:0001250').setLabel('Seizure')
#   id-keyed table     'HP:0000006': 'AD',   // Autosomal dominant inheritance
#   comment            Mild: 'observed;HP:0012825',   // Mild (HP:0012825)
#   Markdown link      [Ventricular septal defect HP:0001629](https://...)
#   Markdown fences    the script shapes above, inside ```ts / ```js / ```json / bare
#
# Each is narrowed until what sits beside the identifier is a name and not just
# some text. A first version was not, and a review made nine false pairs from
# ordinary code (`parentLabel`, `track('HP:1', 'click')`, `// See the term (HP:1)`):
#
#   - A label key is `label` or `name`. A longer key (`hpoLabel`, `diseaseName`)
#     counts only when what comes before it matches what comes before `id`
#     (`hpoId`). `parentLabel` beside `id` is someone else's label.
#   - A call is read only when the function's name says it makes a term
#     (_SC_TERM_CALL), and only with exactly two string arguments.
#   - A `// Name (ID)` comment is read only at the end of a line of code that
#     itself contains that ID. A comment standing alone is prose.
#   - A template string with `${...}` in it is not a literal and is never a label.
#
# Still weak, and said so: `name` beside an id is taken for the term's name
# (`{ id, name: 'btn-x' }`); the comment that ends an id-keyed entry is taken
# for the name whatever it says (`// legacy`); so is Markdown link text before
# an id (`[see HP:1](...)`). Each is reported with the text as written.
#
# NOT read: a pair split between two statements; `id = '...'` assignments; a
# table from an identifier to its label with no comment ('HP:1': 'Seizure' is
# not told apart from 'HP:1': 'AD'); .html, .vue and .svelte files, which are
# not opened at all.
#
# ACCOUNTING, as for Rust and for the same reason: every identifier with a known
# prefix in the file is an occurrence, found by a search of the raw text that
# does not depend on the lexer. It is PAIRED only if a reader paired the
# identifier at exactly that offset. Everything else is counted and printed as
# NOT checked. The prefix must be spelled as the ontology spells it (`HP:`), or
# in any case when a digit follows (`hp:0001250`): `so:string` is a TypeScript
# parameter and `go:embed` is prose. Not seen: an identifier written with an
# escape inside it ('HP\x3a0001250'), because the search is on the text as written.
SCRIPT_EXTS = (".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs", ".mts", ".cts")
MARKDOWN_EXTS = (".md", ".mdx", ".markdown")
SC_IDS = {"occurrences": 0, "paired": 0, "unchecked": 0}
SC_OCC = set()      # (file, offset, 0, identifier): one per occurrence NOT paired

_JS_TOK = re.compile(r'''
  (?P<ws>\s+)
 |(?P<lc>//[^\n]*)
 |(?P<bc>/\*.*?\*/)
 |(?P<sq>'(?:[^'\\\n]|\\\r\n|\\.)*')
 |(?P<dq>"(?:[^"\\\n]|\\\r\n|\\.)*")
 |(?P<w>[A-Za-z_$][\w$]*)
 |(?P<n>\d[\w.]*)
 |(?P<p>.)
''', re.S | re.X)
_JS_REGEX = re.compile(r'/(?![*/])(?:[^/\\\n\[]|\\.|\[(?:[^\]\\\n]|\\.)*\])+/[A-Za-z]*')
# A slash starts a regular expression, not a division, after one of these.
_JS_RE_AFTER_P = frozenset("(,=:[!&|?{};+-*%<>~^")
_JS_RE_AFTER_W = frozenset(("return", "typeof", "case", "in", "of", "do", "else", "void",
                            "delete", "throw", "new", "instanceof", "yield", "await"))
_JS_ESC = re.compile(r'\\(?:u\{([0-9A-Fa-f]{1,6})\}|u([0-9A-Fa-f]{4})|x([0-9A-Fa-f]{2})|(\r\n|[\s\S]))')
_JS_ESC_CH = {"n": " ", "t": " ", "r": " ", "f": " ", "v": " ", "b": "", "0": ""}


def _js_unescape(s):
    if "\\" not in s:
        return s

    def one(m):
        h = m.group(1) or m.group(2) or m.group(3)
        if h:
            try:
                return chr(int(h, 16))
            except (ValueError, OverflowError):
                return ""
        ch = m.group(4)
        if ch in ("\n", "\r", "\r\n"):
            return ""                     # a backslash at the end of a line joins the lines
        return _JS_ESC_CH.get(ch, ch)
    return _JS_ESC.sub(one, s)


def _js_template_end(text, i, b):
    """text[i] is a backtick. -> the offset just past its closing backtick, or None."""
    j = i + 1
    while j < b:
        ch = text[j]
        if ch == "\\":
            j += 2
        elif ch == "`":
            return j + 1
        elif ch == "$" and text.startswith("${", j):
            j = _js_subst_end(text, j + 2, b)
            if j is None:
                return None
        else:
            j += 1
    return None


def _js_subst_end(text, j, b):
    """j is just past `${`. -> the offset just past the brace that closes it, or None."""
    depth = 1
    while j < b:
        ch = text[j]
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return j + 1
        elif ch in "'\"":
            m = _JS_TOK.match(text, j, b)
            if m.lastgroup in ("sq", "dq"):
                j = m.end()
                continue
        elif ch == "`":
            j = _js_template_end(text, j, b)
            if j is None:
                return None
            continue
        j += 1
    return None


def _js_lex(text, a=0, b=None, rel=None):
    """-> (tokens, comments).

    token   = (kind, start, end, value): 's' a string with its escapes resolved,
              'x' a template string with ${...} in it (not a literal),
              'w' a word, 'n' a number, 'r' a regular expression, 'p' one character.
    comment = (start, end, is_line_comment).
    Where it loses its place it says so and skips: to the end of the line for a
    string, to the end of the text for a template or a block comment.
    rel=None means do not warn: a Markdown fence is only guessed to be script."""
    if b is None:
        b = len(text)
    toks, comments = [], []

    def lost(at, what):
        if rel is not None:
            RS_LEX_WARN.append("%s:%d: %s" % (rel, text.count("\n", 0, at) + 1, what))

    i, prev = a, None
    while i < b:
        m = _JS_TOK.match(text, i, b)
        k, s, e = m.lastgroup, m.start(), m.end()
        if k == "ws":
            i = e
            continue
        if k in ("lc", "bc"):
            comments.append((s, e, k == "lc"))
            i = e
            continue
        if k in ("sq", "dq"):
            prev = ("s", s, e, _js_unescape(text[s + 1:e - 1]))
        elif k in ("w", "n"):
            prev = (k, s, e, m.group())
        else:
            ch = m.group()
            if ch == "`":
                end = _js_template_end(text, s, b)
                if end is None:
                    lost(s, "template string never closes")
                    break
                # with ${...} in it, it is an expression, not a literal: kind 'x'
                prev, e = ("x" if "${" in text[s:end] else "s", s, end, text[s + 1:end - 1]), end
            elif ch in "'\"":
                eol = text.find("\n", s, b)
                eol = b if eol < 0 else eol
                lost(s, "string does not close on its line")
                i = eol
                continue
            elif ch == "/" and text.startswith("/*", s):
                lost(s, "block comment never closes")
                break
            else:
                r = None
                if ch == "/" and (prev is None
                                  or (prev[0] == "p" and prev[3] in _JS_RE_AFTER_P)
                                  or (prev[0] == "w" and prev[3] in _JS_RE_AFTER_W)):
                    r = _JS_REGEX.match(text, s, b)
                if r is not None:
                    prev, e = ("r", s, r.end(), ""), r.end()
                else:
                    prev = ("p", s, e, ch)
        toks.append(prev)
        i = e
    return toks, comments


def _sc_known(curie):
    return curie.partition(":")[0].upper() in PREFIX_ONTOLOGY


_SC_FULL = re.compile(RS_CURIE_RE + r"\Z")
# A function whose name says it makes a term: ontologyClass, OntologyClass, TermId, hpoTerm ...
_SC_TERM_CALL = re.compile(r"ontology|term|curie|concept|phenotyp|disease|hpo", re.I)
_SC_COMMENT_PAREN = re.compile(r"//[/!]*[ \t]*([^()\n]{1,120}?)[ \t]*\([ \t]*(" + RS_CURIE_RE
                               + r")[ \t]*\)\.?[ \t\r]*\Z")
_SC_COMMENT_BODY = re.compile(r"//[/!]*[ \t]*(.*?)[ \t\r]*\Z", re.S)


def _script_pairs(text, lexed, rel, out, paired, line_of):
    toks, comments = lexed
    n = len(toks)
    cstarts = [c[0] for c in comments]

    def is_p(j, chars):
        return 0 <= j < n and toks[j][0] == "p" and toks[j][3] in chars

    def is_w(j, word):
        return 0 <= j < n and toks[j][0] == "w" and toks[j][3] == word

    def is_s(j):
        return 0 <= j < n and toks[j][0] == "s"

    def emit(curie, at, label, alt=None):
        label = " ".join(label.split())
        alt = " ".join(alt.split()) if alt else None
        if not label:
            label, alt = alt, None
        if not label:
            return
        out.append((curie, label, rel, line_of(at), alt if alt and alt != label else None))
        paired.add(at)

    def close_object(props):
        ids, labels = [], []
        for key, val, k in props:
            kv, vv = key[3], val[3]
            if key[0] == "s" and _SC_FULL.match(kv) and _sc_known(kv):
                # id-keyed table: the label is the comment that ends the line
                j = k + 3
                if is_p(j, ","):
                    j += 1
                ci = bisect.bisect_left(cstarts, val[2])
                if ci == len(comments):
                    continue
                cs, ce, is_line = comments[ci]
                if (not is_line or line_of(cs) != line_of(val[2] - 1)
                        or (j < n and toks[j][1] < cs)
                        or _SC_COMMENT_PAREN.match(text, cs, ce)):
                    continue
                emit(kv, key[1] + 1, _SC_COMMENT_BODY.match(text, cs, ce).group(1), vv)
                continue
            low = kv.lower()
            if (low.endswith("id") or low.endswith("curie")) and _SC_FULL.match(vv):
                stem = low[:-2] if low.endswith("id") else low[:-5]
                ids.append((stem.rstrip("_-"), val))
            elif low.endswith("label"):
                labels.append((low[:-5].rstrip("_-"), val))
            elif low.endswith("name"):
                labels.append((low[:-4].rstrip("_-"), val))
        for stem, val in ids:
            cands = [l for l in labels if l[0] == stem and l[1][3].strip()]
            if not cands and len(ids) == 1:
                # termId beside a bare `label`: yes. id beside `parentLabel`: no.
                cands = [l for l in labels if l[0] == "" and l[1][3].strip()]
            if len(cands) in (1, 2):
                emit(val[3], val[1] + 1, cands[0][1][3], cands[1][1][3] if len(cands) == 2 else None)

    stack = []
    for k, t in enumerate(toks):
        if t[0] == "p" and t[3] in "{[(":
            if (t[3] == "(" and k > 0 and toks[k - 1][0] == "w" and _SC_TERM_CALL.search(toks[k - 1][3])
                    and is_s(k + 1) and is_p(k + 2, ",") and is_s(k + 3) and is_p(k + 4, ")")
                    and _SC_FULL.match(toks[k + 1][3])
                    and toks[k + 3][3].strip() not in ("", "label", "id", "type")):
                emit(toks[k + 1][3], toks[k + 1][1] + 1, toks[k + 3][3])
            stack.append((t[3], []))
        elif t[0] == "p" and t[3] in "}])":
            if stack:
                opener, props = stack.pop()
                if opener == "{":
                    close_object(props)
        elif (t[0] in ("w", "s") and stack and stack[-1][0] == "{" and is_p(k - 1, "{,")
              and is_p(k + 1, ":") and is_s(k + 2)
              and (k + 3 >= n or is_p(k + 3, ",}") or is_w(k + 3, "as"))):
            stack[-1][1].append((t, toks[k + 2], k))
        elif (is_w(k, "setId") and is_p(k + 1, "(") and is_s(k + 2) and is_p(k + 3, ")")
              and is_p(k + 4, ".") and is_w(k + 5, "setLabel") and is_p(k + 6, "(")
              and is_s(k + 7) and is_p(k + 8, ")") and _SC_FULL.match(toks[k + 2][3])):
            emit(toks[k + 2][3], toks[k + 2][1] + 1, toks[k + 7][3])
    for opener, props in stack:          # an object the text never closes is still read
        if opener == "{":
            close_object(props)

    for cs, ce, is_line in comments:
        if not is_line:
            continue
        m = _SC_COMMENT_PAREN.match(text, cs, ce)
        if m and _sc_known(m.group(2)) and re.search(r"[A-Za-z]", m.group(1)):
            bol = text.rfind("\n", 0, cs) + 1
            if m.group(2) in text[bol:cs]:      # the code this comment ends names the same id
                emit(m.group(2), m.start(2), m.group(1))


def _line_finder(text):
    starts = [0] + [m.end() for m in re.finditer(r"\n", text)]
    return lambda off: bisect.bisect_right(starts, off)


def _sc_account(text, rel, paired):
    for off, written, c in _ids_in(text, 0, len(text), False):
        # spelled as the ontology spells it, or any spelling with a digit after it
        if (written is not None and written.partition(":")[0] not in _RS_EXACT_PREFIX
                and not any(ch.isdigit() for ch in written)):
            continue
        SC_IDS["occurrences"] += 1
        if off in paired:
            SC_IDS["paired"] += 1
        else:
            SC_IDS["unchecked"] += 1
            SC_OCC.add((rel, off, 0, c))


YAML_EXTS = (".yaml", ".yml")
YAML_IDS = {"occurrences": 0, "paired": 0, "unchecked": 0}
YAML_OCC = set()    # (file, offset, 0, identifier): one per occurrence NOT paired


def _yaml_account(text, rel, paired):
    """Every identifier with a known prefix written anywhere in a YAML file is an
    occurrence, found by a search of the text and not by the reader. It is PAIRED
    only if the reader paired the identifier at exactly that offset; otherwise it
    is counted and printed as NOT checked. So a layout the reader does not know
    (a flow mapping, a key other than `id`, a label four lines away) is counted,
    not dropped."""
    for off, written, c in _ids_in(text, 0, len(text), False):
        if (written is not None and written.partition(":")[0] not in _RS_EXACT_PREFIX
                and not any(ch.isdigit() for ch in written)):
            continue
        YAML_IDS["occurrences"] += 1
        if off in paired:
            YAML_IDS["paired"] += 1
        else:
            YAML_IDS["unchecked"] += 1
            YAML_OCC.add((rel, off, 0, c))


def extract_script(text, rel, out):
    paired = set()
    lexed = _js_lex(text, 0, len(text), rel)
    _script_pairs(text, lexed, rel, out, paired, _line_finder(text))
    _sc_account(text, rel, paired)


_MD_FENCE = re.compile(r" {0,3}(`{3,}|~{3,})[ \t]*([\w.+#-]*)")
_MD_SCRIPT_LANGS = frozenset(("", "js", "javascript", "ts", "typescript", "jsx", "tsx",
                              "mjs", "cjs", "json", "json5", "jsonc"))
_MD_LINK = re.compile(r"\[([^\[\]]{1,200}?)[ \t\r\n]+\(?(" + RS_CURIE_RE + r")\)?[ \t\r\n]*\]\(")


def extract_markdown(text, rel, out, paired):
    """Adds to what the line readers found. `paired` already holds their offsets."""
    line_of = _line_finder(text)
    pos, fence, body_at = 0, None, 0
    for line in text.splitlines(True):
        m = _MD_FENCE.match(line)
        if fence is None:
            if m:
                fence, body_at = (m.group(1)[0], len(m.group(1)), m.group(2).lower()), pos + len(line)
        elif m and m.group(1)[0] == fence[0] and len(m.group(1)) >= fence[1] and not m.group(2):
            if fence[2] in _MD_SCRIPT_LANGS:
                _script_pairs(text, _js_lex(text, body_at, pos, None), rel, out, paired, line_of)
            fence = None
        pos += len(line)
    for m in _MD_LINK.finditer(text):
        if _sc_known(m.group(2)) and re.search(r"[A-Za-z]", m.group(1)):
            out.append((m.group(2), " ".join(m.group(1).split()), rel, line_of(m.start(2)), None))
            paired.add(m.start(2))
    _sc_account(text, rel, paired)


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
        if path.endswith(SCRIPT_EXTS):
            # Script gets ONLY the script reader, for the same reason: the line
            # patterns below take `id: 'user_1'` for an identifier.
            extract_script(text, rel, pairs)
            continue

        lines = text.splitlines()
        # Where each line starts, so a pair can be accounted for by its offset.
        line_at, gen_off, _o = [], set(), 0
        for _l in text.splitlines(True):
            line_at.append(_o)
            _o += len(_l)
        for idx, line in enumerate(lines):
            for rx in (RE_ONTCLASS, RE_SETIDLBL):
                for m in rx.finditer(line):
                    lbl = m.group(2).strip()
                    if lbl and lbl not in ("label", "id", "type"):
                        pairs.append((m.group(1).replace("_", ":"), lbl, rel, idx + 1))
                        gen_off.add(line_at[idx] + m.start(1))
            mi = RE_YAML_ID.match(line)
            if mi:
                # Pair `id:` with a `label:` at the SAME indentation, within 3
                # lines, and stop at any other `id:` at that indent. Without the
                # indentation guard the scan walks out of its own mapping and
                # borrows a sibling block's label — e.g. in docs/evidence.rst it
                # paired `id: "PMID:30962759"` (whose sibling key is
                # `description:`, not `label:`) with the ECO label two lines up.
                found = _yaml_sibling(lines, idx, RE_YAML_LBL)
                if found and RE_CATEGORY.fullmatch(found):
                    # Same rule as JSON: a category-shaped `label` beside a `name`
                    # in the same mapping is a category; the name is checked.
                    nm = _yaml_sibling(lines, idx, RE_YAML_NAME)
                    if nm:
                        found = nm
                        LABEL_DEFERRED[0] += 1
                if found:
                    pairs.append((mi.group(1).replace("_", ":"), found, rel, idx + 1))
                    gen_off.add(line_at[idx] + mi.start(1))
        if path.endswith(MARKDOWN_EXTS):
            extract_markdown(text, rel, pairs, gen_off)
        if path.endswith(YAML_EXTS):
            _yaml_account(text, rel, gen_off)

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
            # 4th column `obsolete` carries OLS4's is_obsolete flag, so the offline
            # path can reach the OBSOLETE status the live path reads from the API.
            retired = len(parts) > 3 and parts[3].strip().lower() == "obsolete"
            if label == "__NOTFOUND__":
                m[curie] = ("NOTFOUND", "", [], "term-not-found")
            elif label == "__ERROR__":
                m[curie] = ("ERROR", "", [], "simulated-lookup-failure")
            else:
                m[curie] = ("OBSOLETE" if retired else "FOUND", label, syns, "")
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
        return (hit[0], hit[1], hit[2], "offline-map")
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

# NOT AN IDENTIFIER SHAPE. (From review: gene symbols such as HGNC:CFTR have no
# digit but are real identifiers, and an all-capital prefix is how ontologies write
# them, so only an ALL-LOWERCASE prefix is set aside.) `enable:sort`, `pg:catalog`, `obo:id` are code, not
# ontology identifiers. A pair is set aside here ONLY when its prefix is not one
# we resolve, has no uppercase letter, AND its local part has no digit at all.
# Every other pair -- any
# known prefix (so `HP:abc` is still judged), any unknown prefix whose local part
# has a digit (`B:1`, `MeSH:D003920`), any capitalised prefix (`HGNC:CFTR`) -- goes on to be judged, and an unresolvable
# one is still UNRESOLVED. What is set aside is counted in the header and listed in the JSON,
# never folded into OK and never dropped without a word.
_NOT_SHAPE = []


def _not_id_shape(curie):
    pre, _, local = curie.partition(":")
    return (pre.upper() not in PREFIX_ONTOLOGY and not any(ch.isdigit() for ch in local)
            and pre == pre.lower())


# NOT A LABEL. Measured on twelve real projects: of 72 mismatches reported, 49
# were two strings side by side in test code where the second was never a
# name: ("CL:0000127", "cell_type"), ("HP:0001166", "HP:0040064"),
# ("CHEBI:6801", "MONDO:0005148"), ("CHEBI:1", "0.35"), or the identifier
# written again as its own label. None of these can be a wrong name, because
# none is a name. They are set aside, counted and listed.
#   - another identifier: colon form, or PREFIX_digits with a prefix this tool knows
#   - no letter in it at all
#   - the identifier itself again, whatever the punctuation
#   - the bare name of an ontology ("NCBITAXON"), one character ("P"), or a
#     bare field word from the list below ("name", "subject", "evidence"),
#     unless the ontology itself calls the term that (next point)
#   - a lower-case word_with_underscores, BUT ONLY when the identifier resolves
#     and its own label is not written that way. Sequence Ontology names are
#     all of that form (missense_variant), and so are the three Gene Ontology
#     roots. A first version set every such word aside and hid a wrong SO name;
#     review caught it. Now the ontology decides: if the term's label or a
#     synonym is itself word_with_underscores, the pair is judged.
# THE ONTOLOGY DECIDES. The last three kinds above, and the underscore kind,
# are set aside only when the term resolves and the text is NOT its label or
# one of its synonyms. Real terms are labelled "HP", "Uberon" and "evidence";
# written beside their own identifiers those are right and are judged OK.
# A FIELD WORD IS A SPECIAL CASE, found in review: NCIT has terms really
# called "Source" and "Subject", so "source" beside the identifier for Subject
# is a genuine swap. A field word is therefore set aside only when NO term of
# that ontology is labelled with it; if one is, or the ontology cannot be
# asked, the pair is judged.
# A single plain word that is not on the field list ("tissue" beside the id
# for lung) is NOT set aside: it may be a wrong name, and that is the thing
# this tool is for.
_NOT_LABEL = []
_SNAKE = re.compile(r"[a-z0-9]+(?:_[a-z0-9]+)+\Z")
_ID_COLON = re.compile(RS_CURIE_RE + r"\Z")
_ID_UNDER = re.compile(r"([A-Za-z]+)_[A-Za-z0-9]*\d[A-Za-z0-9]*\Z")
_KNOWN_SPELLED = set(PREFIX_ONTOLOGY) | set(CURIE_PREFIX_ALIAS.values())
_KNOWN_UPPER = {x.upper() for x in _KNOWN_SPELLED}
# Words that name a field, in test fixtures and canned replies. Measured: 50
# false mismatches in one Rust project were these beside an identifier.
_FIELD_WORDS = frozenset(("name", "label", "id", "type", "object", "subject", "predicate",
                          "category", "evidence", "value", "key", "description", "title",
                          "text", "source", "target", "xrefs", "synonyms"))


_CALLED = {}        # (ontology, word) -> True / False / None


def _some_term_is_called(curie, word):
    """Is ANY term of this identifier's ontology labelled exactly `word`?
    True, False, or None when it cannot be asked (no network, a failed lookup)."""
    prefix = curie.split(":", 1)[0].upper()
    if prefix not in PREFIX_ONTOLOGY:
        return None
    ont = PREFIX_ONTOLOGY[prefix] or prefix.lower()
    key = (ont, word.lower())
    if key in _CALLED:
        return _CALLED[key]
    if os.environ.get("OTV_TEST_SEARCH_FAILS") == "1":
        # Test hook only: the label search cannot be asked while term lookups
        # still answer. Nothing else can reach that state offline.
        ans = None
    elif OFFLINE is not None:
        ans = any(k.split(":", 1)[0].upper() == prefix and v[0] in ("FOUND", "OBSOLETE") and norm(v[1]) == norm(word)
                  for k, v in OFFLINE.items())
    elif NO_NETWORK:
        ans = None
    else:
        url = "%s/search?%s" % (OLS_BASE, urllib.parse.urlencode({
            "q": word, "ontology": ont, "exact": "true", "queryFields": "label",
            "rows": "20", "fieldList": "label,type,obo_id"}))
        _LOOKUPS[0] += 1
        if _LOOKUPS[0] % 10 == 0:
            time.sleep(0.4)
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "ontology-term-validate/%s" % VERSION})
            with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
                docs = json.load(r)["response"]["docs"]
            # Only a CLASS counts. Most ontologies import annotation properties
            # called label, id, type, title, description and source; a word that
            # only names a property cannot be the wrong name of a term.
            # ... and only one of the ontology's OWN terms: MONDO imports a
            # class called "object" from an upper ontology, which is not a disease.
            own = CURIE_PREFIX_ALIAS.get(prefix, prefix).upper() + ":"
            ans = any(d.get("type") == "class" and (d.get("obo_id") or "").upper().startswith(own)
                      and norm(d.get("label") or "") == norm(word) for d in docs)
        except Exception:
            ans = None
    _CALLED[key] = ans
    return ans


def _ontology_says(curie, s):
    """-> True the term resolves and s is its label or a synonym; False it
    resolves and s is neither; None it cannot be looked up."""
    status, cur, syns, _d = resolve(curie)
    if status == "UNRESOLVED":
        return None
    return any(norm(x) == norm(s) for x in [cur] + list(syns) if x)


def _not_a_label(curie, s):
    s = (s or "").strip()
    if _ID_COLON.match(s):
        return "another identifier"
    m = _ID_UNDER.match(s)
    if m and m.group(1) in _KNOWN_SPELLED:
        return "another identifier"
    if not re.search(r"[^\W\d_]", s):
        return "no letters"
    if norm(s) in (norm(curie), norm(curie.partition(":")[2])):
        return "the identifier again"
    kind = None
    if s.lower() in _FIELD_WORDS and s == s.lower() and _some_term_is_called(curie, s) is not False:
        # The ontology has a term really called this ("source", "subject" in
        # NCIT), or it could not be asked. Then the word may be a wrong NAME,
        # a swap of two real terms, and that is judged, never set aside.
        return None
    if s.upper() in _KNOWN_UPPER:
        kind = "an ontology's name"
    elif len(s) == 1:
        kind = "one character"
    elif s.lower() in _FIELD_WORDS and s == s.lower():
        kind = "a field name"
    elif _SNAKE.match(s):
        # Judge it when the ontology writes ITS label that way (Sequence
        # Ontology, the Gene Ontology roots): then a wrong one is a wrong name.
        status, cur, _syns, _d = resolve(curie)
        if status == "UNRESOLVED" or _SNAKE.match(cur or ""):
            return None
        kind = "a code name"
    if kind and _ontology_says(curie, s) is False:
        return kind
    return None


_kept = []
for _p in pairs:
    if _not_id_shape(_p[0]):
        _NOT_SHAPE.append(_p)
        continue
    _alt = _p[4] if len(_p) > 4 else None
    _why = _not_a_label(_p[0], _p[1])
    if _why and _alt is not None and not _not_a_label(_p[0], _alt):
        # a label sat on both sides and only one of them is a name: judge that one
        _p, _why = (_p[0], _alt, _p[2], _p[3], None), None
    elif not _why and _alt is not None and _not_a_label(_p[0], _alt):
        _p = (_p[0], _p[1], _p[2], _p[3], None)
    if _why:
        _NOT_LABEL.append((_p[0], _p[1], _p[2], _p[3], _why))
    else:
        _kept.append(_p)
pairs = _kept

src = ("offline-map" if OFFLINE is not None
       else ("disabled(--no-network)" if NO_NETWORK else OLS_BASE))
print("ontology-term-validate %s" % VERSION)
print("scan roots     : %d" % len(roots))
print("files read     : %d" % files_read)
print("pairs found    : %d" % len(pairs))
print("distinct CURIEs: %d" % len({p[0] for p in pairs}))
print("resolver       : %s" % src)
_unl = len({o[3] for o in RS_OCC})
if _unl:
    print("unlabelled ids : %d distinct Rust identifier%s with no label beside %s — NOT checked%s"
          % (_unl, "" if _unl == 1 else "s", "it" if _unl == 1 else "them",
             "" if len(RS_OCC) == _unl else " [%d occurrences]" % len(RS_OCC)))
_unl = len({o[3] for o in SC_OCC})
if _unl:
    print("unlabelled ids : %d distinct identifier%s in script or Markdown with no label beside %s — NOT checked%s"
          % (_unl, "" if _unl == 1 else "s", "it" if _unl == 1 else "them",
             "" if len(SC_OCC) == _unl else " [%d occurrences]" % len(SC_OCC)))
_unl = len({o[3] for o in YAML_OCC})
if _unl:
    print("unlabelled ids : %d distinct identifier%s in YAML with no label beside %s — NOT checked%s"
          % (_unl, "" if _unl == 1 else "s", "it" if _unl == 1 else "them",
             "" if len(YAML_OCC) == _unl else " [%d occurrences]" % len(YAML_OCC)))
if LABEL_DEFERRED[0]:
    print("label deferred to name: %d (a category-shaped label sat beside a name; the name was checked, the label was not)"
          % LABEL_DEFERRED[0])
if SKIPPED_DIRS:
    print("skipped dirs   : %d director%s NOT read, holding files of a type this tool reads: %s%s"
          % (len(SKIPPED_DIRS), "y" if len(SKIPPED_DIRS) == 1 else "ies",
             ", ".join("%s (%d)" % d for d in SKIPPED_DIRS[:10]),
             "" if len(SKIPPED_DIRS) <= 10 else ", ... %d more" % (len(SKIPPED_DIRS) - 10)))
if _NOT_SHAPE:
    print("not id-shaped  : %d pair%s set aside -- lower-case unknown prefix and no digit in the local part (e.g. %s) -- NOT checked"
          % (len(_NOT_SHAPE), "" if len(_NOT_SHAPE) == 1 else "s",
             ", ".join(sorted({p[0] for p in _NOT_SHAPE})[:4])))
if _NOT_LABEL:
    print("not a label    : %d pair%s set aside -- the text beside the identifier is %s -- NOT checked"
          % (len(_NOT_LABEL), "" if len(_NOT_LABEL) == 1 else "s",
             ", ".join(sorted({p[4] for p in _NOT_LABEL}))))
if RS_LEX_WARN:
    print("lexer warnings : %d place%s where a reader lost its place -- pairs after %s may be missing:"
          % (len(RS_LEX_WARN), "" if len(RS_LEX_WARN) == 1 else "s", "it" if len(RS_LEX_WARN) == 1 else "each"))
    for w in RS_LEX_WARN[:10]:
        print("                 " + w)
print("")

if not pairs:
    print("EMPTY SCAN — zero (CURIE, label) pairs were found%s." % (
        " to judge (%s)" % ", ".join(
            x for x in ("%d set aside as not identifier-shaped" % len(_NOT_SHAPE) if _NOT_SHAPE else "",
                        "%d set aside as not a label" % len(_NOT_LABEL) if _NOT_LABEL else "") if x)
        if (_NOT_SHAPE or _NOT_LABEL) else ""))
    print("This is UNKNOWABLE, not clean: an empty scan proves nothing about the")
    print("tree. Check the scan root, the file extensions, and the extractors.")
    print("")
    print("SUMMARY ok=0 synonym=0 mismatch=0 unresolved=0 obsolete=0 pairs=0")
    sys.stdout.flush()
    write_json({"version": VERSION, "verdict": "EMPTY-SCAN", "pairs": [],
                "counts": {"ok": 0, "synonym": 0, "mismatch": 0,
                           "unresolved": 0, "obsolete": 0,
                           "not_identifier_shaped": len(_NOT_SHAPE), "not_a_label": len(_NOT_LABEL),
                           "label_deferred_to_name": LABEL_DEFERRED[0]},
                "skipped_dirs": [{"dir": d, "files": n} for d, n in SKIPPED_DIRS],
                "not_a_label_pairs": [
                    {"curie": p[0], "written": p[1], "file": p[2], "line": p[3], "why": p[4]} for p in _NOT_LABEL],
                "not_identifier_shaped_pairs": [
                    {"curie": p[0], "written": p[1], "file": p[2], "line": p[3]} for p in _NOT_SHAPE],
                "rust_ids": RS_IDS, "script_ids": SC_IDS, "yaml_ids": YAML_IDS}, indent=2)
    print("VERDICT EMPTY-SCAN (UNKNOWABLE) — exit %d" % EXIT_EMPTY)
    sys.exit(EXIT_EMPTY)

rows = []
for curie, label, rel, lineno, alt in pairs:
    status, cur, syns, detail = resolve(curie)

    def judge(written):
        if status == "UNRESOLVED":
            return "UNRESOLVED", detail
        if status == "OBSOLETE":
            # A retired term is read BEFORE the synonym branch, or a written name
            # that is one of its synonyms reads SYNONYM and hides the retirement.
            # OLS4 writes the label as "obsolete <name>"; the bare name, the label
            # and every synonym are all the retired term's own names. A name that
            # is none of them falls through and is judged (MISMATCH).
            # Gated on OLS4's is_obsolete flag: a label that merely begins
            # "obsolete " on a live term is a different name, and is judged.
            own = [cur] + list(syns)
            if re.match(r"obsolete\s", cur or "", re.I):
                own.append(cur[len("obsolete"):])
            if any(norm(x) == norm(written) for x in own if x):
                return "OBSOLETE", detail
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
                       "obsolete": c["OBSOLETE"], "pairs": len(rows),
                       "not_identifier_shaped": len(_NOT_SHAPE), "not_a_label": len(_NOT_LABEL),
                           "label_deferred_to_name": LABEL_DEFERRED[0]},
            "skipped_dirs": [{"dir": d, "files": n} for d, n in SKIPPED_DIRS],
            "not_a_label_pairs": [
                {"curie": p[0], "written": p[1], "file": p[2], "line": p[3], "why": p[4]} for p in _NOT_LABEL],
            "not_identifier_shaped_pairs": [
                {"curie": p[0], "written": p[1], "file": p[2], "line": p[3]} for p in _NOT_SHAPE],
            "rust_ids": RS_IDS, "script_ids": SC_IDS, "yaml_ids": YAML_IDS,
            "rows": rows}, indent=2, sort_keys=True)
print("VERDICT %s — exit %d" % (verdict, code))
sys.exit(code)
PY
