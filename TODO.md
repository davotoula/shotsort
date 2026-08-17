# shotsort — TODO

Things found by *using* the tool, not by reviewing it.

---

## 1. `extract` segfaults inside Apple's Vision framework — MITIGATED (`4e7d4a0`)

**Resolution.** Concurrency was the cause, and the mechanism is known: the
**Apple Neural Engine session limit of 2**, which Apple DTS has named and which
the community has validated as the safe width for accurate OCR. Two is a
documented boundary, not a lucky value.

Measured over the full 1,494-image collection:

| width | result |
|---|---|
| 1 | survived |
| **2** | **survived (5m05s)** |
| 4 | crashed |
| 8 | crashed |

The `extract` default is now `2`, with `--concurrency N` to override. An
earlier default of 1 was chosen before the mechanism was known — it was simply
the only width then tested, and it costs roughly 2x the runtime for no
additional safety. `--supervise` re-invokes the binary as a child until
progress stops, which works regardless of root cause — and distinguishes
"crashed but progressed" (retry) from "crashed with no progress" (stuck on one
file: report and stop), so a poisoned image can never masquerade as the flaky
framework bug. A cap makes the crash unlikely, not impossible — the race is
inside Apple's code — so the supervisor is worth keeping regardless.

Verified end to end: **1,494 / 1,494 records indexed, 0 restarts, exit 0.**

**Possible further throughput (not done):** gate only `RecognizeTextRequest`
through a width-2 limiter and let `ClassifyImageRequest` /
`DetectFaceRectanglesRequest` run wider — every captured stack implicates only
`TextRecognition`. More moving parts, and only worth it if width-2 extraction
feels slow, which at ~5 minutes for the full collection it does not.

The underlying Vision bug is still there and is still Apple's. The reproducer
below remains valid and is worth filing. What follows is the original
investigation, kept because it is the evidence for the chosen default.

---

### Original investigation

**Symptom**

```
$ ./shotsort extract
zsh: segmentation fault  ./shotsort extract
```

**What is established**

- Two crash reports, identical signature: `SIGSEGV` / `EXC_BAD_ACCESS`, faulting
  frame `libobjc.A.dylib objc_retain` called from `TextRecognition` inside
  `Vision`. A bad retain means an over-release or a race on an object Vision
  owns.
- **Not our code.** Reproduced in a standalone probe importing only `Vision`,
  calling `RecognizeTextRequest` / `ClassifyImageRequest` /
  `DetectFaceRectanglesRequest` with no `ShotsortCore` involved. Exit 139.
- **Not a specific bad image.** Run 1 died after 688 records; run 2 resumed and
  died after 80 more (768). A poisoned file would fail at the same file every
  time. It does not.
- **Not simply the request multiplier.** The extractor issues 3 requests per
  image × 8 images = 24 concurrent Vision requests. Serialising the three per
  image (24 → 8) still crashes, at width 8 *and* width 4.
- **No data was lost.** The append-only JSONL design held: 688 records survived
  the first crash, the resume key skipped them, and the second run continued
  from there. `~/Downloads/ss` was never modified — `extract` only reads.

**Still open:** whether fully serial (`width=1`) survives. If it does, the fix
is a concurrency cap. If it does not, the fault is cumulative state inside
Vision and a cap will not help.

**Fix options, in preference order**

1. **If serial is stable** — add `--concurrency N`, default it to whatever
   survives, and document the cost. Extraction is currently 1–4 minutes;
   serial would be slower but correct.
2. **Auto-resume around the crash.** Worth doing *regardless* of root cause,
   because we cannot fix a framework bug. `extract` is already resumable and
   append-only, so a supervisor loop that re-invokes it until the processed
   count stops rising turns a hard crash into a slowdown. The design already
   survives being killed; nothing currently takes advantage of that.
3. **Report to Apple.** The probe is a minimal reproducer independent of this
   project.

**Do not** work around this by trapping the signal — `SIGSEGV` from a corrupted
heap is not safely recoverable in-process. Restarting is the honest remedy.

---

## 2. Show progress during `extract` and `classify` — DONE

