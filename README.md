# ontology-term-validate

Catch ontology identifiers that are **correctly formed and mean the wrong thing**.

`NCIT:C5189` and `NCIT:C51899` differ by one character. The first is
*Breast Extraskeletal Osteosarcoma*. The second is *Radical Cystoprostatectomy*.
Both are real, both parse, and a schema validator accepts either. If your code
writes the first while its label says the second, nothing fails — the identifier
is valid and the label is just a string.

That exact defect sits in a published GA4GH Phenopacket example
([ga4gh/phenopacket-schema#451](https://github.com/ga4gh/phenopacket-schema/issues/451)),
where a maintainer asked for automated identifier/label validation so that
unrelated but syntactically valid identifiers get caught. This is that check.

## What it does

Finds `(identifier, label)` pairs in a source tree, resolves each identifier
against [EBI OLS4](https://www.ebi.ac.uk/ols4), and classifies every pair:

| Result | Meaning |
|---|---|
| `OK` | the written label matches the ontology's current label |
| `SYNONYM` | matches an exact synonym rather than the primary label — reported distinctly, never folded into `OK` |
| `MISMATCH` | the identifier resolves to a **different** term than the label claims |
| `OBSOLETE` | resolves and matches, but the term is deprecated |
| `UNRESOLVED` | the lookup did not answer — **cannot determine**, not "clean" |

```console
$ ontology-term-validate.sh src/
MISMATCH  src/.../UrothelialCarcinoma.java:118
          NCIT:C5189
          written  'Radical Cystoprostatectomy'
          ontology 'Breast Extraskeletal Osteosarcoma'

SUMMARY ok=48 synonym=3 mismatch=1 unresolved=0 obsolete=2 pairs=54
VERDICT MISMATCH — exit 1
```

## Install

One shell script and `python3`. No packages, no services, nothing to build.

```bash
curl -fsSLO https://raw.githubusercontent.com/aquaduct-data/ontology-term-validate/main/ontology-term-validate.sh
chmod +x ontology-term-validate.sh
```

## Exit codes

Designed so that **"I could not check" can never be mistaken for "I checked and
it is fine."**

| Code | Meaning |
|---|---|
| `0` | every pair checked and clean |
| `1` | at least one `MISMATCH` — the defect class above |
| `2` | usage or environment error |
| `3` | **empty scan** — zero pairs found. Unknowable, not clean. |
| `4` | no mismatch, but something was `UNRESOLVED` — cannot determine |

Exit 3 matters more than it looks. A scan that finds nothing looks identical to
a scan that finds nothing wrong, so it gets its own code and its own words.

## What it reads

`.java .rst .yaml .yml .json .md .txt .py .proto .kt .ts .js`

Four extractors: `ontologyClass("ID", "label")` calls, Java builder chains
(`.setId(...).setLabel(...)`), `id:` / `label:` pairs in YAML and reStructuredText
literal blocks, and JSON — which is parsed **structurally**, never by regex,
because a Java-shaped pattern applied to JSON matches the wrong neighbouring
string.

`.mjs` is deliberately **not** on that list. If you keep terms in an `.mjs` file
they will not be scanned, and you will get a clean-looking exit 3.

## Options

```
--json <file>            also write a machine-readable report
--offline-map <file>     resolve from a local TSV instead of the network
--no-network             make every lookup fail, to prove fail-closed behaviour
--tolerate-unresolved    downgrade exit 4 to 0; pairs are still printed as UNRESOLVED
--timeout <seconds>      per-request timeout (default 25)
```

`--no-network` exists so you can watch the tool refuse rather than trusting that
it would. A check you have never seen fail is indistinguishable from `exit 0`.

## In CI

```yaml
- name: Ontology identifiers resolve to the labels we wrote
  run: ./ontology-term-validate.sh src/ docs/
```

Treat exit 3 and 4 as failures too. If the scan found nothing, the check did not
run; if a lookup did not answer, you do not know.

## What it does not do

- **It does not validate schemas.** Use your schema validator for that; this
  only answers whether an identifier means what the surrounding label says.
- **It does not check that the term is the *right* term clinically.** It checks
  agreement between an identifier and its label. A pair can agree perfectly and
  still be the wrong concept for the sentence it sits in. That judgement is
  yours.
- **It does not cover every ontology.** It resolves what OLS4 serves. OMIM, for
  instance, is not served there and comes back `UNRESOLVED` — reported as
  cannot-determine, not as a pass.
- **It needs the network**, unless you give it `--offline-map`.

## Testing

```bash
./ontology-term-validate-selftest.sh
```

21 cases, hermetic by default via `--offline-map`, plus live lookups when the
network is available. Every classification has a case that **plants the defect
and requires the tool to report it**, so a passing suite means the detector
still bites.

## Try it

Two tiny synthetic trees ship with the tool, so you can watch both outcomes
before pointing it at your own code:

```console
$ ./ontology-term-validate.sh examples/clean      # every pair agrees -> exit 0
$ ./ontology-term-validate.sh examples/mismatch   # the defect above  -> exit 1
```

CI runs both on every push, and requires the second one to fail.

## Data

Reads source trees. Never writes into the tree it scans. No patient-derived data
of any kind, and none is accepted: this tool looks at identifiers and labels in
code and documentation, not at records about people.

Network traffic is to EBI OLS4, a free public read-only API. No credentials, no
cost, no telemetry.

## Provenance

Built while contributing corrections to the GA4GH Phenopacket Schema. It was
written because a wrong identifier in a published example could not be caught by
any existing check, and it has since found two further terms in published
examples that the ontology had retired (`EFO:0000221`, `EFO:0000222`).

Prepared with AI assistance, disclosed in the commit history.

## Licence

BSD-3-Clause, the same licence as the GA4GH Phenopacket Schema. See
[LICENSE](LICENSE). Copyright (c) 2026, Aquaduct Data Strategies LLC.
