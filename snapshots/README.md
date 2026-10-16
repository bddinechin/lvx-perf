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