Both stages render a bar to stderr: `extracting  [████░░░░]  712/1494   47%
eta 2m41s`. The runners themselves emit only a `ProgressUpdate` through
`onProgress` — they neither format nor write. `ShotsortCore` does supply the
rendering machinery (`ProgressLine`, `ProgressReporter`, whose default sink
writes to stderr), but it is opt-in and fully injectable: `main.swift` decides
to construct a reporter at all, and a caller wanting JSON or silence either
skips it or passes its own sink.

Rendering lives in `ProgressLine` (pure) and `ProgressReporter` (cursor
control); the resize recovery computes its row count from the painted length,
and `ProgressReporter.walkPrefix` documents why that is exact.

DONE for the display, not for the perception: item 12 measures a resumed
`classify` holding a painted-but-motionless bar for 34-76s, because progress
is reported per completed unit and the first unit can take ten model calls.

Three properties worth not regressing, each covered by a test:

- **Counts are collection-relative.** `done` includes work recorded before
  this process started, so a `--supervise` restart resumes the bar instead of
  reopening it at zero.
- **`ProgressUpdate` carries a `ceiling` as well as a `total`.** The bar
  tracks the collection; the ETA tracks what this invocation will actually
  reach, or a `classify --limit 50` run quotes the time to finish 1,444
  records.
- **Rate comes from a trailing 30s window, not a run average.** `classify`
  drains every group before any single, so it has two throughput phases and a
  run-long average gets worse as the run proceeds.

---

## 3. Configurable inbox and output folders

**CLOSED 2026-08-14** by `Paths.resolve` plus `--inbox`/`--output`:
`--inbox`/`--output` on every command. One deliberate deviation from the
item as written: the default is the current directory (not the old
Downloads behaviour — accepted as a breaking change for the single user).
No explicit `~` expansion was added — `resolve` takes what it is given —
but this turned out not to be a gap: `URL(fileURLWithPath:)` expands a
leading `~` itself (verified), so both a shell-expanded and a quoted
`--inbox "~/x"` resolve correctly with no extra code.

**What happens now:** `main.swift` calls `Paths.standard()`, hardcoded to
`~/Downloads/ss` and `~/Downloads/ss-sorted`. The tool cannot be pointed
anywhere else.

**Wanted:** `--inbox PATH` and `--output PATH`, defaulting to current behaviour.

**Where it goes:** `Sources/shotsort/main.swift` only. `Paths` already accepts
explicit URLs — `Paths(inbox:output:)` has existed since the first task — so no
library change is needed. Expand `~` explicitly; a shell does it, another
caller may not.

**Why this is worth more than convenience.** Three things are untestable
*because* the paths are fixed, and all three become testable once they are not:

- **`apply`'s dry-run default has no automated test.** `Applier.plan` and
  `Applier.commit` are both covered, but the CLI branch choosing between them
  is not — and choosing wrong moves 1,494 real files.
- **No end-to-end pipeline test**, for the same reason.
- **Trying the tool on a small folder first** currently means shuffling
  screenshots in and out of `ss/` by hand — the exact chore this tool exists to
  remove.

It also makes item 1 far cheaper to investigate: a 50-image folder reproduces
in seconds instead of minutes.

Add the dry-run-default test as part of this change. It is the reason the gap
matters.

---

## 4. `propose` produces an unusable taxonomy — consolidation is required, not optional — DONE (`a7e707c`)

**Resolution.** Guided one-shot reduction replaced both prior strategies. Verified on the real 1,494-image index: **16 categories**
(Technology, Business, Entertainment, Finance, Lifestyle, Productivity,
Travel, Education, Fashion, Food, Shopping, Stress, Sleep, Personal,
Websites, Unsorted) — one `Finance` bucket where the bad draft had five, no
single-screenshot names, no markdown artifacts, no stderr fallback warning
(the model reduction succeeded). Exit 0, ~2m26s.

**Status (superseded by the above):** `propose` now *completes* (`e9f32da`,
2m25s, exit 0) after deterministic consolidation replaced the model call.
The output is not usable.

**What it produced on the real 1,494-image index:**

```
Account Security, Account Summary, Aurora forecast 2025-06-02 09,
Banking Information, Financial Overview, Flight Information, Google Flights,
Local Events, Motion Alerts, Movie Scene, Outdoor Views, Payments Breakdown,
Radisson Blu, Rhinoplasty, Scottish Twitter, Unsorted
```

