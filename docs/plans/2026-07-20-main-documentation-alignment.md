# Main Documentation Alignment and Information Architecture Plan

**Date:** 2026-07-20  
**Status:** Active. The factual-alignment phase landed in `0cd588c2`; the information-architecture, Mermaid, and durable-governance phase is approved but not yet implemented.

## Goal

Make the repository documentation accurate, executable, discoverable, and maintainable. This plan covers both:

1. alignment of current guidance with behavior shipped on `main`; and
2. the documentation system itself: file placement, folder contracts, naming, navigation, Mermaid rendering, diagram ownership, validation, and instructions for future contributors and agents.

This is the sole plan for the work. Do not create separate design and implementation plans.

## Scope decisions

- Preserve stable URLs for published topic pages unless a rename fixes a concrete semantic defect.
- Reorganize unpublished documents into explicit `plans`, `research`, `evidence`, and `archive` lanes.
- Keep `TESTING-CHECKLIST.md` at the repository root as a deliberate operational exception, but link it prominently.
- Use MkDocs Material's bundled Mermaid integration. Do not add a Mermaid plugin, CDN script, npm documentation runtime, vendored JavaScript, or generated image copies.
- Repair existing diagrams and add only targeted visuals that clarify load-bearing architecture.
- Record the resulting idioms in lane READMEs, contributor guidance, and project `CLAUDE.md` for future agents.

## Phase 1: Contributor workflow — complete

Implemented in `0cd588c2`:

- Added a complete initial visionOS simulator bootstrap for a clone with no `.simid`.
- Made `docs/DEVELOPMENT.md` canonical for simulator provisioning, exact-product build/install, observable smoke criteria, simulator shutdown, and linked-worktree closeout.
- Replaced divergent recipes in `README.md`, `docs/CONTRIBUTING.md`, `docs/MOBILE-IOS.md`, and `docs/TESTING-STRATEGY.md` with concise platform-specific entry points.
- Added the missing `uv` prerequisite and complete physical Vision Pro first-use guidance.
- Preserved independent mobile-only simulator setup without a visionOS prerequisite.

## Phase 2: Architecture and current behavior — complete

Implemented in `0cd588c2`:

- Corrected playback ownership, initial negotiation, prewarming, stall deadlines, replacement cleanup, and Dolby Vision claims.
- Added current SharePlay ownership, privacy, local resolution, routing, and Cinema continuity.
- Documented visionOS Now Playing separately from the iOS/macOS system-media lease.
- Corrected PMSKit effect boundaries and stale source paths.

## Phase 3: Downloads and live validation — complete

Implemented in `0cd588c2`:

- Documented completed-row poster/chapter repair and the current process-lifetime retry budget semantics.
- Corrected the active checklist to the 512 MiB static-range regime.
- Added focused regression checks for Now Playing, SharePlay lifecycle races, iPad trick-play, side-asset repair, and range-auth ownership.
- Added triage-first evidence guidance and corrected the Mac validator's documentation references.
- Added a read-only `worktree-sim.sh --help` contract and regression coverage.

## Phase 4: Documentation information architecture

### Target taxonomy

```text
docs/
├── *.md                     # Current, published guidance and architecture
├── plans/                   # Active implementation plans and acceptance journals
├── research/                # Active investigations with unresolved questions
├── evidence/
│   ├── audits/              # Immutable audit and review evidence
│   └── profiling/           # Immutable profiling baselines
└── archive/
    ├── plans/               # Completed or superseded plans
    ├── reviews/             # Resolved point-in-time reviews
    ├── research/            # Closed investigations
    ├── downloads/
    ├── macos/
    ├── testing/
    ├── proposals/
    └── first-public-cleanup/
```

Published topic pages remain at their current paths. The repository-root `TESTING-CHECKLIST.md` remains a documented exception.

### Lane contracts

Add or revise READMEs so each lane answers what belongs there, what does not, how files are named, and when material moves:

- `docs/plans/README.md`: active implementation plans and acceptance journals;
- `docs/research/README.md`: unresolved investigations only;
- `docs/evidence/README.md`: immutable observations rather than current guidance;
- `docs/evidence/audits/README.md`: dated audit and review evidence;
- `docs/evidence/profiling/README.md`: immutable profiling baselines;
- `docs/archive/README.md`: completed or superseded context that is never canonical.

