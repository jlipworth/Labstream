# App Store metadata

Product-page text for the four Labstream App Store platform versions, one plain-text file per
field. `scripts/asc-metadata.py` validates the files (`check`), compares them with App Store
Connect (`diff`), refreshes them (`pull`), and writes reviewed changes back (`push --yes`). The
layout and the managed fields are described at the top of that script.

- Edit the files here and review them in a pull request, then push after merge.
- Review contact details and demo-account credentials never belong in this directory; enter them
  only in App Store Connect.
- `review_notes.txt` is the App Review note. Re-check it on clean installs of the exact release
  candidate before submission (see `docs/plans/2026-09-15-store-demo-capture.md`).
- `whats_new.txt` stays empty for the first public version and describes each later update.