Five overlapping finance buckets, two flight buckets, and several
single-screenshot topics — `Aurora forecast 2025-06-02 09` has the description
`24 UTC.`, which is one screenshot's contents.

**Diagnosis.** The list is **exactly alphabetical** — verified, not inferred.
Every candidate has frequency 1, so ranking by count descending is a no-op and
the alphabetical tie-break selects all 15. Each propose call sees 12 *different*
samples and invents names specific to them, so names essentially never recur
across batches. There is no frequency signal for deterministic ranking to use.

**Consequence for the earlier decision.** Deterministic consolidation was chosen
on the understanding that it merely lost near-synonym merging. That understated
it: with no reduction step, nothing turns ~60 one-off names into a coherent set.
Item 5 or 6 below is required for `propose` to be useful, not an optimisation.

**What is still sound:** the propose loop, the `maxProposeCalls` bound, markdown
stripping, the `Unsorted` injection, the `minCategories` floor, and
`TaxonomyStore` validation. Only the reduction step is inadequate.

**Note:** the design intends `taxonomy.json` to be hand-edited before
`classify`, so this is a poor starting draft rather than a blocker — but it is a
poor starting draft.

---

## 5. Consolidation via the model, with a deterministic fallback — SUPERSEDED (`0facdee`)

**Resolution.** Implemented as part of guided reduction, not as the
free-text retry originally described below: the reduction call is now
schema-bounded (8–15 categories), so there is no echo-the-count failure mode
to retry around. Retry-once-then-deterministic-fallback is a policy that
`Proposer.run` applies around the guided `reduce(candidates:)` seam — the
seam itself is policy-free — with its own test for the fallback path. Item
4's acceptance run hit the model path cleanly (no fallback warning), but the
fallback exists and is exercised in tests.

Original plan, kept for context:

Restore a reduction call, but make it honest about what went wrong the first
time: given 6 names the model returned 6 lightly-reworded names, echoing the
count rather than merging.

- State a hard maximum in the instruction ("return AT MOST 12 names"), and give
  it the full candidate list at once rather than in batches of 20 — the echo
  behaviour was observed on a short list, and a longer one may behave
  differently.
- If a round still fails to shrink, fall back to the deterministic reduction
  that exists now instead of aborting the stage.
- The fallback path needs its own test; it is the path that runs when the model
  misbehaves, which is exactly when it is least observed.

## 6. Guided generation for `propose` — DONE (`a7e707c`)

**Resolution.** Done as designed: batch generation
uses `@Generable CategoryDraft`, and reduction uses a `@Generable
TaxonomyDraft` bounded to 8–15 categories via `.count(8...15)`. `parse`,
`cleanName`, and `looksLikeACategoryName` are deleted along with their tests
— confirmed no markdown artifacts in the real acceptance run (item 4).

Original plan, kept for context:

Replace free-text parsing with a `GenerationSchema`, as `classify` already does.
No parsing, and no markdown leakage by construction — the `cleanName` stripping
added in `e9f32da` exists only because the model ignores the requested format.

Larger change than item 5: `classify` constrains to a flat `anyOf` string set,
whereas this needs a list of name/description pairs. Structurally the cleanest
of the three, and it would make item 5's fallback unnecessary.

---

## 7. `classify` verify-agreement is 26% — halted before apply

**Measured** on 50 real records against the guided taxonomy (`8963ebd`):

```
classified:        50
Unsorted share:    2/50  =  4%     (worry line ~40% — fine)
reasons:           model 49, guardrail 1
verify agreement:  13/49 = 26%     (threshold ~70% — FAILS)
```

Task 15's decision rule is "report before any full run", so `apply` was not run.

**Why this matters more than the number.** Every other signal looks healthy: the
category distribution is plausible (Finance 10, Social Media 10, Personal 6,
tapering), `Unsorted` is low, there are no schema misses. Without `--verify`
this would have read as success and sorted 1,494 screenshots on assignments that
are ~74% unstable.

`--verify` re-asks with `PromptVariant.alternate`, deliberately different
phrasing. An earlier draft re-asked with the *identical* prompt, which would have
reported near-100% agreement by construction and detected nothing.