### Required moves

Use `git mv` and update live links together:

- `docs/research/2026-07-10-codebase-remediation-plan.md`
  → `docs/plans/2026-07-10-codebase-remediation.md`
- `docs/research/2026-07-20-tvos-implementation-plan.md`
  → `docs/plans/2026-07-20-tvos-implementation.md`
- `docs/research/2026-07-12-remediation-branch-review.md`
  → `docs/archive/reviews/2026-07-12-remediation-branch-review.md`
- `docs/research/2026-07-12-remediation-delta-review.md`
  → `docs/archive/reviews/2026-07-12-remediation-delta-review.md`
- `docs/research/offline-playback-compatibility.md`
  → `docs/archive/research/2026-06-27-offline-playback-compatibility.md`
- `docs/research/2026-07-15-optional-download-side-assets.md`
  → `docs/archive/downloads/2026-07-15-optional-download-side-assets.md`
- `docs/audits/`
  → `docs/evidence/audits/`
- `docs/profiling/baselines/`
  → `docs/evidence/profiling/`
- `docs/BUILD-PERFORMANCE-AUDIT.md`
  → `docs/COMPILE-PERFORMANCE.md`

The alignment plan is active at `docs/plans/2026-07-20-main-documentation-alignment.md`. Archive it under `docs/archive/plans/` only after every phase and verification gate in this file is complete.

### Migration rules

- Repair every live Markdown link, MkDocs nav entry, include, script reference, and active contributor instruction affected by a move.
- Preserve historical path literals inside archived snapshots unless they are intended as clickable navigation.
- Do not reorganize published pages into audience/topic subfolders merely for symmetry.
- Remove stale MkDocs exclusions for nonexistent top-level `proposals/` and `superpowers/`; add exclusions for active `plans/` and `evidence/` lanes.
- Update `README.md` and `docs/DEVELOPMENT.md` to explain all internal lanes, not only research and archive.
- Keep root legal/support files and the include adapters under `docs/` unchanged.

## Phase 5: Mermaid rendering and diagram ownership

### Rendering setup

Configure the existing `pymdownx.superfences` extension in `mkdocs.yml`:

```yaml
- pymdownx.superfences:
    custom_fences:
      - name: mermaid
        class: mermaid
        format: !!python/name:pymdownx.superfences.fence_code_format
```

No dependency change is required. Do not add `mkdocs-mermaid2-plugin`, external JavaScript, custom Mermaid CSS, npm tooling, or pre-rendered SVG/PNG copies unless a separately approved requirement cannot be met by the bundled Material integration.

### Diagram conventions

Every retained or new Mermaid diagram must:

- live beside the canonical prose it illustrates;
- include `accTitle` and `accDescr`;
- have adjacent prose that remains complete without JavaScript;
- avoid HTML labels, click directives, custom colors, and meaning encoded only through color or line style;
- use conservative flowchart, sequence, or state syntax compatible with GitHub and MkDocs Material;
- remain readable at narrow mobile widths;
- change in the same commit as behavior or ownership it depicts.

### Existing diagram work

Retain and accessibilize:

- landing-page topology;
- high-level architecture composition;
- playback startup sequence;
- persistence storage boundaries;
- diagnostics redaction/export flow;
- system-entry routing.

Correct or replace:

- redraw the download lifecycle as actual persisted row states, including `.unverified`;
- replace the backend overview with the Plex versus shared Jellyfin/Emby abstraction boundary;
- remove the volatile and redundant `CODE-MAP.md` mindmap;
- remove or replace the misleading Testing Strategy flowchart with an accurate change-type/validation-lane view;
- replace or remove the generic music-provider diagram unless it expresses the real browse-session, app-lifetime player/queue, and system-media boundaries;
- keep the download route overview only if it clearly distinguishes static from live-forward durability.

Add only these high-value diagrams:

- static segment-train data flow in `docs/DOWNLOADS-OFFLINE.md`;
- SharePlay privacy and participant-local resolution sequence in `docs/SYSTEM-INTEGRATION.md`;
- Plex versus Jellyfin/Emby replacement-cleanup ordering in `docs/PLAYBACK-ARCHITECTURE.md`.

