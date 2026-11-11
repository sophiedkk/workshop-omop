# R workshops with a facilitator (Hanze)

Pure R/Shiny, container-based: a learnr tutorial per participant (ShinyProxy), a plumber api (state + answer key),
a Shiny facilitator app, Caddy for HTTPS. `README.md` has a "Where to find things" table.

- `workshops/<name>/` content (tutorial.Rmd, questions.yml, key.yml); `app/` R code; `server/` image, Caddy, login
  pages; `branding/` logos; `tests/`; `run/` generated state and secrets (gitignored).

## Development environment

- Everything runs in containers. Use `./ws` for all commands (`build`, `prepare-data`, `setup`, `up`,
  `down`, `logs`, `ps`, `test`, `e2e`). No R or Python setup on the machine itself.
- Local: Fedora host with **rootless podman** + podman-compose (`ws` starts the podman API socket that ShinyProxy
  needs). The `omop` toolbox is no longer needed; if a session does run inside it, `ws` re-runs itself on the host
  via `flatpak-spawn --host`.
- SELinux: `ws` adds `:z` to bind mounts, and ShinyProxy runs with `label=disable` (otherwise it may not use the
  podman socket: "Permission denied" in its log).
- The app is at `http://127.0.0.1:8080`; passwords in `run/handouts/`. `run/` is gitignored and holds
  all state and secrets.
- Containers ShinyProxy starts (one per participant, plus the facilitator app) are not compose services:
  see them with `./ws ps`, and debug with `podman logs <name>`.

## Gotchas

- learnr exercises use the **inline evaluator** (set in the tutorial's setup chunk): the Linux default forks,
  which is unsafe with DuckDB. DuckDB is capped (`memory_limit`, `threads`) because it otherwise sizes itself to
  the whole host, not the container limit.
- The image prerenders the tutorial; `RMARKDOWN_RUN_PRERENDER=0` stops runtime re-rendering. After changing
  `tutorial.Rmd`, `questions.yml` or R code: `./ws build`, then `./ws up`.
- `key.yml` must never enter the image (`.dockerignore`); it is mounted into the api only.
- In e2e tests with several browser sessions, call `Page$bringToFront()` before clicking learnr's Run Code:
  background pages are throttled and the run never completes.

## Local vs. VM

- The VM (clean Ubuntu, Azure) runs Docker Engine + compose plugin; setup steps in `SERVER.md`. `config.yml`
  (gitignored; from `config.example.yml`) holds participants, `address`, `http_port`/`https_port`, `tls`. Locally
  the same Caddy path can be tested with `address: 127.0.0.1`, ports above 1024 and `tls: internal`. A real
  Let's Encrypt certificate and Docker Engine cannot be tested locally. The VM is deploy-only: change things here.

## Tests

`./ws test` (api/core, testthat) and `./ws e2e` (headless Chrome through ShinyProxy; needs `./ws up` and a fresh
`./ws setup --reset`; takes several minutes because it runs every exercise).

## Commits

- **No AI attribution** in commits, PRs, issues or code: no `Co-Authored-By` trailer, no "Generated with" line.
  The use of AI is disclosed once, in the README's "Use of AI" section; keep that section true when the practice
  changes.
