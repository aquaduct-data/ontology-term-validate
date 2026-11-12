#!/usr/bin/env bash
# Selftest for ontology-term-validate.sh
#
#   ontology-term-validate-selftest.sh [--offline-only]
#
# This is the real deliverable alongside the tool: proof that the validator
# BITES. Every case asserts both an exit code and the presence (or absence) of
# specific lines in the report.
#
# EXIT CODES
#   0  all cases passed (hermetic + network, or hermetic only under --offline-only)
#   1  at least one case FAILED
#   3  network cases were SKIPPED because OLS4 was unreachable. This is loud and
#      non-zero on purpose: a skipped network case must never read as a pass.
#      (--offline-only makes the skip deliberate and exits 0, with a banner.)
#
# NO `grep -q` ON A PIPE ANYWHERE. grep exits at the first match, the producer
# takes SIGPIPE, and under `pipefail` a genuine match reads as no-match. Every
# assertion below writes the report to a file first and then scans the file.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="${OTV_TOOL:-${HERE}/ontology-term-validate.sh}"
OFFLINE_ONLY=0
[ "${1:-}" = "--offline-only" ] && OFFLINE_ONLY=1

[ -x "${TOOL}" ] || { echo "selftest: tool not executable: ${TOOL}" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/otv-selftest.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT

PASS=0; FAIL=0; SKIP=0

ok()   { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && sed 's/^/        | /' "$2"; }

# assert_exit <expected> <name> -- <tool args...>
run_tool() { # -> writes $WORK/out, returns tool exit code
  "${TOOL}" "$@" > "${WORK}/out" 2>&1
  return $?
}

has()    { grep -F -- "$2" "$1" > "${WORK}/.hit" 2>/dev/null; [ -s "${WORK}/.hit" ]; }
hasnt()  { grep -F -- "$2" "$1" > "${WORK}/.hit" 2>/dev/null; [ ! -s "${WORK}/.hit" ]; }

# ── fixtures ─────────────────────────────────────────────────────────────────
mkdir -p "${WORK}/good" "${WORK}/bad" "${WORK}/unresolved" "${WORK}/empty" \
         "${WORK}/synonym" "${WORK}/unknownprefix" "${WORK}/451"

cat > "${WORK}/good/Good.java" <<'J'
class Good {
  void x() {
    OntologyClass a = ontologyClass("HP:0001250", "Seizure");
    OntologyClass b = OntologyClass.newBuilder().setId("NCIT:C51899").setLabel("Radical Cystoprostatectomy").build();
  }
}
J
cat > "${WORK}/good/good.yaml" <<'Y'
subject:
  code:
    id: "MONDO:0007947"
    label: "Marfan syndrome"
Y

# The #451 shape: valid identifier, unrelated concept.
cat > "${WORK}/bad/Bad.java" <<'J'
class Bad {
  void x() {
    OntologyClass a = ontologyClass("HP:0001250", "Seizure");
    OntologyClass b = ontologyClass("NCIT:C5189", "Radical Cystoprostatectomy");
  }
}
J

cat > "${WORK}/unresolved/Unres.java" <<'J'
class Unres {
  void x() {
    OntologyClass a = ontologyClass("HP:0001250", "Seizure");
    OntologyClass b = ontologyClass("NCIT:C99999999", "Entirely Fictional Procedure");
  }
}
J

cat > "${WORK}/empty/Empty.java" <<'J'
class Empty { void x() { int i = 1; } }
J

cat > "${WORK}/synonym/Syn.java" <<'J'
class Syn { void x() { OntologyClass a = ontologyClass("NCIT:C51899", "Cystoprostatectomy"); } }
J

cat > "${WORK}/unknownprefix/Unk.java" <<'J'
class Unk { void x() { OntologyClass a = ontologyClass("ZZZNOTANONTOLOGY:12345", "Some Label"); } }
J

# Exactly the four affected shapes named in issue #451.
cat > "${WORK}/451/UrothelialCarcinomaExample.java" <<'J'
class UrothelialCarcinomaExample {
  void biosample() {
    biosampleBuilder.setProcedure(Procedure.newBuilder().setCode(ontologyClass("NCIT:C5189", "Radical Cystoprostatectomy")).build());
  }
}
J
cat > "${WORK}/451/cancer-example.rst" <<'R'
.. code-block:: yaml

      procedure:
          code:
            id: "NCIT:C5189"
            label: "Radical Cystoprostatectomy"
R

# Offline resolution map: CURIE <TAB> label <TAB> synonym|synonym
MAP="${WORK}/map.tsv"
cat > "${MAP}" <<'M'
HP:0001250	Seizure	Seizures|Epileptic seizure
NCIT:C51899	Radical Cystoprostatectomy	Cystoprostatectomy|Radical Cystoprostatectomy
NCIT:C5189	Breast Extraskeletal Osteosarcoma	Breast Osteosarcoma
MONDO:0007947	Marfan syndrome	MFS
NCIT:C99999999	__NOTFOUND__
M

# Report the tool path repo-relative: committed transcripts must carry no host paths.
REPO_ROOT="$(cd "${HERE}/../.." 2>/dev/null && pwd)"
TOOL_DISPLAY="${TOOL}"
case "${TOOL_DISPLAY}" in
  "${REPO_ROOT}"/*) TOOL_DISPLAY="${TOOL_DISPLAY#${REPO_ROOT}/}" ;;
  *)                TOOL_DISPLAY="$(basename "$(dirname "${TOOL}")")/$(basename "${TOOL}")" ;;
esac

echo "ontology-term-validate selftest"
echo "tool : ${TOOL_DISPLAY}"
echo ""
echo "── HERMETIC CASES (offline map, no network) ─────────────────────────────"

# 1 — known-good fixture passes
run_tool --offline-map "${MAP}" "${WORK}/good"; rc=$?
if [ $rc -eq 0 ] && has "${WORK}/out" "VERDICT OK"; then
  ok "good fixture -> exit 0, VERDICT OK"
else bad "good fixture should exit 0 / VERDICT OK (got exit ${rc})" "${WORK}/out"; fi

# 2 — deliberately wrong CURIE FAILS (the tool bites)
run_tool --offline-map "${MAP}" "${WORK}/bad"; rc=$?
if [ $rc -eq 1 ] && has "${WORK}/out" "mismatch=1"; then
  ok "wrong-CURIE fixture -> exit 1, mismatch=1"
else bad "wrong-CURIE fixture should exit 1 with mismatch=1 (got exit ${rc})" "${WORK}/out"; fi

# 3 — the actual #451 pair is reported MISMATCH with the true ontology label
run_tool --offline-map "${MAP}" "${WORK}/bad"; rc=$?
if has "${WORK}/out" "NCIT:C5189  written='Radical Cystoprostatectomy'  ontology='Breast Extraskeletal Osteosarcoma'"; then
  ok "#451 pair reported with both labels quoted"
else bad "#451 pair not reported with both labels" "${WORK}/out"; fi

# 4 — the corrected CURIE passes
run_tool --offline-map "${MAP}" "${WORK}/good"; rc=$?
if has "${WORK}/out" "mismatch=0"; then
  ok "NCIT:C51899 + 'Radical Cystoprostatectomy' -> no mismatch"
else bad "corrected CURIE should not mismatch" "${WORK}/out"; fi

# 5 — UNRESOLVED is not folded into OK
run_tool --offline-map "${MAP}" "${WORK}/unresolved"; rc=$?
if [ $rc -eq 4 ] && has "${WORK}/out" "unresolved=1" && has "${WORK}/out" "ok=1" \
   && has "${WORK}/out" "VERDICT CANNOT-DETERMINE" && has "${WORK}/out" "term-not-found-in-ols4"; then
  ok "nonexistent CURIE -> exit 4, unresolved=1, ok=1 (not folded)"
else bad "unresolved handling wrong (got exit ${rc}); want exit 4 unresolved=1 ok=1" "${WORK}/out"; fi

# 6 — empty scan is UNKNOWABLE, not clean
run_tool --offline-map "${MAP}" "${WORK}/empty"; rc=$?
if [ $rc -eq 3 ] && has "${WORK}/out" "EMPTY SCAN" && hasnt "${WORK}/out" "VERDICT OK"; then
  ok "empty scan -> exit 3, EMPTY SCAN, never VERDICT OK"
else bad "empty scan should exit 3 with EMPTY SCAN (got exit ${rc})" "${WORK}/out"; fi

# 7 — fail-closed: no network means UNRESOLVED, never OK
run_tool --no-network "${WORK}/good"; rc=$?
if [ $rc -eq 4 ] && has "${WORK}/out" "network-disabled" && has "${WORK}/out" "ok=0"; then
  ok "--no-network -> exit 4, ok=0 (fail-closed)"
else bad "--no-network should exit 4 with ok=0 (got exit ${rc})" "${WORK}/out"; fi

# 8 — exact synonym is SYNONYM, not MISMATCH (false-positive control)
run_tool --offline-map "${MAP}" "${WORK}/synonym"; rc=$?
if [ $rc -eq 0 ] && has "${WORK}/out" "synonym=1" && has "${WORK}/out" "mismatch=0"; then
  ok "exact synonym -> synonym=1, mismatch=0"
else bad "synonym should not be a mismatch (got exit ${rc})" "${WORK}/out"; fi

# 9 — unknown prefix is UNRESOLVED, not OK
run_tool --offline-map "${MAP}" "${WORK}/unknownprefix"; rc=$?
if [ $rc -eq 4 ] && has "${WORK}/out" "unknown-prefix:ZZZNOTANONTOLOGY" && has "${WORK}/out" "ok=0"; then
  ok "unknown prefix -> exit 4, unknown-prefix reason, ok=0"
else bad "unknown prefix should be UNRESOLVED (got exit ${rc})" "${WORK}/out"; fi

# 10 — --tolerate-unresolved downgrades the exit code but still PRINTS unresolved
run_tool --offline-map "${MAP}" --tolerate-unresolved "${WORK}/unresolved"; rc=$?
if [ $rc -eq 0 ] && has "${WORK}/out" "unresolved=1" && has "${WORK}/out" "OK-WITH-UNRESOLVED"; then
  ok "--tolerate-unresolved -> exit 0 but unresolved=1 still reported"
else bad "--tolerate-unresolved behaviour wrong (got exit ${rc})" "${WORK}/out"; fi

# 11 — both #451 surfaces (Java + RST yaml block) are detected
run_tool --offline-map "${MAP}" "${WORK}/451"; rc=$?
if [ $rc -eq 1 ] && has "${WORK}/out" "UrothelialCarcinomaExample.java" && has "${WORK}/out" "cancer-example.rst"; then
  ok "#451 detected in BOTH the Java and the RST/YAML surface"
else bad "#451 should be found in both Java and RST (got exit ${rc})" "${WORK}/out"; fi

# 12 — a bad --timeout is a USAGE error (exit 2), never exit 1 (= MISMATCH)
for t in abc -5 0; do
  run_tool --offline-map "${MAP}" --timeout "$t" "${WORK}/good"; rc=$?
  if [ $rc -eq 2 ] && has "${WORK}/out" "--timeout must be a positive number" && hasnt "${WORK}/out" "VERDICT"; then
    ok "--timeout '$t' -> exit 2 usage error, no VERDICT"
  else bad "--timeout '$t' should exit 2 with a usage message (got exit ${rc})" "${WORK}/out"; fi
done
run_tool --offline-map "${MAP}" --timeout 2.5 "${WORK}/good"; rc=$?
if [ $rc -eq 0 ] && has "${WORK}/out" "VERDICT OK"; then
  ok "--timeout 2.5 accepted (control: validation is not over-strict)"
else bad "--timeout 2.5 should be accepted (got exit ${rc})" "${WORK}/out"; fi

# 13 — an unwritable --json path fails cleanly (exit 2) and NO VERDICT is printed.
#      It used to print "VERDICT OK — exit 0", then throw, then exit 1.
for fx in good empty; do
  run_tool --offline-map "${MAP}" --json "${WORK}/no-such-dir/report.json" "${WORK}/${fx}"; rc=$?
  if [ $rc -eq 2 ] && has "${WORK}/out" "cannot write --json file" && hasnt "${WORK}/out" "VERDICT" \
     && hasnt "${WORK}/out" "Traceback"; then
    ok "--json <unwritable> on ${fx} fixture -> exit 2, no VERDICT line, no traceback"
  else bad "--json <unwritable> on ${fx} fixture should exit 2 with no VERDICT (got exit ${rc})" "${WORK}/out"; fi
done
rm -f "${WORK}/report.json"
run_tool --offline-map "${MAP}" --json "${WORK}/report.json" "${WORK}/good"; rc=$?
if [ $rc -eq 0 ] && has "${WORK}/out" "VERDICT OK" && has "${WORK}/report.json" '"verdict": "OK"' \
   && has "${WORK}/report.json" '"exit": 0'; then
  ok "--json <writable> -> exit 0, report written and agrees with VERDICT (control)"
else bad "--json <writable> should write a report agreeing with exit 0 (got exit ${rc})" "${WORK}/out"; fi

# ── Rust ─────────────────────────────────────────────────────────────────────
# Shapes taken from real Rust phenopacket tooling, not invented. Every negative
# below is a pair the extractor must NOT make, written so that making it would
# change the verdict -- a control that cannot fail is not a control.
mkdir -p "${WORK}/rs_good" "${WORK}/rs_labelfirst" "${WORK}/rs_field" "${WORK}/rs_ambig_ok" \
         "${WORK}/rs_ambig_bad" "${WORK}/rs_accession" "${WORK}/rs_boundary"

cat > "${WORK}/rs_good/good.rs" <<'R'
fn fixtures() {
    let a = HpoTermData::from_str("HP:0001250", "Seizure", "observed").unwrap();
    let b = HpoTermDuplet::new("Marfan syndrome","MONDO:0007947" );
    // The .expect() text is NOT an argument next to the identifier. If it were
    // paired, this line alone would turn the verdict to MISMATCH.
    let c = find(&children, "NCIT:C51899").expect("Breast Extraskeletal Osteosarcoma");
    let d = vec![("NCIT:C51899", "Radical Cystoprostatectomy"),
        ("HP:0001250", "Seizure")];
    let e = Moi { hpo_id: "HP:0001250".to_string(), hpo_label: "Seizure".to_string() };
    let f = DiseaseData {
        disease_id: "MONDO:0007947".to_string(),
        disease_label: "Marfan syndrome".to_string(),
    };
    let g = HpoTermDuplet::new(
        "Seizure",
        "HP:0001250",
    );
}
R
cat > "${WORK}/rs_labelfirst/bad.rs" <<'R'
fn f() { let d = HpoTermDuplet::new("Radical Cystoprostatectomy", "NCIT:C5189"); }
R
cat > "${WORK}/rs_field/bad.rs" <<'R'
fn f() -> OntologyClass {
    OntologyClass {
        id: "NCIT:C5189".to_string(),
        label: "Radical Cystoprostatectomy".to_string(),
    }
}
R
cat > "${WORK}/rs_ambig_ok/a.rs" <<'R'
fn f() { let x = row("Seizure", "HP:0001250", "observed"); }
R
cat > "${WORK}/rs_ambig_bad/a.rs" <<'R'
fn f() { let x = row("Marfan syndrome", "HP:0001250", "observed"); }
R
cat > "${WORK}/rs_accession/a.rs" <<'R'
fn f() { let v = VariantDto::hgvs_c("c.8242G>T", "NM_000138.5"); }
R
cat > "${WORK}/rs_boundary/a.rs" <<'R'
fn f() { let v = vec![
        ("Marfan syndrome", "HP:0001250"),
        ("Seizure", "MONDO:0007947")]; }
R

echo ""
echo "── RUST CASES (offline map) ─────────────────────────────────────────────"

# R1 — every Rust shape is read, and the .expect() decoy is not paired
run_tool --offline-map "${MAP}" "${WORK}/rs_good"; rc=$?
if [ $rc -eq 0 ] && has "${WORK}/out" "pairs=3" && has "${WORK}/out" "mismatch=0"; then
  ok "rust: all shapes read (3 distinct pairs), .expect() text not paired -> exit 0"
else bad "rust good fixture should exit 0 with pairs=3 (got exit ${rc})" "${WORK}/out"; fi

# R2 — label-first argument order: the planted #451 pair is caught
run_tool --offline-map "${MAP}" "${WORK}/rs_labelfirst"; rc=$?
if [ $rc -eq 1 ] && has "${WORK}/out" "NCIT:C5189  written='Radical Cystoprostatectomy'  ontology='Breast Extraskeletal Osteosarcoma'"; then
  ok "rust: label-first arguments, planted mismatch -> exit 1"
else bad "rust label-first mismatch should exit 1 (got exit ${rc})" "${WORK}/out"; fi

# R3 — struct fields: id / label across lines, planted mismatch, with its line
run_tool --offline-map "${MAP}" "${WORK}/rs_field"; rc=$?
if [ $rc -eq 1 ] && has "${WORK}/out" "mismatch=1" && has "${WORK}/out" "at bad.rs:3"; then
  ok "rust: struct fields, planted mismatch -> exit 1 at the id line"
else bad "rust struct-field mismatch should exit 1 at bad.rs:3 (got exit ${rc})" "${WORK}/out"; fi

# R4 — a label on both sides: passes when EITHER is the term's label
run_tool --offline-map "${MAP}" "${WORK}/rs_ambig_ok"; rc=$?
if [ $rc -eq 0 ] && has "${WORK}/out" "ok=1" && has "${WORK}/out" "mismatch=0"; then
  ok "rust: label on both sides, preceding one is right -> OK, not a false MISMATCH"
else bad "rust ambiguous-order pair should pass on the preceding label (got exit ${rc})" "${WORK}/out"; fi

# R5 — ...and still bites when NEITHER is
run_tool --offline-map "${MAP}" "${WORK}/rs_ambig_bad"; rc=$?
if [ $rc -eq 1 ] && has "${WORK}/out" "mismatch=1"; then
  ok "rust: label on both sides, neither is right -> MISMATCH (exit 1)"
else bad "rust ambiguous-order pair with no right label should exit 1 (got exit ${rc})" "${WORK}/out"; fi

# R6 — a transcript accession is not an identifier: nothing to check, exit 3
run_tool --offline-map "${MAP}" "${WORK}/rs_accession"; rc=$?
if [ $rc -eq 3 ] && has "${WORK}/out" "EMPTY SCAN"; then
  ok "rust: NM_ accession is not read as an identifier -> exit 3, EMPTY SCAN"
else bad "rust accession-only file should be an empty scan (got exit ${rc})" "${WORK}/out"; fi

# R7 — a label is never borrowed from the neighbouring tuple. Borrowing would
#      pair each identifier with the OTHER tuple's label, which happens to be
#      correct, and report clean.
run_tool --offline-map "${MAP}" "${WORK}/rs_boundary"; rc=$?
if [ $rc -eq 1 ] && has "${WORK}/out" "mismatch=2"; then
  ok "rust: tuple boundary respected -> both swapped labels reported (mismatch=2)"
else bad "rust tuple-boundary fixture should report mismatch=2 (got exit ${rc})" "${WORK}/out"; fi

# R8-R11 -- from the independent review of the first Rust extractor. R8 and R9
# are its two reproductions of a real mismatch reported clean; both were exit 0
# before the fix. R10 and R11 are controls that the fix is not simply stricter.
mkdir -p "${WORK}/rs_m1_shared" "${WORK}/rs_m1_table" "${WORK}/rs_table_labelfirst" "${WORK}/rs_sibling"
cat > "${WORK}/rs_m1_shared/a.rs" <<'R'
fn f() {
    let a = row("Seizure", "HP:0001250", "Marfan syndrome");
}
fn g() {
    let b = pair("HP:0001250", "Marfan syndrome");
}
R
cat > "${WORK}/rs_m1_table/a.rs" <<'R'
const TERMS: [&str; 4] = ["HP:0001250", "Seizure", "HP:0001250", "Marfan syndrome"];
R
cat > "${WORK}/rs_table_labelfirst/a.rs" <<'R'
const TERMS: [&str; 4] = ["Seizure", "HP:0001250", "Marfan syndrome", "MONDO:0007947"];
R
cat > "${WORK}/rs_sibling/a.rs" <<'R'
fn f() -> Vec<T> {
    vec![
        T { id: "MONDO:0007947", label: "Marfan syndrome" },
        T { id: "HP:0001250", name: "x" },
    ]
}
R

# R8 — an ambiguous call must not excuse an unambiguous mismatch in the same file
run_tool --offline-map "${MAP}" "${WORK}/rs_m1_shared"; rc=$?
if [ $rc -eq 1 ] && has "${WORK}/out" "mismatch=1" && has "${WORK}/out" "ok=1" && has "${WORK}/out" "at a.rs:5"; then
  ok "rust: ambiguity is per occurrence -> the plain mismatch at line 5 is still reported"
else bad "rust: one ambiguous call excused a real mismatch elsewhere (got exit ${rc})" "${WORK}/out"; fi

# R9 — a flat identifier-first table: a copy-pasted identifier is caught
run_tool --offline-map "${MAP}" "${WORK}/rs_m1_table"; rc=$?
if [ $rc -eq 1 ] && has "${WORK}/out" "mismatch=1" && has "${WORK}/out" "written='Marfan syndrome'"; then
  ok "rust: flat identifier-first table, repeated identifier -> MISMATCH (exit 1)"
else bad "rust: flat table with a repeated identifier should exit 1 (got exit ${rc})" "${WORK}/out"; fi

# R10 — control: the same table written label-first is entirely correct
run_tool --offline-map "${MAP}" "${WORK}/rs_table_labelfirst"; rc=$?
if [ $rc -eq 0 ] && has "${WORK}/out" "ok=2" && has "${WORK}/out" "pairs=2"; then
  ok "rust: flat label-first table -> both pairs read and OK (control)"
else bad "rust: flat label-first table should be ok=2 pairs=2 (got exit ${rc})" "${WORK}/out"; fi

# R11 — a struct with no label does not borrow its sibling's
run_tool --offline-map "${MAP}" "${WORK}/rs_sibling"; rc=$?
if [ $rc -eq 0 ] && has "${WORK}/out" "pairs=1" && has "${WORK}/out" "mismatch=0"; then
  ok "rust: sibling struct's label is not borrowed -> pairs=1, no false MISMATCH"
else bad "rust: a label was borrowed from a sibling struct (got exit ${rc})" "${WORK}/out"; fi

# R12-R14 -- from the second review. R12 is a false OK that the R11 fix itself
# introduced; R13 is its control; R14 makes a silent skip visible.
mkdir -p "${WORK}/rs_nested_bad" "${WORK}/rs_nested_ok" "${WORK}/rs_trailing"
cat > "${WORK}/rs_nested_bad/a.rs" <<'R'
fn f() -> Term {
    Term {
        id: "HP:0001250",
        parent: Ref { id: "MONDO:0007947" },
        label: "Marfan syndrome",
    }
}
R
cat > "${WORK}/rs_nested_ok/a.rs" <<'R'
fn f() -> Term {
    Term {
        id: "HP:0001250",
        parent: Ref { id: "MONDO:0007947" },
        label: "Seizure",
    }
}
R
cat > "${WORK}/rs_trailing/a.rs" <<'R'
fn f() { let x = alias("HP:0001250", "Seizure", "MONDO:0007947"); }
R

# R12 — a nested inline id neither stops the outer scan nor takes the outer label
run_tool --offline-map "${MAP}" "${WORK}/rs_nested_bad"; rc=$?
if [ $rc -eq 1 ] && has "${WORK}/out" "HP:0001250  written='Marfan syndrome'  ontology='Seizure'" && has "${WORK}/out" "pairs=1"; then
  ok "rust: nested inline struct between id and label -> the outer mismatch is reported"
else bad "rust: a nested inline id hid the outer mismatch (got exit ${rc})" "${WORK}/out"; fi

# R13 — control: with the right outer label the same shape is one clean pair
run_tool --offline-map "${MAP}" "${WORK}/rs_nested_ok"; rc=$?
if [ $rc -eq 0 ] && has "${WORK}/out" "ok=1" && has "${WORK}/out" "pairs=1"; then
  ok "rust: nested inline struct, outer label right -> ok=1 pairs=1 (control)"
else bad "rust: nested inline struct with a right label should be ok=1 pairs=1 (got exit ${rc})" "${WORK}/out"; fi

# R14 — an identifier left without a label is counted out loud, never just dropped
run_tool --offline-map "${MAP}" "${WORK}/rs_trailing"; rc=$?
if [ $rc -eq 0 ] && has "${WORK}/out" "unlabelled ids : 1 distinct Rust identifier with no label beside it"; then
  ok "rust: trailing identifier with no label -> reported as unlabelled, not silently skipped"
else bad "rust: an unpaired identifier should be counted in the header (got exit ${rc})" "${WORK}/out"; fi

# ── Rust LEXER cases ──────────────────────────────────────────────
# One group per string form the reader must know. Each group has a BAD fixture
# (a wrong pair the tool must report) and, where it matters, a control (the
# same shape written right, which must read clean) so a lexer that simply stopped
# finding pairs cannot pass. Every fixture is a shape the old per-line pattern
# lost or misread; the old tool was run against this block to confirm that.
rs_fx() { mkdir -p "${WORK}/$1"; cat > "${WORK}/$1/a.rs"; }

rs_fx lx_raw_bad <<'R'
fn f() {
    let a = pair(r#"HP:0001250"#, r"Marfan syndrome");
    let b = pair(r##"MONDO:0007947"##, r#"Seizure"#);
}
R
rs_fx lx_raw_ok <<'R'
fn f() {
    let a = pair(r#"HP:0001250"#, r"Seizure");
    let b = pair(r##"Marfan syndrome"##, r#"MONDO:0007947"#);
}
R
rs_fx lx_afterraw_bad <<'R'
fn f() { let n = r#"ends in a space "#; let t = pair("HP:0001250", "Marfan syndrome"); }
R
rs_fx lx_afterraw_ok <<'R'
fn f() { let n = r#"ends in a space "#; let t = pair("HP:0001250", "Seizure"); }
R
rs_fx lx_char_bad <<'R'
fn f<'a>(x: &'a str) { let q = '"'; let e = '\''; let t = pair("HP:0001250", "Marfan syndrome"); }
R
rs_fx lx_char_ok <<'R'
fn f<'a>(x: &'a str) { let q = '"'; let e = '\''; let t = pair("HP:0001250", "Seizure"); }
R
rs_fx lx_bchar <<'R'
fn f() { let b = b'"'; let t = pair("HP:0001250", "Marfan syndrome"); }
R
rs_fx lx_multi_bad <<'R'
fn f() {
    let s = "first line
second line.", pair("HP:0001250", "Marfan syndrome");
}
R
rs_fx lx_multi_ok <<'R'
fn f() {
    let s = "first line
second line.", pair("HP:0001250", "Seizure");
}
R
rs_fx lx_cont_bad <<'R'
fn f() { let t = pair("HP:0001250", "Marfan \
        syndrome"); }
R
rs_fx lx_cont_ok <<'R'
fn f() { let t = pair("HP:0001250", "Seiz\
        ure"); }
R
rs_fx lx_blockc_bad <<'R'
fn f() { let t = pair("HP:0001250", /* the term */ "Marfan syndrome"); }
R
rs_fx lx_blockc_ok <<'R'
fn f() { let t = pair("HP:0001250", /* the term */ "Seizure"); }
R
rs_fx lx_blockc_str <<'R'
fn f() { let t = pair("HP:0001250", /* "Seizure" was here */ "Marfan syndrome"); }
R
rs_fx lx_linec_bad <<'R'
fn f() {
    let t = pair("HP:0001250", // the label
        "Marfan syndrome");
}
R
rs_fx lx_incomment <<'R'
// old: pair("HP:0001250", "Marfan syndrome")
fn f() {}
R
rs_fx lx_nested <<'R'
/* outer /* inner */ still "unbalanced */ fn f() { let t = pair("HP:0001250", "Marfan syndrome"); }
R
rs_fx lx_bytes <<'R'
fn f() { let t = pair(b"HP:0001250", "Marfan syndrome"); }
R
rs_fx lx_bytes_ok <<'R'
fn f() { let k = b"skip me"; let t = pair("HP:0001250", "Seizure"); let u = br#"HP:0001250"#; }
R
rs_fx lx_json <<'R'
fn f() { let j = r#"{"hpoId": "HP:0001250", "note": "Marfan syndrome"}"#; }
R
# A red control from review: a wrong pair inside a raw blob, the SAME identifier paired
# correctly in another file. Per-distinct-id counting hid this one.
mkdir -p "${WORK}/lx_rawdup"
cat > "${WORK}/lx_rawdup/a.rs" <<'R'
fn a() { let t = r#"{
  "terms": ["HP:0001250", "Marfan syndrome"]
}"#; }
fn b() { let u = r#"["HP:0001250", "Thick eyebrow"]"#; }
R
cat > "${WORK}/lx_rawdup/b.rs" <<'R'
fn c() { f("HP:0001250", "Seizure"); }
R
mkdir -p "${WORK}/lx_rawdup_ok"
cat > "${WORK}/lx_rawdup_ok/a.rs" <<'R'
fn a() { let t = r#"{
  "terms": ["HP:0001250", "Seizure"]
}"#; }
R
cat > "${WORK}/lx_rawdup_ok/b.rs" <<'R'
fn c() { f("HP:0001250", "Seizure"); }
R
# From review: the JSON OBJECT form, id paired right in another file.
mkdir -p "${WORK}/lx_jsonobj" "${WORK}/lx_jsonobj_ok"
cat > "${WORK}/lx_jsonobj/a.rs" <<'R'
fn a() { let t = r#"{"id": "HP:0001250", "label": "Thick eyebrow"}"#; }
fn b() { let u = r#"{
  "label": "Marfan syndrome",
  "id": "HP:0001250"
}"#; }
R
cat > "${WORK}/lx_jsonobj/b.rs" <<'R'
fn c() { f("HP:0001250", "Seizure"); }
R
cat > "${WORK}/lx_jsonobj_ok/a.rs" <<'R'
fn a() { let t = r#"{"id": "HP:0001250", "label": "Seizure", "note": "Marfan syndrome"}"#; }
R
cat > "${WORK}/lx_jsonobj_ok/b.rs" <<'R'
fn c() { f("HP:0001250", "Seizure"); }
R
rs_fx lx_unicode <<'R'
fn f() { let é = 1; /* über naïve */ let t = pair("HP:0001250", "Marfan syndrome"); }
R
rs_fx lx_lostsync <<'R'
fn a() { pair("HP:0001250", "Marfan syndrome"); }
fn b() { let q = "oops; }
R

echo ""
echo "── RUST LEXER CASES (offline map) ───────────────────────────────────────"

# L1 -- raw strings are strings: both the identifier and the label can be one
run_tool --offline-map "${MAP}" "${WORK}/lx_raw_bad"; rc=$?
if [ $rc -eq 1 ] && has "${WORK}/out" "mismatch=2" && has "${WORK}/out" "written='Marfan syndrome'"; then
  ok "lexer: raw r\"..\", r#\"..\"#, r##\"..\"## read as identifier and label -> wrong pairs reported"
else bad "lexer: raw-string wrong pairs should be mismatch=2 (got exit ${rc})" "${WORK}/out"; fi
run_tool --offline-map "${MAP}" "${WORK}/lx_raw_ok"; rc=$?
if [ $rc -eq 0 ] && has "${WORK}/out" "ok=2" && has "${WORK}/out" "pairs=2"; then
  ok "lexer: raw strings, right labels, either order -> ok=2 pairs=2 (control)"
else bad "lexer: raw-string right pairs should be ok=2 pairs=2 (got exit ${rc})" "${WORK}/out"; fi

# L1b -- a WRONG pair on the same line, right after a raw string full of quotes
run_tool --offline-map "${MAP}" "${WORK}/lx_afterraw_bad"; rc=$?
if [ $rc -eq 1 ] && has "${WORK}/out" "mismatch=1" && has "${WORK}/out" "at a.rs:1"; then
  ok "lexer: wrong pair after a raw string on the same line -> reported (exit 1)"
else bad "lexer: a raw string's quotes hid a wrong pair on its line (got exit ${rc})" "${WORK}/out"; fi
run_tool --offline-map "${MAP}" "${WORK}/lx_afterraw_ok"; rc=$?
if [ $rc -eq 0 ] && has "${WORK}/out" "ok=1" && has "${WORK}/out" "pairs=1"; then
  ok "lexer: right pair after a raw string on the same line -> ok=1 (control)"
else bad "lexer: right pair after a raw string should be ok=1 pairs=1 (got exit ${rc})" "${WORK}/out"; fi

# L2 -- char literals and lifetimes do not open or close a string
run_tool --offline-map "${MAP}" "${WORK}/lx_char_bad"; rc=$?
if [ $rc -eq 1 ] && has "${WORK}/out" "mismatch=1" && has "${WORK}/out" "at a.rs:1"; then
  ok "lexer: '\"' '\\'' b'\"' and a lifetime before a wrong pair -> reported (exit 1)"
else bad "lexer: char literals desynced the reader (got exit ${rc})" "${WORK}/out"; fi
run_tool --offline-map "${MAP}" "${WORK}/lx_char_ok"; rc=$?
if [ $rc -eq 0 ] && has "${WORK}/out" "ok=1" && has "${WORK}/out" "pairs=1"; then
  ok "lexer: same line with the right label -> ok=1 pairs=1 (control)"
else bad "lexer: char-literal control should be ok=1 pairs=1 (got exit ${rc})" "${WORK}/out"; fi

run_tool --offline-map "${MAP}" "${WORK}/lx_bchar"; rc=$?
if [ $rc -eq 1 ] && has "${WORK}/out" "mismatch=1" && has "${WORK}/out" "at a.rs:1"; then
  ok "lexer: byte char literal b'\"' before a wrong pair -> reported (exit 1)"
else bad "lexer: b'\"' desynced the reader (got exit ${rc})" "${WORK}/out"; fi

# L3 -- a multi-line string is one string; the pair on its closing line is found
run_tool --offline-map "${MAP}" "${WORK}/lx_multi_bad"; rc=$?
if [ $rc -eq 1 ] && has "${WORK}/out" "mismatch=1" && has "${WORK}/out" "at a.rs:3"; then
  ok "lexer: wrong pair on the closing line of a multi-line string -> reported at line 3"
else bad "lexer: multi-line string hid the pair on its closing line (got exit ${rc})" "${WORK}/out"; fi
run_tool --offline-map "${MAP}" "${WORK}/lx_multi_ok"; rc=$?
if [ $rc -eq 0 ] && has "${WORK}/out" "ok=1" && has "${WORK}/out" "pairs=1"; then
  ok "lexer: multi-line string, right label on the closing line -> ok=1 (control)"
else bad "lexer: multi-line control should be ok=1 pairs=1 (got exit ${rc})" "${WORK}/out"; fi
run_tool --offline-map "${MAP}" "${WORK}/lx_cont_bad"; rc=$?
if [ $rc -eq 1 ] && has "${WORK}/out" "written='Marfan syndrome'"; then
  ok "lexer: label continued with a trailing backslash is one label -> wrong one reported"
else bad "lexer: a backslash-continued label was not read (got exit ${rc})" "${WORK}/out"; fi
run_tool --offline-map "${MAP}" "${WORK}/lx_cont_ok"; rc=$?
if [ $rc -eq 0 ] && has "${WORK}/out" "ok=1" && has "${WORK}/out" "pairs=1"; then
  ok "lexer: 'Seiz\\<newline>   ure' joins to 'Seizure' -> ok=1 (control)"
else bad "lexer: continuation should join to Seizure (got exit ${rc})" "${WORK}/out"; fi

# L4 -- comments
run_tool --offline-map "${MAP}" "${WORK}/lx_blockc_bad"; rc=$?
if [ $rc -eq 1 ] && has "${WORK}/out" "mismatch=1" && has "${WORK}/out" "written='Marfan syndrome'"; then
  ok "lexer: block comment between two arguments does not stop them pairing -> wrong pair reported"
else bad "lexer: a block comment between arguments broke the pairing (got exit ${rc})" "${WORK}/out"; fi
run_tool --offline-map "${MAP}" "${WORK}/lx_blockc_ok"; rc=$?
if [ $rc -eq 0 ] && has "${WORK}/out" "ok=1" && has "${WORK}/out" "pairs=1"; then
  ok "lexer: block comment between arguments, right label -> ok=1 (control)"
else bad "lexer: block-comment control should be ok=1 pairs=1 (got exit ${rc})" "${WORK}/out"; fi
# The string INSIDE the comment must not become the label: if it did, HP:0001250
# would take "Seizure" and this wrong pair would read clean.
run_tool --offline-map "${MAP}" "${WORK}/lx_blockc_str"; rc=$?
if [ $rc -eq 1 ] && has "${WORK}/out" "mismatch=1" && has "${WORK}/out" "written='Marfan syndrome'"; then
  ok "lexer: a string inside a comment between arguments is not borrowed as the label"
else bad "lexer: a commented-out label excused a wrong pair (got exit ${rc})" "${WORK}/out"; fi
run_tool --offline-map "${MAP}" "${WORK}/lx_linec_bad"; rc=$?
if [ $rc -eq 1 ] && has "${WORK}/out" "mismatch=1" && has "${WORK}/out" "at a.rs:2"; then
  ok "lexer: line comment between arguments across a newline -> still paired (exit 1)"
else bad "lexer: a line comment between arguments broke the pairing (got exit ${rc})" "${WORK}/out"; fi
run_tool --offline-map "${MAP}" "${WORK}/lx_incomment"; rc=$?
if [ $rc -eq 1 ] && has "${WORK}/out" "mismatch=1" && has "${WORK}/out" "at a.rs:1"; then
  ok "lexer: code inside a comment is still read (as the other extractors do)"
else bad "lexer: a pair inside a comment should still be read (got exit ${rc})" "${WORK}/out"; fi
run_tool --offline-map "${MAP}" "${WORK}/lx_nested"; rc=$?
if [ $rc -eq 1 ] && has "${WORK}/out" "mismatch=1"; then
  ok "lexer: nested block comment, unbalanced quote inside it -> the pair after it is found"
else bad "lexer: a nested block comment desynced the reader (got exit ${rc})" "${WORK}/out"; fi

# L5 -- byte strings are skipped, not misread
run_tool --offline-map "${MAP}" "${WORK}/lx_bytes"; rc=$?
if [ $rc -eq 3 ] && has "${WORK}/out" "EMPTY SCAN"; then
  ok "lexer: b\"HP:..\" is bytes, not an identifier -> nothing paired (exit 3, EMPTY SCAN)"
else bad "lexer: a byte string was read as text (got exit ${rc})" "${WORK}/out"; fi
run_tool --offline-map "${MAP}" "${WORK}/lx_bytes_ok"; rc=$?
if [ $rc -eq 0 ] && has "${WORK}/out" "ok=1" && has "${WORK}/out" "pairs=1" && hasnt "${WORK}/out" "lexer warnings"; then
  ok "lexer: byte and raw-byte strings around a real pair are skipped, pair read (control)"
else bad "lexer: byte-string control should be ok=1 pairs=1 (got exit ${rc})" "${WORK}/out"; fi

# L6 -- JSON inside a raw string is not paired by accident, and not forgotten
run_tool --offline-map "${MAP}" "${WORK}/lx_json"; rc=$?
if [ $rc -eq 3 ] && has "${WORK}/out" "EMPTY SCAN" && has "${WORK}/out" "unlabelled ids : 1 distinct"; then
  ok "lexer: identifier inside a raw JSON blob is not paired with a JSON key, and is counted unchecked"
else bad "lexer: raw JSON blob should be unpaired but counted (got exit ${rc})" "${WORK}/out"; fi

# L6b -- review finding (high): wrong pair in a raw blob, identifier also paired elsewhere
run_tool --offline-map "${MAP}" "${WORK}/lx_rawdup"; rc=$?
if [ $rc -eq 1 ] && has "${WORK}/out" "mismatch=2" && has "${WORK}/out" "at a.rs:2" && has "${WORK}/out" "at a.rs:4"; then
  ok "lexer: wrong pair inside a raw string is reported even when the id is paired elsewhere (exit 1)"
else bad "lexer: raw-string wrong pair hidden by a correct pair elsewhere (got exit ${rc})" "${WORK}/out"; fi
run_tool --offline-map "${MAP}" "${WORK}/lx_rawdup_ok"; rc=$?
if [ $rc -eq 0 ] && has "${WORK}/out" "ok=2" && has "${WORK}/out" "mismatch=0"; then
  ok "lexer: right pair inside a raw string + right pair elsewhere -> ok=2 (control)"
else bad "lexer: right raw-string pair should be ok (got exit ${rc})" "${WORK}/out"; fi

# L6c -- from review: wrong pair in a JSON OBJECT in a raw string, id also paired elsewhere
run_tool --offline-map "${MAP}" "${WORK}/lx_jsonobj"; rc=$?
if [ $rc -eq 1 ] && has "${WORK}/out" "'Thick eyebrow'" && has "${WORK}/out" "'Marfan syndrome'"; then
  ok "lexer: wrong pair in a JSON object in a raw string is reported, either key order (exit 1)"
else bad "lexer: JSON-object wrong pair hidden by a correct pair elsewhere (got exit ${rc})" "${WORK}/out"; fi
run_tool --offline-map "${MAP}" "${WORK}/lx_jsonobj_ok"; rc=$?
if [ $rc -eq 0 ] && has "${WORK}/out" "mismatch=0" && hasnt "${WORK}/out" "Marfan"; then
  ok "lexer: right JSON-object pair; an unrelated 'note' value is not taken for a label (control)"
else bad "lexer: right JSON-object pair should be clean (got exit ${rc})" "${WORK}/out"; fi

# From review: a raw blob inside a COMMENT, id paired right elsewhere
mkdir -p "${WORK}/lx_cblob" "${WORK}/lx_cblob2"
cat > "${WORK}/lx_cblob/a.rs" <<'R'
// let t = r#"["HP:0001250", "Thick eyebrow"]"#;
fn a() {}
R
cat > "${WORK}/lx_cblob2/a.rs" <<'R'
/* old: let t = r#"["HP:0001250", "Thick eyebrow"]"#; */
fn a() {}
R
for d in lx_cblob lx_cblob2; do cp "${WORK}/lx_rawdup_ok/b.rs" "${WORK}/${d}/b.rs"; done
for d in lx_cblob lx_cblob2; do
  run_tool --offline-map "${MAP}" "${WORK}/${d}"; rc=$?
  if [ $rc -eq 1 ] && has "${WORK}/out" "'Thick eyebrow'"; then
    ok "lexer: wrong pair in a raw blob inside a comment is reported, id paired elsewhere (${d})"
  else bad "lexer: commented-out raw blob hid a wrong pair (${d}, got exit ${rc})" "${WORK}/out"; fi
done

# finding 2: shapes the reader does not pair must still be COUNTED, per occurrence
mkdir -p "${WORK}/lx_occ" "${WORK}/lx_occ2"
cat > "${WORK}/lx_occ/a.rs" <<'R'
fn a() { let t = r#"{"id": "HP:0001250", "excluded": false, "label": "Thick eyebrow"}"#; }
R
cat > "${WORK}/lx_occ2/a.rs" <<'R'
fn a() { let t = r#"{"id": "HP:0001250", "prefLabel": "Thick eyebrow"}"#; }
R
for d in lx_occ lx_occ2; do cp "${WORK}/lx_rawdup_ok/b.rs" "${WORK}/${d}/b.rs"; done
run_tool --offline-map "${MAP}" "${WORK}/lx_occ"; rc=$?
if has "${WORK}/out" "unlabelled ids : 1 distinct"; then
  ok "lexer: an id in a shape the reader does not pair is counted unchecked though paired elsewhere"
else bad "lexer: unpaired occurrence vanished because the id is paired elsewhere (exit ${rc})" "${WORK}/out"; fi
run_tool --offline-map "${MAP}" "${WORK}/lx_occ2"; rc=$?
if [ $rc -eq 1 ] && has "${WORK}/out" "'Thick eyebrow'"; then
  ok "lexer: a key ending in 'label' (prefLabel) is read as the label (exit 1)"
else bad "lexer: prefLabel pair not read (exit ${rc})" "${WORK}/out"; fi

# From a second review: a quote before an id that is NOT a token must not hide it
mkdir -p "${WORK}/lx_qid" "${WORK}/lx_qid2"
cat > "${WORK}/lx_qid/a.rs" <<'R'
fn a() { let t = r#"{"HP:0001250": "Thick eyebrow"}"#; }
R
cat > "${WORK}/lx_qid2/a.rs" <<'R'
fn a() { let t = r#"{\"id\":\"HP:0001250\",\"label\":\"Thick eyebrow\"}"#; }
R
for d in lx_qid lx_qid2; do
  cp "${WORK}/lx_rawdup_ok/b.rs" "${WORK}/${d}/b.rs"
  run_tool --offline-map "${MAP}" "${WORK}/${d}"
  if has "${WORK}/out" "unlabelled ids : 1 distinct"; then
    ok "lexer: a quoted id that is not a token still counts as unchecked, paired elsewhere (${d})"
  else bad "lexer: quoted non-token id vanished from the count (${d})" "${WORK}/out"; fi
done

# Round 4: an id at the START of a longer quoted string. And the ACCOUNTING RULE
# as a test: over every raw-string case, occurrences == paired + unchecked, the
# occurrence total equals what grep finds in the fixture, and the unchecked total
# equals the number the header prints. A dropped occurrence fails whatever its shape.
mkdir -p "${WORK}/lx_longstr" "${WORK}/lx_longstr2"
cat > "${WORK}/lx_longstr/a.rs" <<'R'
fn a() { let t = r#"["HP:0001250 Thick eyebrow"]"#; }
R
cat > "${WORK}/lx_longstr2/a.rs" <<'R'
fn a() { let t = r#"{"text": "HP:0001250 - Thick eyebrow"}"#; }
R
for d in lx_longstr lx_longstr2; do cp "${WORK}/lx_rawdup_ok/b.rs" "${WORK}/${d}/b.rs"; done
for d in lx_longstr lx_longstr2; do
  run_tool --offline-map "${MAP}" "${WORK}/${d}"
  if has "${WORK}/out" "unlabelled ids : 1 distinct"; then
    ok "lexer: an id at the start of a longer quoted string is counted unchecked (${d})"
  else bad "lexer: id at the start of a longer string vanished (${d})" "${WORK}/out"; fi
done
# Round 5: raw BYTE and raw C strings, and every counted shape from the review.
# Each fixture holds ONLY raw-string ids, so a grep over a.rs is the truth.
accfx() { mkdir -p "${WORK}/$1"; cat > "${WORK}/$1/a.rs"; }
accfx lx_br <<'R'
fn a() { let t = br#"HP:0001250"#; }
R
accfx lx_cr <<'R'
fn a() { let t = cr#"{"id": "HP:0001250", "label": "Thick eyebrow"}"#; }
R
accfx lx_brcr2 <<'R'
fn a() { let t = br##"["HP:0001250", "MONDO:0007947"]"##; let u = cr"HP:0001250"; }
R
accfx lx_glued_after <<'R'
fn a() { let t = r#"HP:0001250abc"#; }
R
accfx lx_url <<'R'
fn a() { let t = r#"http://purl.example.org/obo/HP:0001250"#; }
R
accfx lx_four <<'R'
fn a() { let t = r#"HP:0001250 HP:0001250 MONDO:0007947 MONDO:0007947"#; }
R
accfx lx_trail <<'R'
fn a() { let t = r#"HP:0001250. HP:0001250- MONDO:0007947."#; }
R
accfx lx_taxon <<'R'
fn a() { let t = r#"["NCBITaxon:9606", "SCTID:12345"]"#; }
R
accfx lx_accent <<'R'
fn a() { let t = r#"ÉHP:0001250É"#; }
R
for d in lx_br lx_cr lx_brcr2 lx_glued_after lx_url lx_four lx_trail lx_taxon lx_accent; do
  cp "${WORK}/lx_rawdup_ok/b.rs" "${WORK}/${d}/b.rs"
done
ACC_BAD=0; ACC_N=0
for d in lx_raw_bad lx_raw_ok lx_json lx_rawdup lx_rawdup_ok lx_jsonobj lx_jsonobj_ok lx_cblob lx_cblob2 \
         lx_occ lx_occ2 lx_qid lx_qid2 lx_longstr lx_longstr2 \
         lx_br lx_cr lx_brcr2 lx_glued_after lx_url lx_four lx_trail lx_taxon lx_accent; do
  ACC_N=$((ACC_N+1))
  "${TOOL}" --offline-map "${MAP}" --json "${WORK}/acc.json" "${WORK}/${d}" > "${WORK}/out" 2>&1
  # The truth is a plain search of every file in the case, made by grep and not by the tool.
  truth=$(cat "${WORK}/${d}"/*.rs | grep -o -E 'HP:[0-9]{7}|MONDO:[0-9]{7}|NCBITaxon:9606|SCTID:12345' | wc -l | tr -d ' ')
  verdict=$(python3 - "${WORK}/acc.json" "${WORK}/out" "${truth}" <<'PYE'
import json, re, sys
j = json.load(open(sys.argv[1]))["rust_ids"]
out = open(sys.argv[2]).read()
truth = int(sys.argv[3])
m = re.search(r"unlabelled ids : (\d+) distinct.*?(?:\[(\d+) occurrences\])?\n", out)
hdr = (int(m.group(2)) if m and m.group(2) else int(m.group(1))) if m else 0
ok = (j["occurrences"] == truth and j["paired"] + j["unchecked"] == j["occurrences"]
      and j["unchecked"] == hdr)
print("OK" if ok else "BAD occ=%s paired=%s unchecked=%s truth=%s header=%s" % (j["occurrences"], j["paired"], j["unchecked"], truth, hdr))
PYE
)
  [ "${verdict}" = "OK" ] || { ACC_BAD=$((ACC_BAD+1)); printf '        accounting %s: %s\n' "${d}" "${verdict}"; }
done
# WHOLE-FILE ACCOUNTING (after five review rounds on one class of fault). Shapes
# that used to be dropped without a word are now each counted, because the count
# is a search of the text and no longer a question asked shape by shape. Each case
# states how many occurrences it holds; the one shape that still cannot be seen
# (an identifier split across two lines) is pinned at 0 so the limit is a tested fact.
accfx lx_w_underscore <<'R'
fn a() { let t = r#"HP_0001250 http://purl.obolibrary.org/obo/HP_0001250"#; }
R
accfx lx_w_glued_us <<'R'
fn a() { let t = r#"term_HP:0001250"#; }
R
accfx lx_w_glued_alnum <<'R'
fn a() { let t = r#"9HP:0001250 XHP:0001250"#; }
R
accfx lx_w_split <<'R'
fn a() { let t = r#"HP:
0001250"#; }
R
accfx lx_w_plain_mid <<'R'
fn a() { let t = "see HP:0001250 here"; let u = "HP:0001250 Thick eyebrow"; }
R
accfx lx_w_bytes <<'R'
fn a() { let t = b"HP:0001250"; let u = c"HP:0001250 x"; }
R
accfx lx_w_comment <<'R'
// HP:0001250 is mentioned here, and again: HP:0001250
/* and MONDO:0007947 in a block /* nested HP:0001250 */ */
fn a() {}
R
accfx lx_w_transcript <<'R'
fn a() { let t = "NM_000138.5 and ENST_0001 are not ontology terms"; }
R
accfx lx_w_code <<'R'
struct S { hp: u8 } fn a() -> S { S { hp:1 } }
R
W_BAD=0
wcase() { # <dir> <occurrences> <unchecked>
  "${TOOL}" --offline-map "${MAP}" --json "${WORK}/w.json" "${WORK}/$1" > "${WORK}/out" 2>&1
  python3 - "${WORK}/w.json" "$2" "$3" <<'PYE' || { W_BAD=$((W_BAD+1)); printf '        whole-file accounting %s: wanted occurrences=%s unchecked=%s\n' "$1" "$2" "$3"; }
import json, sys
j = json.load(open(sys.argv[1]))["rust_ids"]
sys.exit(0 if (j["occurrences"], j["unchecked"], j["paired"]) == (int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[2]) - int(sys.argv[3])) else 1)
PYE
}
wcase lx_w_underscore 2 2      # underscore spelling and the PURL tail
wcase lx_w_glued_us 1 1        # an underscore before the prefix does not hide it
wcase lx_w_glued_alnum 0 0     # a letter or digit before it makes it part of a longer word
wcase lx_w_split 0 0           # the one stated blind spot
wcase lx_w_plain_mid 2 2       # mid-string and start-of-string, in PLAIN strings
wcase lx_w_bytes 2 2           # plain byte and C strings
wcase lx_w_comment 4 4         # bare identifiers in line and nested block comments
wcase lx_w_transcript 0 0      # an underscore accession with an unknown prefix is not a term
wcase lx_w_code 0 0            # `hp:1` in code, outside any string or comment, is not text
# Found in review of the first version of this pass, each red there:
accfx lx_w_us_after <<'R'
fn a() { let s = "HP:0001250_label"; }
R
accfx lx_w_joined <<'R'
fn a() { let s = "HP:0001250-HP:0001251"; let t = "HP:0001250.MONDO:0007947"; }
R
accfx lx_w_unclosed <<'R'
fn a() { let s = "HP:0001250 oops; }
R
accfx lx_w_unclosed_raw <<'R'
fn a() { let s = r#"HP:0001250 never
R
accfx lx_w_field <<'R'
fn a() { let x = S { hpo_id: "HP:0001250", hpo_label: "Seizure" }; }
R
accfx lx_w_field_twice <<'R'
fn a() { let x = S { hpo_id: "HP:0001250".into(), hpo_label: "Seizure".into() }; assert_eq!(y, "HP:0001250"); }
R
wcase lx_w_us_after 1 1        # an underscore AFTER the identifier does not hide it
wcase lx_w_joined 4 4          # two identifiers joined by - or . are two
run_tool --offline-map "${MAP}" "${WORK}/lx_w_joined"
if has "${WORK}/out" "unlabelled ids : 3 distinct"; then
  ok "accounting: joined identifiers are named as themselves (3 distinct of 4 occurrences), not as one mangled id"
else bad "accounting: a joined identifier was named with its neighbour's prefix attached" "${WORK}/out"; fi
wcase lx_w_unclosed 1 1        # after a string that never closes, the rest of the file is searched
wcase lx_w_unclosed_raw 1 1    # the same for a raw string
wcase lx_w_field 1 0           # the struct-field reader's pair is PAIRED
wcase lx_w_field_twice 2 1     # ...and a second use of that identifier on the same line is NOT
if [ ${W_BAD} -eq 0 ]; then
  ok "accounting: fifteen shapes outside raw strings each give the stated count (plain, byte, C, comments, underscore, PURL, joined, unclosed, struct fields)"
else bad "accounting: ${W_BAD} whole-file case(s) gave a different count"; fi
# A paired identifier is PAIRED and nothing else: one right pair, one occurrence, none unchecked.
accfx lx_w_pair <<'R'
fn a() { f("HP:0001250", "Seizure"); }
R
wcase lx_w_pair 1 0
if [ ${W_BAD} -eq 0 ]; then ok "accounting: a paired identifier is counted once, as paired"
else bad "accounting: a plain right pair was miscounted"; fi
if [ ${ACC_BAD} -eq 0 ]; then
  ok "accounting: occurrences = paired + unchecked = grep truth over every file = header, over ${ACC_N} cases"
else bad "accounting: ${ACC_BAD} of ${ACC_N} raw-string cases dropped or invented an occurrence"; fi

# finding 3: pasted escaped JSON in a raw string must not go quadratic
python3 - "${WORK}/lx_esc" <<'PYE'
import os, sys
d = sys.argv[1]; os.makedirs(d, exist_ok=True)
open(d + "/a.rs", "w").write('fn a() { let t = r#"' + '\\"x\\": 1, ' * 12000 + '"#; f("HP:0001250", "Seizure"); }\n')
PYE
if python3 - "${TOOL}" "${WORK}/lx_esc" "${MAP}" <<'PYE'
import subprocess, sys
try:
    subprocess.run([sys.argv[1], "--offline-map", sys.argv[3], sys.argv[2]], capture_output=True, timeout=10)
except subprocess.TimeoutExpired:
    sys.exit(1)
PYE
then ok "lexer: 130 KB raw blob of escaped quotes scans in under 10 s (was quadratic)"
else bad "lexer: escaped-quote blob did not finish in 10 s" "${WORK}/out"; fi

# From a real run -- word:word strings in ordinary code are not identifiers. Set aside
# only: unknown ALL-LOWERCASE prefix AND no digit in the local part. Counted, never OK.
mkdir -p "${WORK}/ns_only" "${WORK}/ns_real" "${WORK}/ns_bad" "${WORK}/ns_digit" "${WORK}/ns_known"
cat > "${WORK}/ns_only/A.java" <<'R'
class A { void f() { g("enable:sort", "off"); g("obo:id", "oboId"); } }
R
cat > "${WORK}/ns_real/A.java" <<'R'
class A { void f() { g("enable:sort", "off"); g("HP:0001250", "Seizure"); } }
R
cat > "${WORK}/ns_bad/A.java" <<'R'
class A { void f() { g("pg:catalog", "pg_extension"); g("HP:0001250", "Marfan syndrome"); } }
R
cat > "${WORK}/ns_digit/A.java" <<'R'
class A { void f() { g("B:1", "x"); } }
R
cat > "${WORK}/ns_known/A.java" <<'R'
class A { void f() { g("HP:abc", "Seizure"); } }
R
run_tool --offline-map "${MAP}" "${WORK}/ns_only"; rc=$?
if [ $rc -eq 3 ] && has "${WORK}/out" "not id-shaped  : 2 pairs" && has "${WORK}/out" "set aside as not identifier-shaped" && hasnt "${WORK}/out" "UNRESOLVED"; then
  ok "shape: word:word code strings are set aside and counted, not UNRESOLVED (empty scan, exit 3, not a pass)"
else bad "shape: code-shaped strings should be counted as not id-shaped (got exit ${rc})" "${WORK}/out"; fi
run_tool --offline-map "${MAP}" "${WORK}/ns_real"; rc=$?
if [ $rc -eq 0 ] && has "${WORK}/out" "ok=1" && has "${WORK}/out" "not id-shaped  : 1 pair "; then
  ok "shape: real pair is judged OK while the code-shaped string is counted aside, in the header"
else bad "shape: real pair beside a code string (got exit ${rc})" "${WORK}/out"; fi
run_tool --offline-map "${MAP}" "${WORK}/ns_bad"; rc=$?
if [ $rc -eq 1 ] && has "${WORK}/out" "mismatch=1"; then
  ok "shape: a wrong pair beside a code-shaped string is still a MISMATCH (exit 1)"
else bad "shape: wrong pair hidden by the set-aside rule (got exit ${rc})" "${WORK}/out"; fi
run_tool --offline-map "${MAP}" "${WORK}/ns_digit"; rc=$?
if [ $rc -eq 4 ] && has "${WORK}/out" "unknown-prefix:B" && hasnt "${WORK}/out" "not id-shaped"; then
  ok "shape: unknown prefix WITH a digit stays UNRESOLVED (exit 4), not set aside (limit of the rule)"
else bad "shape: B:1 must remain UNRESOLVED (got exit ${rc})" "${WORK}/out"; fi
# From review: a real identifier with a digit-free local part (gene symbol) must
# never become VERDICT OK. Capitalised prefixes are never set aside.
mkdir -p "${WORK}/ns_hgnc" "${WORK}/ns_hgnc2" "${WORK}/ns_hgncjson" "${WORK}/ns_cap"
for d in ns_hgnc ns_hgnc2 ns_hgncjson ns_cap; do
  cat > "${WORK}/${d}/ok.java" <<'R'
class B { void f() { g("HP:0001250", "Seizure"); } }
R
done
cat > "${WORK}/ns_hgnc/A.java" <<'R'
class A { void f() { g("HGNC:CFTR", "Totally wrong label"); } }
R
cat > "${WORK}/ns_hgnc2/A.java" <<'R'
class A { void f() { g("HGNC:HLA-A", "Totally wrong label"); } }
R
cat > "${WORK}/ns_hgncjson/a.json" <<'R'
{"type": {"id": "HGNC:CFTR", "label": "Totally wrong label"}}
R
cat > "${WORK}/ns_cap/A.java" <<'R'
class A { void f() { g("Some:value", "x"); g("enable:sort", "off"); } }
R
for d in ns_hgnc ns_hgnc2 ns_hgncjson; do
  run_tool --offline-map "${MAP}" "${WORK}/${d}"; rc=$?
  if [ $rc -eq 4 ] && has "${WORK}/out" "unknown-prefix:HGNC" && hasnt "${WORK}/out" "VERDICT OK"; then
    ok "shape: capitalised unknown prefix, no digit (${d}) stays UNRESOLVED exit 4, never OK"
  else bad "shape: ${d} must stay UNRESOLVED exit 4 (got exit ${rc})" "${WORK}/out"; fi
done
run_tool --offline-map "${MAP}" "${WORK}/ns_cap"; rc=$?
if [ $rc -eq 4 ] && has "${WORK}/out" "unknown-prefix:Some" && has "${WORK}/out" "not id-shaped  : 1 pair "; then
  ok "shape: Some:value stays UNRESOLVED while enable:sort beside it is set aside"
else bad "shape: capitalised code string must stay judged (got exit ${rc})" "${WORK}/out"; fi
"${TOOL}" --offline-map "${MAP}" --json "${WORK}/ns.json" "${WORK}/ns_only" > /dev/null 2>&1
if python3 - "${WORK}/ns.json" <<'PYE'
import json, sys
j = json.load(open(sys.argv[1]))
l = j["not_identifier_shaped_pairs"]
sys.exit(0 if j["counts"]["not_identifier_shaped"] == len(l) == 2 and all(x["file"] and x["line"] for x in l) else 1)
PYE
then ok "shape: the JSON lists every pair that was set aside, with file and line"
else bad "shape: JSON does not list the set-aside pairs"; fi
run_tool --offline-map "${MAP}" "${WORK}/ns_known"; rc=$?
if [ $rc -eq 4 ] && has "${WORK}/out" "HP:abc" && hasnt "${WORK}/out" "not id-shaped"; then
  ok "shape: known prefix with a bad local part (HP:abc) is still judged, never set aside"
else bad "shape: HP:abc must still be judged (got exit ${rc})" "${WORK}/out"; fi

# L7 -- non-ASCII text outside strings (found on the real tree: it crashed the lexer)
run_tool --offline-map "${MAP}" "${WORK}/lx_unicode"; rc=$?
if [ $rc -eq 1 ] && has "${WORK}/out" "mismatch=1" && hasnt "${WORK}/out" "Traceback"; then
  ok "lexer: non-ASCII identifier and comment text -> no crash, wrong pair reported"
else bad "lexer: non-ASCII source broke the lexer (got exit ${rc})" "${WORK}/out"; fi

# L8 -- losing sync is said out loud, and what came before it is still read
run_tool --offline-map "${MAP}" "${WORK}/lx_lostsync"; rc=$?
if [ $rc -eq 1 ] && has "${WORK}/out" "lexer warnings : 1 place" && has "${WORK}/out" "a.rs:2" && has "${WORK}/out" "mismatch=1"; then
  ok "lexer: a string that never closes -> warning in the header naming a.rs:2, earlier pair still read"
else bad "lexer: an unterminated string should warn, not pass silently (got exit ${rc})" "${WORK}/out"; fi

# ── script and Markdown ───────────────────────────────────────────
# Shapes taken from a real TypeScript project on which the tool read 187 files
# and found no pair. Every "must NOT pair" line below is written so that pairing
# it would change the verdict of its case.
#
# expect <exit> <dir> <name> <needle>...   a needle starting with ! must be ABSENT
expect() {
  local want="$1" dir="$2" name="$3" miss=""; shift 3
  run_tool --offline-map "${MAP}" "${WORK}/${dir}"; local rc=$?
  [ $rc -eq "$want" ] || miss="exit ${rc}, wanted ${want}"
  local n
  for n in "$@"; do
    case "$n" in
      '!'*) hasnt "${WORK}/out" "${n#!}" || miss="${miss}; has '${n#!}'" ;;
      *)    has   "${WORK}/out" "$n"     || miss="${miss}; lacks '$n'" ;;
    esac
  done
  if [ -z "$miss" ]; then ok "$name"; else bad "$name (${miss})" "${WORK}/out"; fi
}
for d in sc_good sc_bad_obj sc_bad_stem sc_bad_call sc_bad_chain sc_table sc_bad_table sc_bad_comment \
         sc_under sc_unknown sc_lost sc_pos sc_tsx sc_ambig sc_ambig_bad md_good md_bad_link md_bad_fence \
         md_notscript sc_acc md_acc sc_name sc_unclosed sc_lostbc md_fence_char; do mkdir -p "${WORK}/${d}"; done

cat > "${WORK}/sc_good/a.ts" <<'T'
export const A = [
  { id: 'HP:0001250', label: 'Seizure', selected: false },
  { hpoId: "HP:0001250" as any, status: 'observed' as any, hpoLabel: `Seizure` },
  {
    diseaseId: 'MONDO:0007947',
    diseaseName: 'Marfan syndrome',
    hpoId: 'HP:0001250',
    hpoLabel: 'Seizure',
  },
  // className is not a label
  { id: 'NCIT:C51899', className: 'Breast Extraskeletal Osteosarcoma' },
];
// a ternary is not a property, and neither is a parameter list
const x = { a: cond ? id : 'NCIT:C51899', b: cond ? label : 'Breast Extraskeletal Osteosarcoma' };
function f(id: string, label = 'Breast Extraskeletal Osteosarcoma') { return { id: 'HP:0001250', 'label': 'Seizure' }; }
const c = ontologyClass('NCIT:C51899', 'Radical Cystoprostatectomy');
const d = new OntologyClass().setId('HP:0001250').setLabel('Seizure');
// a call with a third argument is not the (id, name) shape; its second string may be anything
const k = ontologyTerm('NCIT:C51899', 'Breast Extraskeletal Osteosarcoma', 3);
// a label built by joining strings is not a literal and is not judged
const e = { id: 'NCIT:C51899', label: 'Breast ' + rest };
// text that only LOOKS like the shape, inside a string, a regular expression and a template
const s = "{ id: 'NCIT:C5189', label: 'Radical Cystoprostatectomy' }";
const r = /{ id: 'NCIT:C5189', label: 'Seizure' }/;
const t = `{ id: 'NCIT:C5189', label: '${s}' }`;
// the label of one object is not lent to its neighbour
const g = [{ id: 'NCIT:C51899' }, { label: 'Breast Extraskeletal Osteosarcoma' }];
// nor to an object nested inside it
const h = { label: 'Breast Extraskeletal Osteosarcoma', inner: { id: 'NCIT:C51899' } };
// found in review, each made a false pair: someone else's label, a call that makes no term,
// a comment standing alone, a template with a substitution in it
const i1 = { id: 'NCIT:C51899', parentLabel: 'Breast Extraskeletal Osteosarcoma' };
const i2 = { hpoId: 'NCIT:C51899', groupLabel: 'Breast Extraskeletal Osteosarcoma' };
track('NCIT:C51899', 'Breast Extraskeletal Osteosarcoma');
// See the term Breast Extraskeletal Osteosarcoma (NCIT:C51899)
const i3 = { id: 'NCIT:C51899', label: `${name}` };
// escapes inside a string are resolved before it is judged
const j1 = { id: 'HP:0001250', label: 'S\x65izure' };
const j2 = { curie: 'MONDO:0007947', label: 'Marfan\u0020syndrome' };
// a template may hold an escaped backtick, and a slash after return starts a regular expression
const j3 = `a \` b`;
function q(x) { return /it's/.test(x); }
T
cat > "${WORK}/sc_bad_obj/a.js" <<'T'
module.exports = [{
  id: "NCIT:C5189",
  selected: false,
  label: "Radical Cystoprostatectomy"
}];
T
cat > "${WORK}/sc_bad_stem/a.ts" <<'T'
const m = { diseaseId: 'MONDO:0007947', hpoLabel: 'Seizure', hpoId: 'HP:0001250', diseaseLabel: 'Seizure' };
T
cat > "${WORK}/sc_bad_call/a.mjs" <<'T'
const c = ontologyClass( 'NCIT:C5189' , "Radical Cystoprostatectomy" );
T
cat > "${WORK}/sc_bad_chain/a.jsx" <<'T'
const d = new OntologyClass().setId('NCIT:C5189').setLabel('Radical Cystoprostatectomy');
T
cat > "${WORK}/sc_table/a.ts" <<'T'
export const ABBR: Record<string, string> = {
  'HP:0001250': 'SZ',   // Seizure
  'MONDO:0007947': 'Marfan syndrome',   // the value is the name here, the comment is not
  // a comment on the NEXT line belongs to nothing
  'NCIT:C51899': 'RC',
  // Breast Extraskeletal Osteosarcoma
  'NCIT:C51899': 'RC', other: 1,  // Breast Extraskeletal Osteosarcoma
  Mild: 'observed;HP:0001250', // Seizure (HP:0001250)
  'HP:0001250': 'SZ', // Seizure (HP:0001250)
  Sev: 'observed;HP:0001250', /// Seizure (HP:0001250)
};
T
cat > "${WORK}/sc_bad_table/a.ts" <<'T'
export const ABBR = {
  'NCIT:C5189': 'RC',   // Radical Cystoprostatectomy
};
T
cat > "${WORK}/sc_bad_comment/a.ts" <<'T'
const M = {
  Mild: 'observed;NCIT:C5189', // Radical Cystoprostatectomy (NCIT:C5189)
};
T
cat > "${WORK}/sc_under/a.ts" <<'T'
const u = {
  id: 'user_1',
  label: 'Someone'
};
T
cat > "${WORK}/sc_unknown/a.ts" <<'T'
const u = { id: 'Zzz:12', label: 'something' };
T
cat > "${WORK}/sc_lost/a.ts" <<'T'
const a = { id: 'HP:0001250', label: 'Seizure' };
const broken = 'this string never closes;
const b = { id: 'NCIT:C5189', label: 'Radical Cystoprostatectomy' };
T
cat > "${WORK}/sc_pos/a.ts" <<'T'
const a = { id: 'HP:0001250', label: 'Seizure', note: 'HP:0001250' };
T
cat > "${WORK}/sc_tsx/a.tsx" <<'T'
export const Row = () => (
  <tr data-term={{ id: 'NCIT:C5189', label: 'Radical Cystoprostatectomy' }}>
    <td>HP:0001250</td>
  </tr>
);
T
cat > "${WORK}/sc_ambig/a.ts" <<'T'
const a = { id: 'HP:0001250', name: 'sz-short', label: 'Seizure' };
T
cat > "${WORK}/sc_ambig_bad/a.ts" <<'T'
const a = { id: 'NCIT:C5189', name: 'Seizure', label: 'Radical Cystoprostatectomy' };
T
cat > "${WORK}/sc_name/a.ts" <<'T'
const a = { termId: 'NCIT:C5189', displayName: 'Radical Cystoprostatectomy' };
T
cat > "${WORK}/md_good/a.md" <<'T'
An individual with [Seizure HP:0001250](https://example.org/term/HP:0001250), or with [Marfan syndrome 
MONDO:0007947](https://example.org/term/MONDO:0007947), or [Seizure (HP:0001250)](https://example.org/x).

```typescript
export const SHELF = [
  { id: 'NCIT:C51899', label: 'Radical Cystoprostatectomy' },
];
const s = 'a string that never closes
```
T
cat > "${WORK}/md_bad_link/a.md" <<'T'
See [Radical Cystoprostatectomy
NCIT:C5189](https://example.org/term/NCIT:C5189).
T
cat > "${WORK}/md_bad_fence/a.md" <<'T'
~~~js
const SHELF = [{ id: 'NCIT:C5189', label: 'Radical Cystoprostatectomy' }];
~~~
T
cat > "${WORK}/md_notscript/a.md" <<'T'
Write { id: 'NCIT:C5189', label: 'Radical Cystoprostatectomy' } in the config, don't forget.

```text
{ id: 'NCIT:C5189', label: 'Radical Cystoprostatectomy' }
```
T
# Identifiers in places no reader pairs: all must still be COUNTED.
cat > "${WORK}/sc_acc/a.tsx" <<'T'
const a = { id: 'HP:0001250', label: 'Seizure' };
const b = `text ${f({ k: 'HP:0000002' })} and HP:0000003`;
const c = /HP:0000004/.test(x) ? 1 : 2;
/* HP:0000005 in a block comment */
const d = <td>HP:0000006</td>;
const e = 'broken HP:0000007
const f = "https://example.org/obo/HP_0000008 and MONDO:0000009";
const g = 'HP:0000010-HP:0000011';
const h = 'hp:0000012 in a string is counted in any spelling';
function z(so:string, hp:number, go:boolean) { return GO; }
const i = <td>hp:0000013 and NCBITaxon:9606 and obo/NCBITaxon_9606</td>;
T
cat > "${WORK}/sc_lostbc/a.mts" <<'T'
const a = { id: 'HP:0001250', label: 'Seizure' };
/* this comment never closes
const b = { id: 'NCIT:C5189', label: 'Radical Cystoprostatectomy' };
T
cat > "${WORK}/md_fence_char/a.markdown" <<'T'
```ts
const a = { id: 'HP:0001250', label: 'Seizure' };
~~~
const b = { id: 'NCIT:C5189', label: 'Radical Cystoprostatectomy' };
```
T
cat > "${WORK}/sc_unclosed/a.ts" <<'T'
const a = [{ id: 'NCIT:C5189', label: 'Radical Cystoprostatectomy'
T
cat > "${WORK}/md_acc/a.md" <<'T'
[Seizure HP:0001250](https://example.org/term/HP:0001250) and HP:0000002 in prose,
`HP:0000003` in code, obo/HP_0000004 in a path, hp:0000006 and Mondo:0000007 written small.

    id: HP:0001250
    label: Seizure

```json
{ "id": "HP:0001250", "label": "Seizure", "see": "MONDO:0000005" }
```
T

expect 0 sc_good "script: objects on one line and many, quoted keys, casts, call, chain -> 3 pairs, all right" \
  "pairs found    : 3" "ok=3" '!lexer warnings'
expect 1 sc_bad_obj   "script: wrong label in an object, another property between the two -> MISMATCH" "mismatch=1" "a.js:2"
expect 1 sc_bad_stem  "script: two ids in one object are paired by their key stems, not by order" "mismatch=1" "ok=1" "MONDO:0007947"
expect 1 sc_bad_call  "script: wrong label in call arguments, single and double quotes -> MISMATCH" "mismatch=1"
expect 1 sc_bad_chain "script: wrong label in setId().setLabel() -> MISMATCH" "mismatch=1"
# three pairs: the two table rows, and the "// Seizure (HP:0001250)" comment
expect 0 sc_table     "script: id-keyed table reads the comment that ends the line, or the value; not a comment on the next line" \
  "pairs found    : 3" "ok=3"
expect 1 sc_bad_table   "script: id-keyed table with the wrong name in its comment -> MISMATCH" "mismatch=1" "written='Radical Cystoprostatectomy'"
expect 1 sc_bad_comment "script: // Name (ID) with the wrong name -> MISMATCH" "mismatch=1"
expect 3 sc_under     "script: id: 'user_1' is not an identifier in script -> EMPTY SCAN, not a pair" "EMPTY SCAN"
expect 4 sc_unknown   "script: an unknown prefix beside a label is UNRESOLVED, never dropped" "unknown-prefix:Zzz"
expect 1 sc_lost      "script: a string that never closes costs its own line only, and is said out loud" \
  "lexer warnings : 1 place" "a.ts:2" "mismatch=1" "ok=1" "a.ts:3"
expect 1 sc_tsx       "script: an object inside JSX braces is read" "mismatch=1"
expect 0 sc_ambig     "script: label and name both present -> passes when either is the term's name" "ok=1"
expect 1 sc_ambig_bad "script: label and name both present, the label wrong, the name another term's -> MISMATCH" "mismatch=1"
expect 1 sc_unclosed  "script: an object the file never closes is still read" "mismatch=1"
expect 0 sc_lostbc     "script: after a block comment that never closes nothing is read as code, and it is said" \
  "lexer warnings : 1 place" "a.mts:2" "ok=1" "unlabelled ids : 1 distinct"
expect 1 md_fence_char "markdown: a fence opened with backticks is not closed by tildes" "mismatch=1" "ok=1"
expect 3 sc_name      "script: displayName beside termId is not taken for a label" "EMPTY SCAN" "unlabelled ids : 1 distinct"
expect 0 md_good      "markdown: link text ending in an id, split across a line, in parentheses; a ts fence" \
  "pairs found    : 3" "ok=3" '!lexer warnings'
expect 1 md_bad_link  "markdown: wrong name in link text split across two lines -> MISMATCH" "mismatch=1"
expect 1 md_bad_fence "markdown: wrong pair inside a ~~~js fence -> MISMATCH" "mismatch=1"
expect 3 md_notscript "markdown: the object shape in prose and in a text fence is not read, and is counted" \
  "EMPTY SCAN" "unlabelled ids : 1 distinct" '!lexer warnings'

# Accounting: the number of occurrences is a plain grep, not the tool's own count.
# sc_good has 7 paired OCCURRENCES behind its 3 distinct pairs
for spec in "sc_good:9" "sc_table:5" "sc_pos:1" "sc_acc:1" "md_good:4" "md_acc:3" "sc_lost:2" "md_notscript:0"; do
  d="${spec%%:*}"; want_paired="${spec##*:}"
  "${TOOL}" --offline-map "${MAP}" --json "${WORK}/acc.json" "${WORK}/${d}" > "${WORK}/out" 2>&1
  truth=$(cat "${WORK}/${d}"/* | grep -o -i -E '(HP|MONDO)[:_][0-9]{7}|NCIT:C[0-9]+|NCBITaxon[:_]9606' | wc -l | tr -d ' ')
  verdict=$(python3 - "${WORK}/acc.json" "${WORK}/out" "${truth}" "${want_paired}" <<'PYE'
import json, re, sys
j = json.load(open(sys.argv[1]))["script_ids"]
out = open(sys.argv[2]).read()
truth, want = int(sys.argv[3]), int(sys.argv[4])
m = re.search(r"unlabelled ids : (\d+) distinct identifiers? in script.*?(?:\[(\d+) occurrences\])?\n", out)
hdr = (int(m.group(2)) if m and m.group(2) else int(m.group(1))) if m else 0
ok = (j["occurrences"] == truth and j["paired"] == want
      and j["paired"] + j["unchecked"] == truth and j["unchecked"] == hdr)
print("OK" if ok else "BAD occ=%s paired=%s unchecked=%s truth=%s want_paired=%s header=%s"
      % (j["occurrences"], j["paired"], j["unchecked"], truth, want, hdr))
PYE
)
  if [ "${verdict}" = "OK" ]; then ok "account: ${d} -> every identifier a grep finds is counted, ${want_paired} paired, the rest printed"
  else bad "account: ${d} ${verdict}" "${WORK}/out"; fi
done

# ── network cases ────────────────────────────────────────────────────────────
echo ""
echo "── NETWORK CASES (live EBI OLS4) ────────────────────────────────────────"

net_up=0
if [ "${OFFLINE_ONLY}" -eq 1 ]; then
  echo "  SKIPPED BY REQUEST (--offline-only). The live-OLS4 cases below did NOT run;"
  echo "  the hermetic cases above do NOT prove the real resolver works."
  SKIP=3
else
  curl -sSf --max-time 20 \
    "https://www.ebi.ac.uk/ols4/api/ontologies/ncit/terms?obo_id=NCIT%3AC51899" \
    -o "${WORK}/probe.json" 2>"${WORK}/probe.err"
  probe_rc=$?
  if [ ${probe_rc} -eq 0 ] && has "${WORK}/probe.json" "Radical Cystoprostatectomy"; then
    net_up=1
  fi
fi

if [ ${net_up} -eq 1 ]; then
  # N1 — the REAL #451 defect, resolved live
  run_tool "${WORK}/451"; rc=$?
  if [ $rc -eq 1 ] && has "${WORK}/out" "ontology='Breast Extraskeletal Osteosarcoma'"; then
    ok "live: NCIT:C5189 + 'Radical Cystoprostatectomy' -> MISMATCH (exit 1)"
  else bad "live #451 case failed (got exit ${rc})" "${WORK}/out"; fi

  # N2 — the corrected identifier passes live
  run_tool "${WORK}/good"; rc=$?
  if [ $rc -eq 0 ] && has "${WORK}/out" "VERDICT OK"; then
    ok "live: NCIT:C51899 + 'Radical Cystoprostatectomy' -> OK (exit 0)"
  else bad "live good fixture failed (got exit ${rc})" "${WORK}/out"; fi

  # N3 — live nonexistent CURIE is UNRESOLVED, not OK
  run_tool "${WORK}/unresolved"; rc=$?
  if [ $rc -eq 4 ] && has "${WORK}/out" "unresolved=1" && has "${WORK}/out" "term-not-found-in-ols4"; then
    ok "live: NCIT:C99999999 -> UNRESOLVED (exit 4), not OK"
  else bad "live unresolved case failed (got exit ${rc})" "${WORK}/out"; fi
elif [ "${OFFLINE_ONLY}" -eq 0 ]; then
  echo "  !! SKIPPED — EBI OLS4 is UNREACHABLE from this host."
  echo "  !! The three live cases did NOT run. This is not a pass."
  [ -s "${WORK}/probe.err" ] && sed 's/^/  !! /' "${WORK}/probe.err"
  SKIP=3
fi

echo ""
echo "SELFTEST SUMMARY pass=${PASS} fail=${FAIL} network-skipped=${SKIP}"
if [ ${FAIL} -gt 0 ]; then
  echo "SELFTEST RED — ${FAIL} case(s) failed"
  exit 1
fi
if [ ${SKIP} -gt 0 ] && [ "${OFFLINE_ONLY}" -eq 0 ]; then
  echo "SELFTEST INCOMPLETE — network cases skipped (OLS4 unreachable). Exit 3."
  exit 3
fi
if [ ${SKIP} -gt 0 ]; then
  echo "SELFTEST GREEN (HERMETIC ONLY) — live-OLS4 cases deliberately not run."
  exit 0
fi
echo "SELFTEST GREEN — all cases passed, including live OLS4"
exit 0