**Leading hypothesis: the taxonomy, not the model.** Disagreements cluster on
`Finance` (5 of 8 sampled), plus `Personal`, `Retail`, `People`. The guided
reduction produced deliberately broad buckets — `Work` / `Productivity` /
`Personal` / `Lifestyle` / `General` are not mutually exclusive, and a banking
screenshot legitimately fits Finance or Personal or Technology. Where categories
genuinely overlap, an unstable answer is the *correct* answer to an ambiguous
question, and no amount of model improvement fixes it.

**Blocked on a data gap:** `LabelRecord.verifyAgreed` is a `Bool`, so the second
answer is discarded. That makes it impossible to distinguish *adjacent*
disagreement (Finance vs Personal — both defensible, taxonomy problem) from
*wild* disagreement (Finance vs Nature — model instability). Store the alternate
category alongside the flag; it costs one field and turns an unactionable
percentage into a diagnosis.

**Next steps, in order:**

1. Store the alternate category (above). Re-run `classify --verify --limit 50`
   and build a confusion pairing. Cheap, and it decides everything below.
2. If disagreement is adjacent: hand-edit `taxonomy.json` into fewer, crisply
   disjoint categories — which is what the design always intended the user to
   do — and re-measure. Merging `Work`/`Productivity`/`General` alone would test
   the hypothesis.
3. If disagreement is wild: the on-device model is not stable enough for
   single-label classification at this taxonomy size, and the honest options are
   a much smaller taxonomy or a different approach entirely.

**Also observed:** `classify --verify` took 5m59s for 50 records, so ~3 min per
50 unverified — roughly **90 minutes** for the full collection, against the
spec's 15-45 minute estimate. The concurrency cap from item 1 contributes.

---

## 8. The on-device model is the limit, not the taxonomy — measured

Follow-up to item 7, using the alternate answers now recorded by `63940be`.

**The disagreement pairs were diagnostic.** `People` was the alternate in 12 of
36 disagreements — `Finance -> People` x3, `Social Media -> People` x3,
`Retail -> People` x2. A systematic pull, not scatter, and traceable to the
`--verify` alternate prompt foregrounding the evidence line (and its `faces:`
field) under a heading the primary prompt does not use.

**So `--verify` conflates three things**, and the shipped design assumed the two
variants were equivalent probes of one question. They are not.

**Three measurements separate them** (29-30 real records, guided taxonomy):

| probe | agreement | isolates |
|---|---|---|
| same prompt, asked twice, 16 categories | **44%** | model instability alone |
| different phrasing (`--verify`), 16 categories | 26% | instability + prompt asymmetry |
| same prompt, asked twice, **7** categories | **51%** | whether taxonomy size is the lever |

**Conclusions:**

1. **The model is unstable at any taxonomy size we would want.** Halving 16
   categories to 7 moved agreement 44% -> 51%, and chance agreement rises 6% ->
   14% as you shrink, so most of that is arithmetic. Shrinking the taxonomy is
   not a fix.
2. **Prompt asymmetry is real but secondary** — roughly 18 points of the gap
   between 26% and 44%. Worth fixing; not the cause.
3. **The model is not random** — 44% against 6% chance is genuine signal. It
   knows roughly what a screenshot is about; it cannot commit to one label.

**This refutes a claim made during spec review.** The argument for the alternate
variant was that an identical re-ask "would report ~100% agreement by
construction" under near-greedy decoding. It reports 44%. Decoding is not
near-greedy, so the cheaper same-prompt probe was valid all along and the
alternate variant traded a clean measurement for a confounded one.

**Options, with honest costs:**

- **Best-of-N voting.** Ask 3x, take the majority. Directly attacks instability,
  but triples a stage already at ~90 minutes for the full collection — call it
  4.5 hours — and a majority over three unstable draws is still not a stable
  answer, merely a less unstable one. Untested.
- **Hybrid: deterministic where the evidence is decisive.** 326 of 1,494 records
  (21.8%) carry a harvested domain, and a domain is an exact signal —
  `news.sky.com` is News with no model and no variance. Rule-sort those, and put
  the model only on what genuinely needs judgement. Smaller model surface, and
  the deterministic fraction becomes reproducible.
- **Abandon single-label.** The instability may be honest: a banking screenshot
  shared on social really is Finance *and* Social Media. Multi-label, or
  ranked-with-confidence, matches the material better than forcing one folder.
  Largest change; contradicts the folder-per-image premise.
