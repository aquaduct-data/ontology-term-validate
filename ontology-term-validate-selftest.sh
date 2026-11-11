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
