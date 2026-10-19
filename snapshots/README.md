# `snapshots/` — the data

One directory per sweep date, written by `../bin/lvx-perf-import`. A second
sweep on the same day goes beside the first as `<YYYY-MM-DD>.<n>` (`--seq n`),
never into it: one `MANIFEST` vouches for every TSV in its directory, so adding
a later sweep there would stamp the earlier numbers with the later SHAs. The
importer refuses to write into an existing snapshot.

```
snapshots/<YYYY-MM-DD>/
    MANIFEST              provenance: which revisions produced these numbers
    polybench/<config>.tsv
    mibench/<config>.tsv
```

`<config>` is the harness's own result name with any trailing date stripped —
`lvx-2-O2-mini-double`, `lvx-1-O2` — so one configuration keeps one stable
name across dates and `lvx-perf-trend` can line its columns up.

The TSVs are **verbatim copies** of what the harness in `lvx-mibench/results/`
or `lvx-polybench/results/` wrote. Nothing here rewrites a number, adds a
column, or re-derives a total; the schema is whatever the producing harness
emitted, which is why the column set may differ between older and newer
snapshots. Read a TSV's own header rather than assuming one.

Never hand-edit a TSV. If a sweep was wrong, import the corrected sweep as a
new date and say so in the commit message — the series is the record, and a
silently patched cell destroys it.

`MANIFEST` may gain a `note<TAB><text>` line by hand; that is the one edit
that is welcome, and the place to record what changed in the toolchain and why
a jump in the numbers is expected.

## The ISS CPU model is not uniform across suites

A cycle column means different things in different suites here, and until
2026-10-19 nothing recorded which:

| suite | `LVX_CPU` | what its cycles are |
|---|---|---|
| `ssw` | `minor` (its harness sets it) | pipeline timing — comparable to published figures |
| `polybench` | unset → gem5 default `atomic` | **functional counts, not timing** |
| `mibench` | unset → gem5 default `atomic` | **functional counts, not timing** |

So an `ssw` cycles/cell must never be set beside a `polybench` one, and a
comparison of two sweeps is only valid if both used the same model. `ssw` rows
now carry a `cpu_model` column; the other two suites do not, and their
committed history predates the question.

This is not a theoretical hazard. A MiBench sweep taken under `minor` against a
committed series taken under `atomic` reads as a uniform 60–240% regression,
with `bundles_dyn` flat because executed bundle count is a property of the code.
That pattern was initially diagnosed here as the ISS's timing work landing
between two dates — a plausible reading of the evidence, and wrong. `atomic`
reproduced the committed figure to 0.2%.

The MANIFEST pins `lvx-gem5`, which catches a *simulator* change. It does not
pin `LVX_CPU`, which is what catches a *model* change, and the model change is
the larger effect.

## What identifies a row differs per suite

`bin/lvx-perf-trend` keys rows on different columns depending on the suite, and
for one of them a single column is not enough:

| suite | row key |
|---|---|
| `polybench` | `kernel` |
| `mibench` | `benchmark` |
| `ssw` | `bench` |
| `turbopfor` | `config` / `codec` / `width` |

`turbopfor` emits the same codec at several widths and the same width under
several build configs within one TSV, so keying on `config` alone would
collapse six rows into three and silently report whichever came last. Composite
labels are joined with `/` and sort config-then-codec-then-width, which is the
order a reader compares in.

`arch`, `opt`, `dataset` and `type` are deliberately **not** part of any key:
they are constant within a TSV, being encoded in its filename, so including
them would add the same noise to every label.
