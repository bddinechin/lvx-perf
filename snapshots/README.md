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

## Single-precision literals: checked 2026-10-22, and mostly a non-issue

`bin/lvx-fp-literals` scans for floating-point literals that are `double` in
single-precision code — a bare `1.0` promotes `floatvar * 1.0` to double, which
costs a widen/narrow pair and can suppress vectorisation. In a suite whose
element type is a macro (`real_t`, `DATA_TYPE`) it silently pins the arithmetic
to double even in the float build.

Result across the suites:

| suite | flagged | assessment |
|---|---|---|
| `lvx-tsvc2` | 4 | the only suite where it could matter; see below |
| `lvx-polybench` | 8 | all in `init_array` and the timer — the kernels use `SCALAR_VAL` (62 uses), so the timed code is type-aware |
| `lvx-ssw` | 2 | upstream's CLI driver, genuinely double (`log()` arithmetic); not on the benchmark path |
| `lvx-turbopfor` | 27 | `round()` and timers, genuinely double |
| `lvx-mibench` | ~660 | 644 float declarations against 522 double: mixed by design, spread thin across lout/tiff/rsynth, none an FP hot path |

**TSVC's upstream authors were careful**, which is the main finding: they used
49 explicit `(real_t)` casts rather than `f` suffixes, which is equivalent and
type-correct for both widths. Four sites escaped, and measuring each rather
than assuming turned a large-looking number into a small one:

| site | in the timed region | measured |
|---|---|---|
| `tsvc.c:1631` `if (a[i] > 0.)` | yes | **nothing** — identical codegen, 44 insns and 9 SIMD either way; GCC narrows the comparison |
| `tsvc.c:2239` `/1.9` | yes | 2 widen/narrow per iteration, and the loop (`s2102`) carries a real cross-iteration dependence so it does not vectorise either way |
| `common.c:139`, `:143` | **no** — `initialise_arrays` | outside the measurement |

**Fixed on 2026-10-22 (lvx-tsvc2 `7111ef3`), and the fix changes nothing
measurable** — which is worth recording because this entry previously argued
against making it, on two predictions that both turned out false.

The argument was that changing the arithmetic would invalidate every checksum
(`common.c:139` being the initialiser feeding all 151 loops) for a gain of two
instructions per iteration. Measured:

| | result |
|---|---|
| checksums changed, float | **0 of 151** |
| checksums changed, double | **0 of 151** |
| `tsvc.c` instructions | 10257 → **10257** |
| `tsvc.c` SIMD instructions | 609 → **609** |

Identical in both FP modes. `1.0/x` computed in double and rounded once to
float gives the same float as the float division — IEEE division is correctly
rounded and double rounding differs only on a tie, which `1/n` for n ≤ 32000
does not produce. And GCC's front end already narrows
`float op double_constant` when the constant is exactly representable
(`shorten_binary_op`, `shorten_compare`), so there was no widen/narrow to
remove. The two-instruction figure came from a hand-reduced version of the
loop, and reducing it changed what was being measured.

The casts are kept for reasons that are not performance: they state the intent,
match upstream's convention in 49 other places, clear the scanner so a future
real finding is not buried in known noise, and do not depend on a front-end
narrowing another compiler need not perform.

The scanner is committed so the check is repeatable rather than a one-off, and
its header lists what it deliberately does not flag — explicit casts, whole
assignments, and complete function arguments. That last rule is what separates
a useful result from a useless one: without it TSVC reports 133 hits, 124 of
them the `dummy(..., 0.)` that closes every loop.
