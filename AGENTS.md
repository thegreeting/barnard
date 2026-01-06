# Agent Instructions

This repository uses Spec Kit–style spec-driven development.

## GitHub MCP automation (PR + CI)

When the user asks to create a PR and verify CI, prefer GitHub MCP operations over local `git`, `gh` commands.

Repository defaults:

- Repo: `thegreeting/barnard`
- Base branch: `main`

Recommended flow:

1. Create a branch from the base branch (e.g., `feature/<topic>`).
2. Push changes via GitHub MCP file operations (single commit is fine for small changes).
3. Create a PR targeting the base branch.
4. Verify CI is green:
   - Poll the PR head commit status/checks until all required checks succeed.
   - If checks fail, fix the underlying issue, push an updated commit, and re-check.
5. Keep the PR description aligned with the spec:
   - Link to the relevant spec and schema changes.
   - Call out compatibility, security/privacy notes (especially “no device-unique persistent identifiers on-wire”).

Notes:

- Do not assume CI is green without checking the PR’s head commit status/checks.
- If the repo uses required checks, treat “neutral”/“skipped” as non-success unless explicitly documented as acceptable.
- When opening a PR, always link the related issues in the PR description:
  - Use `Closes #<issue>` for the primary issue/epic when appropriate.
  - Use `Refs #<issue>` for supporting/sub-issues.

## Rules

- Keep documentation in **English**.
- Use the standard terminology consistently: **Scan / Advertise / Central / Peripheral / GATT / Transport**.
- Prefer schema-first: update `schema/barnard/v1` (JSON Schema) when changing public shapes.
- Do not add device-unique persistent identifiers to on-wire payload formats.
- Keep mock/simulation implementations bounded (avoid unbounded memory growth).

## Git Commit Messages

Use **Conventional Commits** for PR-ready changes.

Format:

`<type>(<scope>): <summary>`

Where:
- `type`: `feat | fix | refactor | docs | test | chore | ci`
- `scope` (optional): short area label like `flutter`, `android`, `ios`, `schema`, `spec`
- `summary`: imperative, present tense, no trailing period

Examples:
- `feat(flutter): add GATT-first BLE transport + PoC app`
- `fix(android): handle missing BLUETOOTH_CONNECT permission`
- `docs(spec): clarify RPID delivery via GATT`

## Spec Kit workflow (detailed)

Treat `specs/` and `schema/` as the source of truth. Implementation follows the spec, not the other way around.

### 0) Clarify scope

- Identify the change type: bug fix, new feature, refactor, or behavior change.
- Identify impacted surfaces: on-wire payloads, public APIs, examples, CI, docs.
- Confirm constraints early (e.g., no persistent device identifiers on-wire).

### 1) Write/update the spec (`specs/`)

Create or update a spec document that makes the change reviewable without reading code.

Minimum contents to include:

- **Problem statement**: what is wrong/missing today, and why it matters.
- **Goals / Non-goals**: keep them crisp; avoid scope creep.
- **Glossary**: define terms and use the standard terminology (Scan/Advertise/Central/Peripheral/GATT/Transport).
- **Behavior**: describe expected behavior as observable events and state changes.
  - Prefer simple state machines and sequence diagrams (text form is fine).
  - Specify error cases and retry behavior (including timeouts/backoff if relevant).
- **Compatibility**: what must remain backward compatible and what can change.
- **Security & privacy**: explicitly confirm the on-wire payload does not carry device-unique persistent identifiers.
- **Examples**: include at least one concrete end-to-end example message/flow (human-readable).

### 2) Update schemas first (`schema/barnard/v1`)

If the change affects any public shapes (messages, config files, exported JSON, etc.), update JSON Schema before code.

Guidelines:

- Keep schemas strict enough to prevent ambiguous payloads.
- Prefer additive changes (new optional fields) over breaking changes.
- If a breaking change is unavoidable, introduce a new versioned schema directory (e.g., `schema/barnard/v2`) and keep the old version intact.
- Add/update schema examples where the repository pattern supports it.

### 3) Implement in packages (`packages/…`)

- Implement exactly what the spec describes; if the code suggests the spec is incomplete, go back and update the spec first.
- Keep boundaries clear:
  - Transport-specific logic stays in Transport modules.
  - GATT-specific behavior stays close to the Peripheral/Central interaction layer.
- Prefer small, composable modules that can be unit-tested without hardware.

### 4) Keep mocks/simulations bounded

For mock Central/Peripheral or simulated Scan/Advertise behavior:

- Avoid unbounded memory growth (use caps, TTLs, ring buffers, or eviction strategies).
- Make determinism easy: allow fixed seeds or scripted scenarios when feasible.

### 5) Update demos (`examples/`)

- Ensure examples reflect the spec (happy path + at least one failure mode if relevant).
- Keep examples runnable and minimal; prefer showcasing the protocol and shapes over app scaffolding.

### 6) Tests and validation

Add or update tests proportional to the change:

- Schema validation tests (if present in the repo conventions).
- Unit tests for parsing/serialization and edge cases.
- Integration-style tests for end-to-end flows where feasible (including mock Transport).

### 7) CI readiness (`.github/workflows/`)

- Ensure CI passes with the updated spec, schema, packages, and examples.
- If CI gaps are discovered (missing checks, missing schema validation), document them in the spec or as a follow-up task rather than silently ignoring them.

## Definition of done (quick checklist)

- Spec updated and readable without code.
- Schema updated first (or explicitly “no public shape changes”).
- Implementation matches spec; no extra behavior.
- No device-unique persistent identifiers on-wire.
- Mocks/simulations remain bounded.
- Examples updated and runnable.
- Tests updated; CI passes.

## GitHub Projects (optional)

If GitHub Projects tooling is available via MCP, also update the relevant Project item when you open/update a PR.

Defaults:

- Project: “Projects/Beid Barnard Project” (id: `4`)

Guidance:

- Link the PR (and/or issue) to the Project item.
- Update the Project item’s status/fields according to the team’s conventions (do not guess field names; query them first).
- Keep Project automation bounded (no mass-editing unrelated items).

## Suggested workflow (short)

1. Update `specs/` and/or `schema/` first
2. Implement in language-specific packages (e.g., `packages/dart/barnard`)
3. Add/adjust demos under `examples/`
4. Ensure CI passes (`.github/workflows/`)
