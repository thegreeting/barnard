# Agent Instructions

This repository uses Spec Kit–style spec-driven development.

## Rules

- Keep documentation in **English**.
- Use the standard terminology consistently: **Scan / Advertise / Central / Peripheral / GATT / Transport**.
- Prefer schema-first: update `schema/barnard/v1` (JSON Schema) when changing public shapes.
- Do not add device-unique persistent identifiers to on-wire payload formats.
- Keep mock/simulation implementations bounded (avoid unbounded memory growth).

## Suggested workflow

1. Update `specs/` and/or `schema/` first
2. Implement in language-specific packages (e.g., `packages/dart/barnard`)
3. Add/adjust demos under `examples/`
4. Ensure CI passes (`.github/workflows/`)