- **Ship as a rough first pass.** `apply` is reversible and `undo` is tested.
  A 44%-stable sort still beats 1,494 files in one flat directory, provided the
  instability is stated plainly rather than presented as classification.

**Not recommended:** proceeding to `apply` on the current numbers without a
decision above. It would move 1,494 personal files on assignments that flip more
than half the time.

---

## 9. `Domains.harvest` captures filenames and truncations as domains — DONE (`21ca2f8`)

**Resolution.** The allowlist fix, in two measured passes: a first cut
(`2f7dbe4`) removed 102 junk domains but also dropped real ones — nostr.mom
(8 records, a would-be group), nostr.wine, nostr.band, gov.scot, .co sites —
so the list was widened against the real index (`21ca2f8`). Final state:
79 junk domains gone (book.php, chatfileuploaddialog.kt, alex.mor, m.gox),
282 records keep genuine domains, and the remaining removals are all person
names, file extensions and OCR truncations. Tests pin the offenders and the
novelty TLDs both. The lesson is recorded in the allowlist's own comment:
curate against the data, and extend the list when a real domain is observed
to be dropped.

Related fix, same motivation (`2f7dbe4`): a scene group whose model verdict
is Unsorted now falls back to per-image instead of stamping the group — 19
scene groups had stamped 173 records Unsorted wholesale while per-image had
sorted 164 of them. Re-measured after both fixes: 155/173 rescued into real
categories (18 honestly Unsorted), collection Unsorted 24% → 13%, domain
consistency still perfect at 19/19, reason histogram
{group-model 453, model 984, guardrail 35, no-signal 22}. Domain groups
keep their Unsorted verdicts — a domain is a real source, one rename
repairs it (primal.net 7/7 stands).

The original record follows.

---

The regex is `/\b((?:[a-zA-Z0-9-]+\.)+[a-zA-Z]{2,})\b/` — any dotted token whose
last segment is 2+ letters. That matches far more than hostnames:

- `book.php`, `coptics.html` — file names
- `chatfileuploaddialog.kt` — a source file
- `alex.mor` — a truncated word split across an OCR line break

Harmless while `domains` only feeds the signal line as weak evidence, and the
full-run analysis showed the field is not load-bearing for classification. It
matters if domains are ever used as a **rule input**, which was considered and
rejected (see below) — a rule keyed on `book.php` would be nonsense.

**Fix:** require the last segment to be a plausible TLD rather than any letters.
Either a small allowlist of the TLDs this collection actually contains, or at
minimum a denylist of common file extensions (`php html htm kt swift js json png
jpg md txt xml yml`). An allowlist is the honest version; a denylist will leak.

Add a test using the real offenders above, asserting each is NOT harvested, and
keep the existing `ignoresDecimalNumbersThatLookLikeDomains` test.

**Why rule-based classification on domains was rejected:** measured over the
full run, the 326 domain-bearing records spread across a ~200-domain long tail.
35 of the 55 multi-record domains split across categories, and no single mapping
would cover more than a handful of records. The mechanism cannot pay for itself
at this distribution — a targeted map for a few observed offenders might, but
that is a patch, not an architecture.

---

## 10. Per-image classification is the wrong unit — measured — DONE (`35463c5`)

**Resolution.** Group-level classification landed: a pure
`GroupPlanner` forms groups from shared positive evidence only — domains with
≥2 records, domainless named-scene clusters with ≥3 — one pooled-evidence
model call per group, the answer stamped on every member atomically
(`appendAll`), refused groups falling back to per-image. Full ClusterKey
grouping was measured and rejected first: its domainless side is dominated by
junk-drawer clusters (one 375-record no-scene bucket), so the "~200 groups,
single-digit minutes" arithmetic below did not survive contact with the data —
about 1,000 calls remain and the win is consistency, not speed.

Measured on the full 1,494-record index (14-category taxonomy):

```
domains >=3 records getting ONE category:  20/20  (was 3/38-grade scatter)
reason histogram: group-model 595, model 845, guardrail 32, no-signal 22
largest bucket: Unsorted 24% (honest), largest real bucket 14%
accuweather.com: 6/6 Places & Nature   primal.net: 7/7 (Unsorted, one call)
```