Do not add diagrams to command procedures, comparison tables, the manual checklist, legal/support pages, CI trust prohibitions, or complete per-file dependency maps.

## Phase 6: Durable contributor and agent idioms

### Contributor-facing guidance

Update `docs/CONTRIBUTING.md` to summarize:

- how to classify a new document;
- lane and filename conventions;
- promotion from research/evidence into current published guidance;
- archival rules for completed plans and resolved reviews;
- Mermaid source, accessibility, ownership, and validation rules.

### Agent-facing guidance

Add a concise **Documentation information architecture** section to project `CLAUDE.md` instructing future agents to:

- evaluate factual accuracy and information architecture together;
- classify documents before creating them;
- never create tool-branded hierarchies such as `docs/superpowers/`;
- use the repository's current/plans/research/evidence/archive lanes;
- keep published URLs stable unless a move has concrete semantic benefit;
- avoid separate design and implementation plans when one durable plan is sufficient;
- promote proven behavior into canonical current docs;
- archive completed plans and resolved reviews;
- preserve historical prose while repairing live links during moves;
- co-locate Mermaid with canonical prose and update diagrams with depicted behavior;
- run all required documentation verification after content or path changes.

## Workflow architecture

Execute the remaining phases in this order:

1. **Taxonomy and moves:** create lane contracts, move files, update indexes and links.
2. **Mermaid infrastructure:** enable rendering and add structural validation before editing diagram content.
3. **Diagram corrections:** repair/remove existing diagrams and add the three approved visuals.
4. **Durable idioms:** update contributor and agent guidance.
5. **Integration review:** compare the full diff against this plan, current code, and repository history.
6. **Verification:** run every gate below and correct confirmed defects.

Agents may work in parallel only on non-overlapping files. Do not create another plan, branch, or worktree unless explicitly requested.

## Verification

### Diff and scope

```sh
git diff --check
```

Review the full diff for unsupported factual changes, accidental app/package code edits, sensitive identifiers, historical rewrites, and unapproved path churn.

### Published documentation

```sh
uv run --with-requirements requirements.txt \
  mkdocs build --strict --config-file mkdocs.yml
scripts/ci-hygiene.sh
```

### Repository-wide links

Validate relative Markdown links and heading anchors across root documents, published docs, plans, research, evidence, and archive. MkDocs exclusions are not sufficient because strict builds do not validate every unpublished lane.

### Mermaid structure

After the strict build:

- count published source ```` ```mermaid ```` fences;
- count generated `class="mermaid"` containers;
- require the counts to match;
- reject literal ```` ```mermaid ```` text in generated HTML;
- reject new external Mermaid/CDN script references.

Add this structural check to repository hygiene and unprivileged documentation CI.

### Browser and accessibility checks

Inspect representative flowchart, sequence, and state diagrams in the served MkDocs site:

- no Mermaid parser or console errors;
- readable in light and dark themes;
- readable at approximately 320–390 px width and 200% zoom;
- no clipped labels;
- rendered title/description and ARIA relationships from `accTitle`/`accDescr`;
- adjacent prose carries the essential meaning without the diagram.

Also inspect representative files through GitHub's native Markdown rendering before merge or push.

### Taxonomy checks

- every non-published document satisfies its lane README;
- active plans live only under `docs/plans/`;
- research contains unresolved investigation only;
- evidence contains immutable observations, not current guidance;
- completed plans/reviews are archived;
- no active `docs/superpowers/` or other tool-branded hierarchy exists;
- `mkdocs.yml` exclusions and nav match the filesystem;
- `TESTING-CHECKLIST.md` remains prominently discoverable.

### Final adversarial review

The final reviewer must confirm:

- all approved moves and no unapproved public-path churn;
- all live links and nav entries resolve;
- Mermaid diagrams match current code and adjacent prose;
- future-agent guidance encodes the final idioms;
- no second alignment plan was introduced;
- no deployment secret is exposed to pull-request documentation builds;
- no excluded housekeeping leaked into the diff.

## Completion boundary

The remaining workflow may move and edit documentation, MkDocs configuration, documentation CI, hygiene tooling/tests, and project `CLAUDE.md` as specified above. It does not change app/package behavior. It does not commit, push, or publish implementation changes unless the user separately requests that action.
