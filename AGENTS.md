# AGENTS.md

Generic engineering conventions for any agent working on this project. These rules are not tied to a particular developer machine, shell, or workspace setup, so they are safe to share with anyone using OMLibraryTesting.jl.

## Code References

Always use full absolute file paths when referencing files in answers, comments, and notes, never relative paths. Include the line number with a colon (for example `src/runner.jl:42` is wrong; the absolute form `/abs/path/to/src/runner.jl:42` is correct).

## Hard Rule: No Unverified Claims

Never speculate about why something happened without checking the evidence first. If log files exist, read them. If data is available, look at it. Do not fabricate plausible-sounding explanations. Say "I do not know yet, let me check" instead of guessing. This applies especially to:

- Why a compiler pass produced unexpected results (check the log files).
- Why a test failed or succeeded (check the actual output).
- Why performance changed (check the actual metrics).

## Code Search Policy

Prefer semantic code search over `grep` / `glob` chains when investigating where something is defined or implemented in the codebase. Semantic search returns better results faster than multi-step text matching. Fall back to `grep` / `glob` only when:

1. Semantic search is unavailable, or
2. Semantic search returned zero results for the query.

## Engineering Principles

- Never use workarounds or hacks. If the proper solution requires more steps, take them.
- Always read and understand existing code before modifying it. Follow existing patterns and conventions.
- Prefer minimal, targeted changes over broad rewrites.
- If unsure about the right approach, explain the options and ask before implementing.
- Examine plans from as many angles as possible before starting. A plan that looks complete from one angle (for example data layout) may be fatally flawed from another (for example no fast inference path). Surface all such issues upfront rather than discovering them after a build cycle.

## Code Quality Practices

- Always read a file fully before editing to understand context and existing patterns.
- Before adding new code, search the codebase to see how similar things are already done.
- Make small incremental changes and verify they work, rather than large sweeping changes.
- If requirements are unclear, ask clarifying questions rather than assuming.
- When debugging, read error messages carefully rather than guessing at fixes.
- Search for files rather than guessing paths.
- Before removing guards or flags, understand WHY they exist. Fixing one case by removing a guard often breaks many others.

## Test Suite Strategy

When fixing a failing test suite, work in foundational-first order:

1. Fix foundational tests first (sanity tests that verify core functionality).
2. Fix feature tests next (tests for specific features that build on the core).
3. Fix complex / integration tests last (tests involving multiple subsystems or runtime behavior).