The denominator shifted from 38 to 20 because the earlier count counted every
domain appearing anywhere in a record's `domains` list, while grouping (and
this measurement) key on `domains.first`; on that same `domains.first` basis
the per-image baseline was 3/20, not 3/38.

The apply-halt below is lifted: at 100% same-source consistency for grouped
domains, folders no longer scatter near-identical screenshots. Heterogeneous
domains (gmail.com → one label) are the accepted design trade — one rename
fixes a bad group call.

The original record follows.

---

Full run under the 14-category taxonomy (`c789f22`), 1,494 records, greedy,
52m33s, exit 0. Descriptions now reach the model (`0d209b8`).

**The histogram looked like success:**

| | new | old |
|---|---|---|
| largest bucket | Social & Messaging 33% | Social Media 46% |
| News & Current Affairs | 70 | *did not exist* |
| Reference & Lookups | 35 | *did not exist* |
| Crypto & Markets | 81 | *did not exist* |

**Same-source consistency says otherwise.** For domains with 3+ screenshots —
near-identical sources that must land together:

```
OLD taxonomy:  6/38 = 15% of domains got ONE category
NEW taxonomy:  3/38 =  7%
```

`accuweather.com`: 6 screenshots, **6 different categories**.
`relay.nostr.band`: 5 shots, 5 categories. `primal.net`: 10 shots, 7 categories.

The improvement in the histogram was errors being **spread**, not fixed. A
consistently wrong label is repairable by renaming a folder; a scattered one is
not. By the measure that matters for a tool whose output is folders, this is a
regression.

**Diagnosis.** The model is not classifying by source or topic — it reacts to
whatever text happens to be in each individual screenshot. Six weather
screenshots differ in temperature, time and location, and each triggers a
different association. Category descriptions fixed specific cases (bbc.co.uk ->
News 2/3, agoda -> Travel) without fixing the mechanism.

**What this rules out:** taxonomy tuning. Two taxonomies have now been tried —
16 model-generated categories and 14 hand-written ones with disambiguating
descriptions. Consistency went 15% -> 7%. The unit of classification is wrong,
not the vocabulary.

**Proposed fix: classify the source, not the screenshot.**

Group first, classify second. `ClusterKey` already exists and already groups by
domain, scene, face band and density. Instead of 1,494 model calls each seeing
one noisy screenshot, make one call per group, showing the model several
samples from that group at once, and assign the answer to every member.

- **Consistent by construction** — every screenshot from `accuweather.com` gets
  the same category because it is decided once.
- **Cheaper** — ~200 domain groups against 1,494 images turns a 52-minute stage
  into single-digit minutes.
- **Better evidence** — aggregate text from several screenshots of one source
  describes that source far better than one screenshot's OCR noise.
- **Reuses what is built** — `Sampler` already draws representatives per
  cluster; this is the same machinery pointed at classification.

Ungrouped records (no domain, no distinctive scene) still need per-image
handling, and will still be inconsistent. But they are the minority, and
`Unsorted` is an honest destination for them.

**Do not run `apply` on the current labels.** At 7% same-source consistency the
folders would scatter near-identical screenshots, which is worse than the flat
directory it replaces.

---

## 11. `manifest.jsonl` records absolute paths — breaks under relocation

**What happens now:** `manifest.jsonl` records each move's `to:` path as an
absolute path under the output tree at the time of the move. Now that
collections are relocatable (item 3), that absolute path is not durable —
moving or remounting a sorted collection (a new machine, a renamed parent
folder, a different mount point) leaves every recorded `to:` pointing at a
location that no longer exists. `Applier.undo` looks up each file with
`exists(current)` against that stale path, finds nothing, and — by design,
per the comment on the skip in `undo` — "skip[s] and report[s] rather than
overwrite," but it does not actually report anything: the skip is silent,
and the caller only sees `restored` come back short. `main.swift` prints
"returned 0 files to `<inbox>`" with no indication that anything was
supposed to move but couldn't be found.

**Wanted:**
1. `undo` names the files it skipped because the recorded location is
   missing, so "returned 0 files" is diagnosable instead of a dead end.
2. Larger, state-format change: make manifest paths relative to the output
   tree rather than absolute, so a relocated or remounted collection's
   history stays valid. Needs a migration story for existing
   `manifest.jsonl` files, same as any state-format change (see
   CONTRIBUTING.md).

