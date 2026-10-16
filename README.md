# lvx-perf — performance tracking for the LVX ISA and its compilers

`lvx-perf` is the long-lived record of **how fast code the LVX compilers emit
actually runs**, kept outside the trees that produce it so that the series
survives rebases, branch surgery and `results/` being overwritten.

It carries the **benchmark suites as submodules** and the harnesses that run
them, the dated snapshots of their sweeps, and the toolchain revisions that
produced each one. It holds no compiler and no machine description: those stay
in [`lvx-csw`](https://github.com/bddinechin/lvx-csw), the cross-software
superproject, which is what a sweep is run *against*.

The benchmark suites were submodules of `lvx-csw` until they moved here, at the
same commits. `lvx-csw` builds the toolchain; `lvx-perf` measures it.

## Why it is a separate repository

A sweep is produced by a harness inside one of the suites here, using a
toolchain built in `lvx-csw`. The harnesses write into their own submodule's
`results/`, and that is the wrong home for a long series:

- **PolyBench overwrites.** `harness/run.sh` writes one file per configuration,
  `results/<arch>-O<opt>-<dataset>-<type>.tsv`. Re-running a configuration
  destroys the previous numbers.
- **`results/` lives in the wrong repository to be read across suites.** A
  number in `lvx-mibench` and a number in `lvx-polybench` belong to one sweep of
  one toolchain, but nothing in either repository says so.
- **The compilers rebase.** `lvx-gcc` and `lvx-llvm` are trunk-tracking forks.
  History that lives on a rebased branch is history you will lose.
- **A number without a revision is not a measurement.** The useful question is
  never "how many cycles is `gemm`" but "how many cycles *more or fewer* than
  before, and what changed in between". That needs the sweep and the toolchain
  SHAs stored together, which is what a snapshot is.

So sweeps are *run* in the submodules here and *kept* in `snapshots/`, where a
snapshot is immutable, dated, and names every revision behind it.

## The suites

| Submodule | Branch | What it is the instrument for |
|---|---|---|
| `lvx-polybench/` | `main` | PolyBench/C 4.2.1-beta: 30 affine dense-FP loop nests, no input, no I/O, no syscalls. Did the vectorizer and the scheduler do their job. Cheap to sweep — minutes. |
| `lvx-mibench/` | `main` | MiBench: 13 integer, control-flow-heavy applications — jpeg, ispell, blowfish, dijkstra. Portability and realism; exercises the C library, the ABI and `argv`. Tens of minutes to hours. |
| `lvx-ssw/` | `lvx-ssw` | Smith-Waterman, **three rows**: striped (Farrar, dominated by a data-dependent early exit), inter-sequence (Rognes/SWIPE, no branch in the inner loop), and the same inter-sequence kernel fetching scores through `_mm_shuffle_epi8` to price the ISA's missing byte gather. Real-world bioinformatics, entirely SIMD integer, over SIMDe's SSE2. The LVX-2 SIMD instrument. |

Each is pristine upstream in its first commit, so `git log` in a suite is the
complete list of what porting required, and each carries its own `GAPS.md` and
`harness/README.md` for the metrics and the traps.

`lvx-ssw` carries **three benchmarks in one suite**, tracked as separate rows:
`striped`, `inter` and `inter-gather`. They are not a speed contest with each other — different
algorithms with different ceilings — but a compiler change can move one and not
the other, which is the reason to have both. Measured 2026-10-16 on lvx-2 at
`-O2`, striped runs 11.386 cycles per cell update and inter-sequence 2.850, a
4.0× difference that is almost entirely the striped kernel's lazy-F fix-up loop
and its data-dependent early exit.

The third row prices an **ISA gap** rather than a compiler one. `inter-gather`
is `inter` with one line changed — each lane's score fetched by
`_mm_shuffle_epi8` instead of loaded from a precomputed profile — and it runs
**40.588** cycles per cell, **14.2×** slower, on identical data with an
identical checksum. LVX has only structured UZP/ZIP permutes and no
runtime-indexed byte gather, so nothing in GCC or SIMDe can move that number;
closing it would be an ISA change. Which is exactly why it is a *series*: the
two rows converge the day such an instruction lands, and until then 14.2× is
the figure the argument for adding one needs — a per-cell cost in a real
kernel, not 22 instructions in a microbenchmark.

That three-row shape is also the clearest illustration of why this repository
tracks shapes rather than kernel counts. The same suite now distinguishes a
branch-dominated kernel, a throughput kernel, and a kernel bottlenecked on one
missing instruction — and a toolchain change can move any one of them without
touching the others.

That pairing exists because of what PolyBench showed the same day: a breadth
gate can be completely blind to a change. The vector-comparison work left all
240 PolyBench kernel-measurements codegen-identical, because those kernels use
comparisons in scalar control flow and never as vector values. **Coverage of
different shapes matters more than more kernels of one shape**, and the two SSW
benchmarks differ in exactly the dimension that mattered there — one is
branch-dominated, the other has no branch in its inner loop at all.

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

### PolyBench carries the evidence for a compiler default in `lvx-csw`

`param_vect_partial_vector_usage` is pinned to **1** in `lvx_option_override`
in `lvx-gcc`, and the justification is a PolyBench sweep kept here: across 30
kernels at both FP widths, usage=1 is best-or-tied on **all 60**
kernel-width combinations, usage=0 is never better, usage=2 loses `fdtd-2d` by
1.2%, and `durbin` at 0.9940× is the single case in that work where a masked
epilogue actually wins.

The coupling is worth stating plainly because the split hid it: the pin lives
in one repository and its evidence in another. Anyone re-opening that default
should re-run the sweep here rather than reason about it, and anyone changing
these kernels should know a compiler default rests on them.

### The correctness gate is not optional

A miscompile reads as a large speed-up. On this target a stale `libgcc`
`divv.o`, carrying eight out-of-date instruction encodings, made a `gemm`
prototype return wrong results *while exiting 0*. Every row therefore carries a
`correct` column; a row whose verdict is not `ok` or `fp-*` is **not a
performance result**. `lvx-perf-trend` prints such rows with a `*` and lists
them separately rather than dropping them — `noref` (upstream ships no reference
output for that benchmark) is a real run worth watching, just not one worth
scoring.

## Locating `lvx-csw` — the one parameter

**`lvx-perf` cannot be self-contained**, and this is the consequence worth
understanding before anything else here. It measures a toolchain that is a
*build product* of a **built** `lvx-csw` checkout: `lvx-toolchain/bin` and
`lvx-gem5/build` are in nobody's git, so they cannot be submodules, vendored or
pinned. `lvx-ssw` additionally compiles through `lvx-simde`, and links
`validation/lib/crt.S` — both of which stay in `lvx-csw`.

So that checkout's location is a **parameter of every harness and every tool
here**, resolved the same way by all of them. Highest precedence first:

| Mechanism | For |
|---|---|
| `--csw <path>` | a one-off, or a CI job measuring a specific tree |
| `$LVX_CSW` | a shell session, or a whole sweep |
| `./lvx-csw.path` | **per machine, set once.** One line, not committed |
| `../lvx-csw` | the default: the two checkouts as siblings |
| `~/lvx-csw` | last resort (tools only) |

```bash
echo /path/to/lvx-csw > lvx-csw.path    # the usual answer, once
./bin/lvx-csw-path --check              # what is resolved, and what is built
LVX_CSW=/other/tree ./bin/lvx-perf-import
cd lvx-polybench && ./harness/run.sh --csw /other/tree
```

`bin/lvx-csw-path` owns the chain, so there is a single place to change it and
a single place that documents it. Two properties it is built to have:

- **A path you name is never silently replaced by a fallback.** Point at the
  wrong tree and the error says which mechanism named it — because the failure
  this design exists to prevent is quietly measuring a *different* checkout's
  compiler and filing the numbers as if they were this one's.
- **"There but not built" is reported as itself.** A fresh `lvx-csw` clone has
  no `lvx-toolchain/`, and that is its ordinary state, not a broken tree; the
  error says `make install-minimal-toolchain` rather than leaving a missing
  compiler to surface as a failed compile thirty kernels in.

The default is a default, not an assumption: `../lvx-csw` is where these
checkouts usually sit, and naming any other path costs one line. Until
2026-10-16 the harnesses took the suite's *parent directory* to be `lvx-csw`,
which was true only while they were submodules of it — moving them here made
that guess resolve to `lvx-perf`, which has no compiler in it at all.

## Tools

Both are dependency-free — bash and Python 3, no packages to install.

```bash
./sync-from-work.sh                        # after cloning, and to pick up another machine's work
echo /path/to/lvx-csw > lvx-csw.path       # once per machine; see below
./bin/lvx-csw-path --check                 # is it there, and is it built?

# Run a sweep, in the suite's own submodule
cd lvx-polybench && ./harness/run.sh && cd ..
cd lvx-mibench   && ./harness/run.sh && cd ..
cd lvx-ssw       && ./harness/run.sh && cd ..
cd lvx-polybench && COMPILER=clang ./harness/run.sh && cd ..   # lvx-llvm

# Snapshot whatever the suites currently have in results/
./bin/lvx-perf-import
./bin/lvx-perf-import --date 2026-10-14 --suite mibench
CSW=/path/to/lvx-csw ./bin/lvx-perf-import

# Read one metric back across every snapshot that measured it
./bin/lvx-perf-trend --suite mibench   --config lvx-2-O2
./bin/lvx-perf-trend --suite polybench --config lvx-2-O2-mini-double
./bin/lvx-perf-trend --suite ssw       --config lvx-2-O2
./bin/lvx-perf-trend --suite polybench --config lvx-2-O2-mini-double
./bin/lvx-perf-trend --suite ssw       --config lvx-2-O2 \
                     --metric bundles_dyn --only gemm,syrk,2mm
```

`lvx-perf-import` reads each sweep from `./lvx-<suite>/results` and finds
`lvx-csw` — for the compiler revisions — at `$CSW`, else `../lvx-csw`, else
`~/lvx-csw`. It still records a snapshot if `lvx-csw` is absent, with a warning,
because a sweep naming no compiler is hard to read later.

It **refuses to import when an input tree is dirty**: numbers that cannot be
tied to a revision are not reproducible by anyone, including you next month.
An uncommitted `results/` is deliberately *not* dirt — that is the sweep's
output, not an input to it, and the harnesses tell you to commit results after
the fact. `--allow-dirty` records the snapshot with
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

## Two compilers, two series

Every harness takes `COMPILER=gcc|clang`, default `gcc`. A clang sweep is a
**separate configuration**, not extra rows: its files are named with `-clang`
after the arch — `lvx-2-clang-O2-mini-double`, `lvx-2-clang-O2` — so
`lvx-perf-import` snapshots them beside the GCC files and `lvx-perf-trend
--config lvx-2-clang-O2` reads them back as their own series. GCC keeps the
unmarked names so the series that predates clang is continuous. Both
compilers' SHAs are in every `MANIFEST` already, so a snapshot holding both
names the revision behind each.

The harness, not the caller, picks the core flag: lvx-gcc spells it
`-march=lvx-2`, clang `-mcpu=lvx-2`. Until lvx-llvm `d7a03955` (2026-10-16)
clang given `-march=lvx-2` only warned and emitted **lvx-1** code, which would
then have been timed under the lvx-2 ISS; `-march` is an alias there now, and
the harness passes `-mcpu` regardless. Both drivers link the
same runtime (crt0, newlib, libgloss, libgcc and `lvx-sim.ld` are lvx-gcc's),
so a GCC/clang difference is a code-generation difference.

Which core clang can target depends on the machine description `lvx-csw`
installed into lvx-llvm, not on `-mcpu`: since 2026-10-16 that is `lvx_v2`,
on which `-mcpu=lvx-1` is **unsupported** — the vectorizer still emits lvx-2
instructions, and some programs then fail to assemble or compute a wrong
answer. Sweep clang on lvx-2 only unless `lvx-llvm/CLAUDE.md` says otherwise;
the correctness gate would catch a wrong answer, but the number would not be
an lvx-1 measurement either way.

A build failure is recorded as a row (`buildfail`, `BUILD_OR_SELFCHECK`), not
dropped, so the day it starts building shows up in the series.

## Layout

```
lvx-polybench/          submodule: the suites and their harnesses, where
lvx-mibench/              sweeps are run and results/ is written
lvx-ssw/
sync-from-work.sh       pull, and update the submodules on their branches
lvx-csw.path            where lvx-csw is on this machine (not committed)
bin/lvx-csw-path        resolve/check lvx-csw; owns the resolution chain
bin/lvx-perf-import     snapshot the suites' results/, with provenance
bin/lvx-perf-trend      one metric per benchmark, across snapshots
snapshots/<date>/       the data; see snapshots/README.md for the schema
LICENSE.TXT             Apache-2.0 WITH LLVM-exception
```

Clone it with the suites:

```bash
git clone --recurse-submodules git@github.com:bddinechin/lvx-perf.git
cd lvx-perf && ./sync-from-work.sh
```

Use `./sync-from-work.sh` rather than `git pull && git submodule update`
whenever you switch machines. It leaves every suite on its branch rather than a
detached HEAD, which matters here because sweeps commit their results into the
suites. It also stops before merging if a suite's branch was rebased elsewhere,
and touches nothing it cannot sync without losing work. `lvx-csw` carries the
same script.

## Provenance

Each snapshot's `MANIFEST` records the SHA and `git describe` of two groups —
the **suites**, which are submodules here (`lvx-mibench`, `lvx-polybench`,
`lvx-ssw`, plus `lvx-perf` itself), and the **toolchain**, read from `lvx-csw`
(`lvx-csw`, `lvx-mds`, `lvx-binutils`, `lvx-gcc/gcc`, `lvx-llvm/llvm-project`,
`lvx-gem5`, `lvx-newlib`) — plus a `provenance` field:

| Value | Meaning |
|---|---|
| `exact` | imported the day the sweep ran, from clean trees — the SHAs describe these numbers |
| `as-of-import` | back-dated import; the SHAs were read at import time and may postdate the sweep |
| `unreproducible-dirty-tree` | a source tree had uncommitted changes; treat the numbers as indicative only |

`lvx-perf`'s own line is recorded but never gates an import: this repository
holds the snapshots and the tools, not an input to the measurement, so an
unstaged README must not block a sweep from being recorded.

The four snapshots seeded in the first commit are `as-of-import`: they are the
genuine sweeps recovered from the suites' `results/` directories, but they
predate this repository, so their manifests name the revisions current at import
rather than at measurement. Snapshots imported from here on are `exact`.

## Scope

Public, while `lvx-csw` and `lvx-mds` are private. All three suites are public
repositories, as are the compiler forks, so nothing here discloses what they do
not. Keep it that way: this repository is for **benchmark sources, numbers and
revision identifiers**. Do not add ISA descriptions, generated
machine-description tables, instruction encodings, disassembly, or `.s`/`.td`
output — a cycle count is a measurement, an encoding table is the architecture.

## Licensing

Apache License v2.0 with LLVM Exceptions; see `LICENSE.TXT`. Every file that can
carry a comment carries the three-line SPDX header; the Markdown documents and
`.gitignore` are covered by `LICENSE.TXT` alone.

```
SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
```

That covers this repository's own files — the tools, the documents, and the
snapshot TSVs, which are measurements rather than derived source.

**The submodules are separate repositories under their own terms**, which this
repository does not alter:

| Suite | Upstream license |
|---|---|
| `lvx-polybench` | Ohio State University Software Distribution License (permissive, BSD-family) |
| `lvx-ssw` | MIT |
| `lvx-mibench` | No single upstream license: a pristine import of the UMich group tarballs, whose constituent programs — jpeg, ispell, blowfish, rijndael — each carry their own terms. Check the individual program before reusing its source. |

Each suite's `harness/` is project-authored and shares its repository's terms;
`lvx-polybench/harness/guest-output.py` is also kept in `lvx-csw/validation/`,
where it is the same project-authored file under that repository's Apache-2.0
WITH LLVM-exception header.
