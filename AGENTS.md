<!-- second-brain-repository-bootstrap:v1 -->

# Repository Agent Guide

This file owns the project's instructions for maintainers, contributors and coding
agents. It must be usable without a maintainer's private repositories, personal
accounts or machine paths. Personal agent configuration may supplement this guide
in its owner's environment; it does not replace project policy or grant access.

## Task-Start Synchronization

Before repository inspection, planning or edits:

1. Run `.codex/bin/repository-preflight` from inside this repository. It uses
   Git only, fetching and fast-forwarding a clean checkout's tracking branch.
2. Preserve dirty, detached, untracked or diverged work. Never reset, clean,
   force, auto-stash or overwrite work to make the preflight pass. Use a clean
   checkout based on the freshly fetched primary branch when appropriate.
3. Read this current guide and the project's contribution/release instructions.
   If working on a feature/release branch, update primary in its clean worktree
   first and follow the project's policy for incorporating it. The preflight
   checks the current branch; it does not prove that primary is incorporated.

## Project Instructions

Maintain the project's purpose, setup, architecture, validation commands,
contribution/review/branch policy, release/deployment authorization, privacy and
source-of-truth rules here or in linked project-owned guides. Document supported
contributor setup and privileged maintainer roles separately. Keep personal reply
preferences, private context and maintainer-specific credential tooling outside
this shared contract. Do not assume direct-to-primary delivery for a shared
project; follow its actual workflow.

This fork tracks experiments in its own GitHub Issues. Base upstream contributions
on the current upstream default branch and keep fork setup and private test data
out of upstream changes. Consult the README for the app and helper build
instructions, SECURITY.md for security reporting, and .github/workflows/ci.yml
for validation.

Run Swift formatting checks and the unsigned macOS build and tests from CI
before publishing changes. Use only synthetic data with unsigned debug builds.
Validate a real Messages send separately with a signed build and an approved
test conversation. The fork does not ship a production release.