**Where it goes:** `Sources/ShotsortCore/Apply/Applier.swift` (`undo`) for
part 1; `Applier`, `NetState`, and `ManifestRecord` for part 2, since
`NetState.location(of:)` is what turns a manifest row into a claimed path
today.

---

## 12. `classify` looks hung for 30-75s after the bar appears — measured

**What happens now:** a resumed `classify` paints its bar almost instantly and
then does not move it for 34-76s, which reads as the hang the bar exists to
rule out (item 2). None of that wait is startup work. Measured 2026-08-17 on
the real 1,494-record collection, against a copy of `.shotsort` so the live
tree was untouched:

| | |
|---|---|
| First paint | **0.19s** — `Preflight`, `ModelAvailability`, taxonomy, the 2.4 MB index, 1,342 labels, `pending()`, `GroupPlanner.plan`, all of it |
| First `done` increment | **34s / 43s / 62s / 76s** across four fresh processes |
| Steady state, warm | ~3.8s per model call (~1 call per image once groups are drained) |

Two causes, both after the first paint.

**a. The first work unit is a group, and a group can cost ten model calls.**
Instrumenting every call through `ModelWatchdog` in a fresh process:

```
threw GenerationError after 0.67s :: guardrailViolation("May contain unsafe content")
threw GenerationError after 0.31s :: guardrailViolation("May contain unsafe content")
threw GenerationError after 0.23s :: refusal("May contain sensitive content")
threw GenerationError after 0.22s :: refusal("May contain sensitive content")
OK after 1.06s
OK after 6.87s   <- per-image fallback begins
OK after 6.84s
OK after 3.97s
OK after 6.91s
OK after 6.87s
```

`classify` drains groups before singles (item 10), Apple's safety layer
rejects the leading group four times in under 1.5s, and that trips the
documented "refused twice -> fall back to per-image" path. `done` advances
only when a unit completes, so the bar holds its resumed value through all
ten calls.

**b. A per-process model cold start of roughly 6-10s.** The first successful
call in a fresh process took 10.33s against 3.76-4.07s later in the *same*
process. It is per-process, not machine-idle: a run launched immediately
after another still paid it in full.

**Not the cause, checked and ruled out:** `ModelWatchdog` never fired — zero
abandonments across every run — so `Classifier.callDeadline` (30s) is not
involved. The initial guess that 76s looked like two 30s deadlines plus a
retry was refuted by the instrumentation.

**Wanted:**
1. Report progress per model *call*, not per completed unit, so the bar moves
   during a fallback burst instead of freezing. `done` counts records and must
   keep doing so (item 2, "counts are collection-relative"), so this needs a
   separate activity signal rather than a redefinition of `done`.
2. Warm the model concurrently with the index read, so the 6-10s cold start
   overlaps work the process is doing anyway rather than landing after it.
3. Surface guardrail rejections. Four refusals per group are silent today —
   only their wall-clock cost is visible, and which images trip the safety
   layer is not recorded anywhere.
4. Correct `Classifier.swift`'s deadline rationale. "A warm classify answer
   takes 2-5s, a cold first call ~19s" still sizes one *call* correctly (warm
   measures 3.8-4.1s), but a user waits on eight to ten calls, and that number
   appears nowhere near the constant it justifies.

**Where it goes:** `ClassifyRunner.run`'s `report()` and the group/fallback
loop for part 1; `ClassifyRunner.run` before the taxonomy load for part 2;
`Classifier.category(for:allowed:)`'s catch sites for part 3.

---

## 13. Label reuse keys on category names only — open question, two opposite fixes

**What happens now:** `ClassifyRunner.pending` reuses a label when its
`taxonomySignature` matches the current taxonomy and its `filterVersion`
matches `SceneFilter.filterVersion`. The signature is
`SHA256(names.sorted().joined())` truncated to 8 bytes, and `names` is
`categories.map(\.name)` — so `desc` and `examples` are outside it. The
consequences run in opposite directions and neither is what a user would guess:

