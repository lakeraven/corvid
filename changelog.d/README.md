# Changelog fragments

Each PR adds one file here instead of editing `CHANGELOG.md`, so merges never conflict.

- Name: `<id>.<type>.md`. `<id>` is the issue or PR number; `<type>` is one of
  `added`, `changed`, `deprecated`, `removed`, `fixed`, `security`.
- The first line becomes the first line of a bullet under `### <Type>`
  (e.g. `` `Foo.bar` returns the row (#12). It used to raise. ``).
- The rest of the file continues that bullet and is indented two spaces when assembled.
  Wrap lines as you would in `CHANGELOG.md`; write continuation text directly under the first line.
- The `<id>` is the issue the PR closes. Two PRs with the same id and type are a duplicate to resolve, not a collision to rename around.
- One fragment per PR. Add a second file with another type if the PR needs one.
- Order in the release: Added, Changed, Deprecated, Removed, Fixed, Security, then by numeric id.
  One `### <Type>` heading is written per type, so a section can sit beside an existing one in `## [Unreleased]`.
- Check: `bundle exec rake changelog:check` (validates every fragment, non-zero on a bad one).
- Release: `bundle exec rake changelog:assemble` inserts the fragments under `## [Unreleased]`,
  ahead of the existing sections, and deletes them. Commit the result. `rake release` refuses to run while fragments remain.
- Ignored by the loader: this README, `.keep`, `.gitkeep`, `.DS_Store`. Any other file is validated.
