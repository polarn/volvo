# Agents Guide for volvo

## Project overview

Volvo cloud tooling in Go, split out of `polarn/waybar-modules` in October 2026 with its history. Two programs of different shapes:

| Program | Shape | What it does |
|---|---|---|
| `cmd/volvo-ctl` | CLI, one-shot | `auth`/`vehicles`/`status`/`location`/`climate`/`waybar`. The `waybar` subcommand prints a single pill line; waybar runs it with `"interval"`, not as a daemon. With `VOLVO_EXPORTER_URL` set, `status`/`location`/`waybar` read volvo-exporter's `/state` instead of the API. |
| `cmd/volvo-exporter` | Service | Polls the Volvo API every 5 min (doors, windows and engine every minute while the car is awake) as the sole holder of the refresh token; serves Prometheus metrics, `/state` for the pill, and a loopback-only login. Deployed to Kubernetes via the flux `volvo-exporter` app. |

Packages:

- `pkg/volvo/` - Volvo cloud client: OAuth with PKCE + rotating refresh token, Energy/Connected Vehicle/Location APIs
- `pkg/waybar/` - The `Waybar` struct with JSON output and `Print()`. A copy of the one in waybar-modules (30 lines); copying it beat a cross-module dependency on `@latest` that lags behind the proxy.

**The OAuth redirect page is not here.** `https://polarn.github.io/waybar-modules/volvo-callback/` is the registered redirect URI of the published Volvo app, fixed at publication, and is served from `docs/volvo-callback/` in `polarn/waybar-modules`. That is why that repo keeps its name and that directory; moving the page means publishing a new Volvo app.

## Where it is wired up

- chezmoi (`~/.local/share/chezmoi`): `dot_config/waybar/modules/volvo.jsonc` runs `volvo-ctl waybar`; `run_onchange_install-waybar-modules.sh` has the `go install github.com/polarn/volvo/cmd/volvo-ctl@latest` line; pill colours are in `dot_config/waybar/style.css` keyed `#custom-volvo.<class>`.
- The `Dockerfile` here builds the exporter. `.github/workflows/build.yml` pushes `ghcr.io/polarn/volvo-exporter:<sha>` (and `:latest`) on every push to `main` that touches the exporter, `pkg/`, the module files or the Dockerfile, and prints the digest in the run summary; a PR builds without pushing. Shipping a change means merging it and re-pinning that digest in `polarn/flux` (`apps/microk8s/volvo-exporter`), which is a deploy. The image runs as 65532 to satisfy the manifests' `runAsNonRoot`; the token file lives on the PVC at `/data`, not in the image.

## Building

- `make build` compiles `volvo-ctl` to `./build/`; `make install` copies it to `~/.local/bin/`.
- `volvo-exporter` is deliberately not in `make build`: it is a server and belongs in the container image, not `~/.local/bin`. Build it locally with `go build ./cmd/volvo-exporter`.

## Conventions

- **No external dependencies**: `go.mod` has none, and that is deliberate. The Prometheus exposition format in `cmd/volvo-exporter` is hand-rolled rather than pulling in client_golang.
- Flags use the standard `flag` package. `volvo-ctl` dispatches on `os.Args[1]` with a `flag.NewFlagSet` per subcommand.
- The `waybar` subcommand must **always exit 0 and print exactly one JSON line**, even on failure — a bad exit or stray output blanks or breaks the pill. Errors go to stderr (waybar forwards them to the journal) and surface as a pill `class` instead.
- Long-lived credentials live under `~/.config/volvo/`, mode 0600, and are never committed.
- A metric or a field is emitted only when the upstream actually reported it. Never publish a zero for an absent value.

## volvo-exporter details

### One token holder

Volvo rotates the refresh token on every refresh (single-use) and access tokens last 5 minutes, so every poll refreshes. Two processes holding copies of `tokens.json` will race: whichever refreshes second gets `invalid_grant` and the chain needs a browser login. The `TokenStore` flock only serialises processes that share one file. So the exporter owns the token on its PVC, the pill reads `/state`, and the Deployment uses `strategy: Recreate` so two pods never overlap. Never seed the pod from a *copy* of a live `~/.config/volvo/tokens.json`; log in through the exporter instead. A local test run is safe only with `VOLVO_DATA_DIR=~/.config/volvo` (the same file, the same lock).

Shutdown waits up to 25 s for an in-flight poll rather than cancelling it: a refresh the server has accepted but the process never saved spends the token.

### Login

`/auth` and `/callback` listen on `127.0.0.1:20999` inside the pod, so they are reachable only through `kubectl port-forward`, which matches the hardcoded target of the `docs/volvo-callback` forwarding page in waybar-modules. Run `kubectl -n volvo-exporter port-forward deploy/volvo-exporter 20999`, open `http://localhost:20999/auth`, and log in; the callback saves the tokens and triggers an immediate poll. `volvo_auth_ok` goes to 0 when the refresh token is rejected, and the poller keeps re-reading `tokens.json` at the normal interval. It logs the login hint once, not on every poll, and words it for `/auth` rather than the `volvo-ctl auth` that `pkg/volvo`'s errors suggest.

### Polling and quota

Each poll is 10 requests (energy, location, 8 Connected Vehicle leaves): 2,880/day at the 5 min default, against the app's 10,000/day and 100/min. Only the energy read is required; the other parts are best-effort and counted in `volvo_partial_errors_total`. A 429 (`RateLimitError`, including from the token endpoint, which must not be read as a lapsed grant) or other failure doubles the wait up to 1 h, or longer if `Retry-After` says so.

Between full polls, while any doors, windows or engine-status field carries a car timestamp under 10 min old, the exporter re-reads those three leaves every `VOLVO_FAST_INTERVAL` (1 min) and swaps them into a copy of the snapshot. A field's `timestamp` is when the car last *reported* the leaf, shared by every field in it, not when that field changed: the car re-sends unchanged state for a few minutes after a drive and then goes quiet. So a parked, sleeping car costs nothing extra, and the worst case (always awake) is 12 more requests per 5 min, 6,336/day in total. Any fast-poll error turns fast polling off until the next good full poll, which owns the backoff. `volvo_fast_polls_total` counts them and `volvo_reported_timestamp_seconds{leaf}` exports the report times.

### Metrics

Hand-rolled text, base units (distances in `_meters`; promtool rejects `_kilometers`), and a metric only when the API reported the field (`chargingPower` is `PROPERTY_NOT_FOUND` when idle). Validate changes with `podman run --rm -i --entrypoint promtool docker.io/prom/prometheus:latest check metrics < metrics.txt`. Location is in `/state` for the pill but deliberately not exported to Prometheus.

**Never name a label `job`** — or `instance`, `pod`, `namespace`, `container`, `endpoint`, `service`. The kube-prometheus-stack scrape attaches its own, and Prometheus silently renames the colliding one to `exported_<name>`.
