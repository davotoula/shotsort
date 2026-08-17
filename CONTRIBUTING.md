# Contributing to shotsort

Thanks for looking. This is a small, opinionated tool with an unusual review bar,
so this document is mostly about **what counts as evidence** that a change works.

## The short version

1. `swift test` must pass.
2. **You must have run the binary on real input.** This is a hard requirement, not
   a nicety — see below.
3. New features come with a screenshot of the tool actually doing the thing.
4. Never commit a real screenshot from anyone's collection.

## Requirements

- macOS 26+ on Apple silicon
- Apple Intelligence enabled in System Settings (needed to run `propose` and
  `classify` — *not* needed to run the test suite)
- Swift 6.2+ toolchain

```sh
swift build          # debug
swift test           # 202 tests, no model and no network required
swift build -c release
```

## Running the binary is a hard requirement

A green test suite does not tell you a change to shotsort works. This is not
generic caution; it is the repeated, documented experience of this project:

- Per-image classification produced a **plausible category histogram** — News 70,
  Crypto 81, a sensible taper — while same-source consistency was **7%**. Six
  `accuweather.com` screenshots went to six different folders. Every test passed.
- `classify` looked healthy on every signal available without running it —
  low `Unsorted`, no schema misses — and `--verify` reported **26% agreement**.
  Without running it, 1,494 personal files would have been sorted on assignments
  that flip more than half the time.
- The Vision segfault only appears under sustained real load. No unit test
  reproduces it.
- The CLI branch choosing dry-run vs `--commit` has **no automated test**, because
  `main.swift` is an executable with top-level code and no test target. Choosing
  wrong moves every file in the inbox.

So: build it, point it at a folder, run the stages your change touches, and put the
output in the pull request.

### What to run, by area

| If you changed… | Run at minimum |
|---|---|
| `Extract/`, `Scene/` | `shotsort extract` over ≥50 images, then `shotsort diagnose` — paste the diagnose output |
| `Propose/` | `shotsort propose` — paste the proposed taxonomy |
| `Classify/`, `ClassifyRunner` | `shotsort classify --limit 50 --verify` — **report the agreement number**, and the reason histogram |
| `Apply/`, `main.swift` | `shotsort apply` (dry run), `apply --commit`, then `undo` — confirm the round trip returns every file |
| Anything touching taxonomy validation | Load a deliberately bad taxonomy and confirm it is *rejected*, not rewritten |

### Setting up a scratch inbox

`shotsort` defaults the inbox to `.` and the output to `./ss-sorted`, so any
scratch directory works — no fixed location to set up first:

```sh
mkdir -p /tmp/ss-scratch
cp fixtures/synthetic/*.png /tmp/ss-scratch   # copy, never move — apply moves files
cd /tmp/ss-scratch
shotsort extract
```

State lands in `./ss-sorted/`. Use your own screenshots, a folder of synthetic
images, or anything you own; pass `--inbox`/`--output` instead of `cd`-ing if you
want the scratch tree somewhere other than the current directory. Start from a
clean state with `rm -rf ss-sorted/.shotsort` when a change alters the index or
label format.

## Screenshots for new features

If you add a feature, include a screenshot of it working. For a CLI that mostly
means terminal output; for anything that changes the sorted result, a Finder window
of the resulting folders is more convincing than a log.

- **Attach images to the pull request description** (drag and drop — GitHub hosts
  them) rather than committing them. The only images in the repo are `assets/`,
  which the README renders, and the synthetic test fixtures. If a change genuinely
  needs a new README image, put it in `assets/` and say so in the PR.
- **Anything in `assets/` must be synthetic or redacted**, to the same standard as
  the rule below. A README screenshot is the most-viewed file in the project and
  the hardest to grep, so it is the worst place for a real filename to survive.
- **Redact before you post.** A screenshot of shotsort output shows filenames,
  harvested domains, OCR fragments and category assignments — that is a window into
  someone's private collection, including yours. Use synthetic input, or blur the
  identifying parts. Reviewers will ask you to.

## Never commit real screenshots

The constraint that forbids network calls forbids this too, and for the same
reason. Committed fixtures are **synthetic** — see `fixtures/synthetic/` and
`make_fixtures.swift`, which generates images with known text so OCR expectations
can be asserted exactly.

`fixtures/local/` is git-ignored for ad-hoc testing against real screenshots. Keep
your real material there. No test may depend on it.

## Conventions

**No network code. Ever.** shotsort makes no network calls, and this is structural
rather than a setting. A pull request that adds a dependency on a remote service,
a telemetry ping, or a "just for the optional cloud fallback" code path will be
declined regardless of how good it is. The material this tool reads includes video
calls and banking screens.

**No third-party dependencies.** The package builds one binary against Vision and
FoundationModels. Keep it that way.

**Measurements beat opinions.** Most claims in this repository carry a number next
to them, because most of the interesting bugs looked like successes. If you are
changing classification behaviour, say what you measured, on how many records, and
against which taxonomy.

**Comments explain why, not what.** The existing code is dense with rationale —
why concurrency is capped at 2, why net state is verified against the filesystem,
why the no-signal gate is spelled out to the constant. Match that. If you remove a
constraint, remove the comment explaining it in the same commit.

**Tests must not need Apple Intelligence or a network.** Inject a `CategoryResponder`
and pass `checkAvailability: false`, as the existing `ClassifyRunner` tests do. CI
and contributors without Apple Intelligence must still be able to run the suite.

**Commit messages** follow the existing style: a lowercase `type: imperative
subject`, where type is `feat`, `fix`, `docs`, `chore` or `refactor`. One logical
change per commit.

```
feat: classify due groups first, atomically, with per-image fallback
fix: widen the TLD allowlist to the domains the collection actually uses
docs: record the scene-fallback and TLD-allowlist outcomes
```

## Substantial changes start with a design note

If you are changing the pipeline's shape — a new stage, a different unit of
classification, a change to the state file formats — open an issue or a draft PR
with a short design note before writing the code. Three things, which is the
level of detail that has worked here: the decision, the alternative rejected,
and what would falsify it.

The note belongs in the issue or PR, not in the repo. What survives the merge is
the doc comment at the declaration and, if the change was driven by something
observed in real use, an entry in `TODO.md` with its numbers. `ModelWatchdog`
and `Taxonomy.signature` are the pattern to copy.

State file format changes need a migration story. `index.jsonl` represents hours of
extraction that users should not have to repeat.

## Reporting bugs

Include:

- macOS version (`sw_vers`) and `swift --version`
- the exact command and its full output
- how many records are in `index.jsonl`, if the stage reads it
- for classification issues: the taxonomy you used, and the `--verify` agreement
  number if you have it

"It picked the wrong category" is expected behaviour at the current accuracy — see
[Accuracy, measured](README.md#accuracy-measured) in the README. "It picked
*different* categories for screenshots from the same source" is a real bug and
worth reporting.

## Pull request checklist

- [ ] `swift test` passes
- [ ] I ran the binary on the stages this change touches, and pasted the output
- [ ] New feature? Screenshot attached, with private content redacted
- [ ] No real screenshots committed
- [ ] No new dependencies, no network code
- [ ] Comments explain why; stale rationale removed
- [ ] Behaviour claims backed by a number, with the sample size stated

## Conduct

Be straightforward and civil. Disagree with the argument, not the person. Reviews
here are direct about evidence — that is about the code, never about you.