| edit | reclassified | why it is wrong |
|---|---|---|
| reword a `desc` | nothing | descriptions ARE the prompt (README: "prompt material, not comments"), so the labels no longer correspond to the taxonomy on disk, and re-running will not refresh them |
| rename one category | all 1,494 | a typo fix costs a full re-run — 40-60 min for 1,500 images — with no way to decline |

Documented in the README as of 2026-08-17 (see "Reusing an earlier
`classify`"), so the behaviour is at least no longer a silent trap. The design
question is unresolved.

**The question:** these two rows want fixes that point in opposite directions,
and doing both would be incoherent.

1. **Widen the signature** to cover `desc` and `examples`, so invalidation
   tracks everything that reaches the prompt. Makes the description case
   correct — a reworded category gets reclassified. Makes the rename case
   worse: now *any* edit to the file costs the collection, including fixing a
   typo in prose that a human will read and the model largely won't notice.
2. **Add an override** — `--reuse-labels`, or a `--force` on the other side —
   so a signature mismatch becomes advisory. Makes the rename case bearable.
   Does nothing for the description case, which is the one where the user is
   not warned at all, because no mismatch is detected to override.

Both, together, would mean a tool that invalidates on every keystroke and a
flag whose normal use is to ignore that. Something else may be right: a
signature over names plus descriptions with a *reported* diff ("3 categories
reworded — reclassify those 210 records?"), which needs per-category
invalidation rather than the current all-or-nothing.

**The incremental workflow is the constraint that decides this.** Raised
2026-08-17: the steady-state use of the tool is not one big sort, it is
dropping new screenshots into the inbox and re-running. That already works
end to end — `extract` skips indexed files on name+mtime+size, `classify`
classifies only the unlabelled, and `Applier.resolve` returns `.alreadyDone`
for a file already in its correct category and `.recategorise` for one whose
verdict moved. Documented in the README as of 2026-08-17.

Two things follow for the choice above. First, option 1 (widen the signature)
gets materially worse: if the tool is re-run often, "any edit to the file
re-runs the collection" is not a one-off tax, it is a permanent deterrent to
ever touching the taxonomy again. Second, the reuse question is not only about
edits — a group is due when ANY member needs a label and deciding it rewrites
EVERY member's row, so adding a handful of images re-decides every group they
land in and can reshuffle already-filed files. That is often an improvement
(more evidence per call) but it means "reuse previous classifications" is
already only approximately true, independently of the signature. Any fix here
should say what it does about group supersession, not just about signatures.

Note this is not the same axis as item 7's agreement problem: reuse decides
*whether* to ask the model again, not whether the answer is any good.

**Where it goes:** `Taxonomy.signature` and `ClassifyRunner.pending` for the
scope of invalidation; `LabelRecord` if per-category invalidation needs more
recorded per row than one whole-taxonomy digest; `main.swift` for any flag.
Changing what goes into the signature invalidates every existing label by
construction, so it needs the migration story CONTRIBUTING.md requires of
state-format changes — the change pays its own worst case on first run.

---

## Deferred review findings

Minor items raised during implementation review and consciously not fixed at the
time. Currently recorded only in `.superpowers/sdd/progress.md`, which is
git-ignored scratch and will not survive `git clean`.

- `JSONLStore`'s first-write path uses `Data.write(.atomic)` with no `fsync`
  while the append path calls `synchronize()` — asymmetric, not a correctness
  bug.
- `TaxonomyStore`'s rejection tests assert `#expect(throws: (any Error).self)`
  rather than pinning `.invalidName(name, reason)`, so a wrong reason for a
  wrong input would pass.
- `Sampler.sampleIsDeterministic` calls `sample()` twice in one process, where
  Swift's `Dictionary` seed is fixed — it would also pass for a
  stable-but-arbitrary implementation. The implementation *is* deterministic
  (explicit sorts); the test is weaker than its name.
- `sampleRespectsTheHardCap` asserts only the aggregate ≤120; it would not catch
  9+7 where 8+8 was intended.
- `Classifier`'s `catch is ModelAvailabilityError` branch is unreachable from
  `OnDeviceResponder`, which never calls `check()`.
- `ClassifyError.categoryNotInTaxonomy` is declared but never thrown by
  production code.
- `Timestamp.swift` / `Domains.swift` carry a comment quoting a compiler
  diagnostic from an approach that was subsequently replaced; the quoted text no
  longer applies to the code beneath it.
