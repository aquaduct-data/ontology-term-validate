# ontology-term-validate

Catch ontology identifiers that are **correctly formed and mean the wrong thing**.

`NCIT:C5189` and `NCIT:C51899` differ by one character. The first is
*Breast Extraskeletal Osteosarcoma*. The second is *Radical Cystoprostatectomy*.
Both are real, both parse, and a schema validator accepts either. If your code
writes the first while its label says the second, nothing fails — the identifier
is valid and the label is just a string.

That exact defect sat in a published GA4GH Phenopacket example until it was
corrected in November 2026
([ga4gh/phenopacket-schema#451](https://github.com/ga4gh/phenopacket-schema/issues/451)).
The issue that reported it suggests adding identifier/label validation so that
unrelated but syntactically valid identifiers are caught automatically. This is
that check.

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

`.java .rst .yaml .yml .json .md .mdx .markdown .txt .py .proto .kt .rs`
`.ts .tsx .js .jsx .mjs .cjs .mts .cts`

`ontologyClass("ID", "label")` calls, Java builder chains
(`.setId(...).setLabel(...)`), `id:` / `label:` pairs in YAML and reStructuredText
literal blocks, and JSON — which is parsed **structurally**, never by regex,
because a Java-shaped pattern applied to JSON matches the wrong neighbouring
string. Rust, and JavaScript/TypeScript with Markdown, each have their own
reader, described below.

Not opened at all: `.html`, `.vue`, `.svelte`. Terms kept only there give a
clean-looking exit 3.

### Rust

Rust source writes terms in shapes the others cannot see, so `.rs` files get
their own reader and nothing else. It finds string literals with a lexer, the
way the compiler does: plain, multi-line and `\`-continued strings, raw strings
(`r"..."`, `r#"..."#`), char literals and nested block comments.

```rust
HpoTermData::from_str("HP:0000574", "Thick eyebrow", "excluded")  // identifier, then label
HpoTermDuplet::new("Delayed ability to sit", "HP:0025336")        // label, then identifier
#[case("Y-linked inheritance", "HP:0001450")]                      // test-case attributes too
OntologyClass { id: "SO:1000183".to_string(), label: "...".to_string() }
ModeOfInheritance {
    hpo_id: "HP:0000006".to_string(),        // fields sharing a stem: hpo_id / hpo_label,
    hpo_label: "Autosomal dominant inheritance".to_string(),  // disease_id / disease_label
}
```

Two literals count as a pair only when they are **adjacent arguments**. Text in
a following `.expect("...")`, or in the next tuple of a list, is never borrowed.

Order is decided per argument list. A flat table that alternates —
`["HP:..", "label", "HP:..", "label"]`, or the same thing label-first — is read
in the order its first entry sets, all the way along. Otherwise an identifier
takes the literal after it; and if that one call has a plausible label on *both*
sides, that occurrence passes when either is the term's label. The allowance
belongs to that one occurrence and never excuses the same pair elsewhere.

An inline struct — `Ref { id: "..", label: ".." }`, opened and closed on one
line — keeps its fields to that line. It never takes a label from the struct
around it, and it does not stop the outer struct finding its own.

A JSON object written inside a string literal (`r#"{"id": "..", "label": ".."}"#`)
is read as JSON.

**Every identifier is accounted for.** Each identifier with a known prefix
inside any string literal or comment is found by a plain search of the text,
independent of the reader, and ends in exactly one place: paired with a label
at that exact position, or counted in the header
(`unlabelled ids : N … NOT checked`). A clean verdict is never mistaken for
every identifier having been looked at. The count is by occurrence: an
identifier paired in one place and bare in another is counted for the bare one.

**Limits.** Read a Rust `MISMATCH` before acting on it, and do not read a clean
result as proof.

- Identifiers must be colon form. An underscore form would turn every
  `NM_000138.5` into a pair. `HP_0001250` is counted as unlabelled, never paired.
- A positional argument beside an identifier is *assumed* to be its label, so
  a call that passes a gene identifier and then a transcript accession yields a
  pair that is not one, and
  `assert_eq!(t.id, "HP:0001250", "id must round trip")` reports the assert
  message as a mismatched label.
- Code inside comments is read, as it is by the other extractors. A wrong pair
  in a commented-out line is still reported.
- Byte and C strings (`b".."`, `br".."`, `c".."`) are bytes, not text. They are
  never paired; an identifier inside one is counted as unlabelled.
- A string or block comment that never closes is reported in the header
  (`lexer warnings`), and everything after it is searched for identifiers but
  not paired.
- An identifier at the end of `f("HP:..", "label", "MONDO:..")` has no label
  after it and is left unpaired — counted as unlabelled, not checked.
- Not paired, and counted as unlabelled: `"HP:.." => "label"` map entries, an
  identifier followed by a method call (`"HP:..".parse().unwrap(), "label"`),
  and a `label:` field more than three lines from its `id:`.
- A pair whose "identifier" has a lower-case unknown prefix and no digit
  (`"enable:sort"`) is set aside as not identifier-shaped, printed in the
  header and listed in the JSON report. It is not judged.

### JavaScript, TypeScript and Markdown

Script files get their own reader too, and nothing else. It reads:

```ts
const shelf = [{ id: 'HP:0001250', label: 'Seizure', selected: false }];
const term = { hpoId: 'HP:0001250', status: 'observed', hpoLabel: 'Seizure' };
const c = ontologyClass('HP:0001250', 'Seizure');
const d = new OntologyClass().setId('HP:0001250').setLabel('Seizure');
const ABBREVIATIONS = {
  'HP:0000006': 'AD',   // Autosomal dominant inheritance
};
const STATES = {
  Mild: 'observed;HP:0012825', // Mild (HP:0012825)
};
```

and in Markdown, link text that ends in an identifier —
`[Ventricular septal defect HP:0001629](https://...)`, also when the line breaks
before the identifier — and the script shapes above inside fences tagged
`js`, `ts`, `json` or untagged.

Each shape is narrowed until what sits beside the identifier is a name and not
just some text:

- A pair is made **within one object**. A label key is `label` or `name`; a
  longer key (`hpoLabel`, `diseaseName`) counts only when what comes before it
  matches what comes before `id` (`hpoId`, `diseaseId`). `parentLabel` beside
  `id` is someone else's label.
- A call is read only when the function's name says it makes a term
  (it contains `ontology`, `term`, `curie`, `concept`, `phenotyp`, `disease` or
  `hpo`), and only with exactly two string arguments. `track('HP:..', 'click')`
  is not a pair.
- A `// Name (ID)` comment is read only at the end of a line of code that
  itself contains that ID.
- A template string with `${...}` in it is never a label.

The same accounting applies: every identifier with a known prefix in these
files is counted, and is either paired at that exact position or printed as
unlabelled. The prefix must be spelled as the ontology spells it (`HP:`), or in
any case when a digit follows (`hp:0001250`).

**Limits.** Read a `MISMATCH` from these files before acting on it.

- `name` beside an identifier is taken for the term's name, so
  `{ id: 'HP:..', name: 'btn-x' }` is reported as a mismatch.
- The comment that ends an identifier-keyed entry is taken for the name
  whatever it says (`// legacy`, `// TODO`).
- Markdown link text before an identifier is taken for the name
  (`[see HP:..](...)` reads as "see").
- Not read: a pair split between two statements, `id = '...'` assignments, and
  a table from an identifier straight to its name with no comment.
- JSX text with an apostrophe in it makes the reader lose that line, and it
  says so in the header.
- In UI code the unlabelled count can include things that are not identifiers
  (`{ go: 1 }` written as `go:1`). It over-counts; it does not drop.
- An identifier with an escape in its first characters (`'HP\x3a0001250'`) is
  not counted, and one with an escape later is counted only up to the escape.
  Neither gives a pair.

## Options

```
--json <file>            also write a machine-readable report (includes the unlabelled counts)
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

114 cases, hermetic by default via `--offline-map`, plus live lookups when the
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
