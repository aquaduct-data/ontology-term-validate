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
