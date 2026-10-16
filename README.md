# lvx-perf — performance tracking for the LVX ISA and its compilers

`lvx-perf` is the long-lived record of **how fast code the LVX compilers emit
actually runs**, kept outside the trees that produce it so that the series
survives rebases, branch surgery and `results/` being overwritten.

It holds no compiler, no benchmark source and no machine description. It holds
dated snapshots of benchmark sweeps, the toolchain revisions that produced each
one, and two small tools: one to import a sweep, one to read a metric back as a
trend.

## Why it is a separate repository

The sweeps are produced in [`lvx-csw`](https://github.com/bddinechin/lvx-csw),
the cross-software superproject, by the harnesses in its `lvx-polybench/` and
`lvx-mibench/` submodules. Those harnesses write into their own `results/`
directories, and that is the wrong home for a long series:

- **PolyBench overwrites.** `harness/run.sh` writes one file per configuration,
  `results/<arch>-O<opt>-<dataset>-<type>.tsv`. Re-running a configuration
  destroys the previous numbers.
- **The compilers rebase.** `lvx-gcc` and `lvx-llvm` are trunk-tracking forks.
  History that lives on a rebased branch is history you will lose.
- **A number without a revision is not a measurement.** The useful question is
  never "how many cycles is `gemm`" but "how many cycles *more or fewer* than
  before, and what changed in between". That needs the sweep and the toolchain
  SHAs stored together, which is what a snapshot is.

So sweeps are *run* in `lvx-csw` and *kept* here.

## What it tracks

| Suite | Source submodule | What it is the instrument for |
|---|---|---|
| `polybench` | `lvx-polybench` | 30 affine dense-FP loop nests, no I/O and no syscalls. Did the vectorizer and the scheduler do their job. Cheap to sweep. |
| `mibench` | `lvx-mibench` | 13 integer, control-flow-heavy applications — jpeg, ispell, blowfish, dijkstra. Portability and realism; exercises the C library, the ABI and `argv`. |

Both measure **cycles under the gem5 ISS, not wall-clock time**. The ISS is
deterministic, so the same ELF yields the same count on any host: no averaging,
no quiet-machine ritual, and a 0.1% change is signal rather than noise. That is
what makes this a usable instrument for tracking a compiler, and it is also why
a cycle count here must never be compared against one from real hardware.

PolyBench rows carry `kernel_cycles` **and** `prog_cycles`, because its harness
brackets the kernel with `polybench_start/stop_instruments` reading `$frcc`, the
64-bit free-running cycle counter. The kernel figure is the one to track —
startup dominates the whole-program figure at `MINI` and would halve any real
improvement before it showed. MiBench has no such bracketing and reports whole
program `cycles` only.

### The correctness gate is not optional

A miscompile reads as a large speed-up. On this target a stale `libgcc`
`divv.o`, carrying eight out-of-date instruction encodings, made a `gemm`
prototype return wrong results *while exiting 0*. Every row therefore carries a
`correct` column; a row whose verdict is not `ok` or `fp-*` is **not a
performance result**. `lvx-perf-trend` prints such rows with a `*` and lists
them separately rather than dropping them — `noref` (upstream ships no reference
output for that benchmark) is a real run worth watching, just not one worth
scoring.

## Tools

Both are dependency-free — bash and Python 3, no packages to install.

```bash
# Import the current sweeps from a sibling lvx-csw checkout as today's snapshot
./bin/lvx-perf-import
./bin/lvx-perf-import --date 2026-10-14 --suite mibench
CSW=/path/to/lvx-csw ./bin/lvx-perf-import

# Read one metric back across every snapshot that measured it
./bin/lvx-perf-trend --suite mibench   --config lvx-2-O2
./bin/lvx-perf-trend --suite polybench --config lvx-2-O2-mini-double
./bin/lvx-perf-trend --suite polybench --config lvx-2-O2-mini-double \
                     --metric bundles_dyn --only gemm,syrk,2mm
```

`lvx-perf-import` locates the superproject from `$CSW`, else `../lvx-csw`, else
`~/lvx-csw`. It **refuses to import from a dirty source tree**: numbers that
cannot be tied to a revision are not reproducible by anyone, including you next
month. `--allow-dirty` records the snapshot with
`provenance unreproducible-dirty-tree` instead of blocking.

`lvx-perf-trend` compares each benchmark's first measurement against its latest,
so a benchmark added partway through the series still gets a usable figure, and
leaves a cell blank where a snapshot did not run it — suites gain and lose
entries, and a gap is not a zero.

Example, reading the committed MiBench series:

```
mibench/lvx-2-O2  metric=cycles  (lower is better, 4 snapshot(s))

benchmark          2026-10-09    2026-10-12    2026-10-13    2026-10-14     change
----------------------------------------------------------------------------------
qsort_small        19,812,178    18,249,540    18,263,018    18,263,033      -7.8%
sha                13,400,010    13,619,291    13,619,267    13,619,275      +1.6%
susan_edges         2,883,671     2,813,940     2,813,922     2,813,928      -2.4%
```

## Layout

```
bin/lvx-perf-import     snapshot a sweep out of lvx-csw, with provenance
bin/lvx-perf-trend      one metric per benchmark, across snapshots
snapshots/<date>/       the data; see snapshots/README.md for the schema
LICENSE.TXT             Apache-2.0 WITH LLVM-exception
```

## Provenance

Each snapshot's `MANIFEST` records the SHA and `git describe` of `lvx-csw`,
`lvx-mds`, `lvx-binutils`, `lvx-gcc/gcc`, `lvx-llvm/llvm-project`, `lvx-gem5`,
`lvx-newlib`, and both benchmark submodules, plus a `provenance` field:

| Value | Meaning |
|---|---|
| `exact` | imported the day the sweep ran, from clean trees — the SHAs describe these numbers |
| `as-of-import` | back-dated import; the SHAs were read at import time and may postdate the sweep |
| `unreproducible-dirty-tree` | a source tree had uncommitted changes; treat the numbers as indicative only |

The four snapshots seeded in the first commit are `as-of-import`: they are the
genuine sweeps recovered from `lvx-mibench/results/` and
`lvx-polybench/results/`, but they predate this repository, so their manifests
name the revisions current at import rather than at measurement. Snapshots
imported from here on are `exact`.

## Scope

Public, while `lvx-csw` and `lvx-mds` are private. Keep it that way: this
repository is for **numbers and revision identifiers**. The benchmark sources
are already public (`lvx-mibench`, `lvx-polybench`), as are the compiler forks,
so the sweeps disclose nothing those do not. Do not import ISA descriptions,
generated machine-description tables, instruction encodings, disassembly, or
`.s`/`.td` output into this tree — a cycle count is a measurement, an encoding
table is the architecture.

## Licensing

Apache License v2.0 with LLVM Exceptions; see `LICENSE.TXT`. Every file that can
carry a comment carries the three-line SPDX header; the Markdown documents and
`.gitignore` are covered by `LICENSE.TXT` alone.

```
SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
```

The imported TSVs are measurements of third-party benchmark suites, and the
suites keep their own terms in their own repositories: PolyBench/C is
GPL-licensed upstream, MiBench ships under its own academic terms. Measuring a
program does not relicense it, and no benchmark source is redistributed here.
