# Select and read transcripts

Use the exposed Scribird tools by their current connected names; the names below
are their server-local names. The read contract is maintained in `mcp/README.md`.

## Select the recording and root

For a supplied `session_directory`, call `read_session` directly. For a day of
recordings, resolve the date in the user's timezone and call `list_sessions` with
`kind: "live"` and `recording_date: "YYYY-MM-DD"`. The filter uses the recording
machine's local folder date, not modification time; do not invent an archive's
timezone. Imports have no inferred recording date: select a named import or list
`kind: "import"` without the date filter.

Omit `output_root` to use the app's effective/saved location. Supply it for a
user-named root or a known old/fallback root. Use returned `sessionDirectory` paths.
The list is newest modified first; writing a report into an old folder does not
make that folder the latest recording.

## Read every requested page

Follow the returned `nextOffset` until `hasMore` is false, for both listing and
reading. Use manageable transcript pages, for example `limit: 100`, and retain
the earlier pages' evidence. Do not recompute offsets or declare full coverage
while more requested records remain unread.

A live archive can grow. Describe the persisted range actually read without
stopping the recording or waiting indefinitely for it to end. If the source
changes between reads, distinguish the observed snapshots instead of merging
their counts as if they were independent sessions.

## Reuse the returned fields

| Data | Interpretation |
| --- | --- |
| `segments`, `text`, `jsonlPath` | Original words and their source; preserve language changes and uncertainty. |
| `citationLabels` | Source lines and whole-second timecodes, in the same order as this page's segments. Copy the labels and matching text. |
| `total`, `transcriptSummary.labelCounts` | Counts across all complete records, not page totals or attendee counts. |
| `transcriptSummary` time fields | Earliest valid start through latest valid end. The span includes gaps; it is not audio duration or summed speaking time. |

`localStartedAt` is inferred from the folder name and has no timezone. Citation
timecodes truncate to whole seconds; preserve raw `start`/`end` values when their
precision matters. `timestampGranularities` containing `chunk` does not establish
word-accurate timing. Missing/invalid times remain unavailable, as counted in
`missingOrInvalidTimingCount`; do not interpolate them from neighboring records.

## Handle incomplete evidence

`incompleteTrailingLine` reports an omitted final unfinished record; the complete
records remain usable. A malformed complete record is a tool error, not permission
to silently discard that line. If a page or session cannot be read, report the
missing scope and continue independent work from evidence already available.

Missing/unplayable audio changes whether an acoustic check is possible. It does
not invalidate readable saved text. `me`/`remote` name capture paths and `unknown`
names unassigned import voices; none of them identifies an actual attendee.
