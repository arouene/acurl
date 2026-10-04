# Project agent memory

This file is the project's committed home for project-intrinsic agent knowledge: build, test, release, architecture, and sharp-edge notes that should travel with the code.

- `make` is the gate (byte-compile with warnings as errors, checkdoc, ERT); see `Makefile`. Tests need `curl` and `python3`: integration tests spawn `test/server.py`.
- Resume relies on curl behavior verified empirically: with `--continue-at -`, a 200 reply exits 33 before writing, a 416 exits 0 with the body discarded, and `--fail` still writes full headers to `--dump-header` without writing the error body. Recheck these if raising the minimum curl version or changing download flags in `acurl--build-args`.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
