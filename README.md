# volvo
Volvo cloud tooling in Go: `volvo-ctl`, a CLI that also feeds a Waybar pill, and `volvo-exporter`, a Prometheus exporter that runs in Kubernetes and is the one holder of the rotating refresh token. Split out of [waybar-modules](https://github.com/polarn/waybar-modules) in October 2026; see [AGENTS.md](AGENTS.md) for the conventions and the details that are easy to get wrong.

`make` builds `volvo-ctl` into `build/`; `make install` copies it to `~/.local/bin`. `volvo-exporter` is built into `ghcr.io/polarn/volvo-exporter` by `.github/workflows/build.yml` on every push to `main` that touches it, or locally with `go build ./cmd/volvo-exporter`.

## volvo-ctl
A CLI for Volvo's cloud API (Energy API v2) that reports an EV's battery/charging state. `volvo-ctl waybar` emits one JSON line for a Waybar custom module (run it with `"interval"`, not as a daemon). With `VOLVO_EXPORTER_URL` set, `status`, `location` and `waybar` read volvo-exporter's `/state` instead of calling the API, so the desktop never competes for the refresh token.

Needs an application from [developer.volvocars.com](https://developer.volvocars.com) published with the scopes listed in `pkg/volvo/config.go` (`openid`, the `conve:*` read scopes for doors/windows/engine/odometer/tyres/warnings/diagnostics/trip statistics, `energy:state:read`, `energy:capability:read`, `location:read` — everything read-only, no `conve:commands`). Simplest is to tick every scope except commands when publishing. Scopes are **fixed at publication**: widening them means creating a new app, swapping all three credentials, and re-running `volvo-ctl auth` — the API answers 403 for unconsented endpoints, which volvo-ctl degrades from rather than erroring. The portal refuses localhost redirect URIs, so register a public forwarding page instead. The one this app uses is served from the waybar-modules repo's GitHub Pages: `https://polarn.github.io/waybar-modules/volvo-callback/` (source in [`docs/volvo-callback/`](https://github.com/polarn/waybar-modules/tree/main/docs/volvo-callback) there — it forwards the OAuth callback, query string intact, to `http://localhost:20999/callback` where `volvo-ctl auth` is listening; host a copy anywhere if you don't want to trust mine). Put the credentials in `~/.config/volvo/config.json`:

```json
    {"client_id": "...", "client_secret": "...", "vcc_api_key": "...",
     "redirect_uri": "https://polarn.github.io/waybar-modules/volvo-callback/", "vin": "..."}
```

`redirect_uri` must match the portal registration character-for-character. Omit it only for apps registered back when localhost redirect URIs were allowed.

Then run `volvo-ctl auth` (opens a browser for the Volvo ID login; tokens are kept fresh automatically in `~/.config/volvo/tokens.json`). Personal Volvo apps have a limited consent grant, so expect to re-run `auth` periodically — the waybar output switches to a `reauth` class when that happens. See `volvo-ctl help` for the other subcommands (`vehicles`, `status`, `location` — the latter prints the car's last GPS fix with OpenStreetMap/Google Maps links, and `--open` jumps straight to OSM in the browser; the waybar tooltip shows the same fix as a "Last seen" line when the scope is granted). `volvo-ctl climate <start|stop>` remotely starts/stops pre-climatization — the tool's only car-actuating command (scope `conve:climatization_start_stop`; everything else is read-only by design).

## volvo-exporter
A long-running companion that polls the Volvo API as the sole holder of the refresh token and serves what it gets, for Prometheus and for the pill.

It exists because Volvo rotates the refresh token on every refresh and access tokens last five minutes: two processes refreshing from copies of the same `tokens.json` race, the loser gets `invalid_grant`, and the whole chain needs a browser login again. One holder in the cluster, everything else reading `/state`, is the only arrangement that stays logged in.

| Endpoint | Port | For |
|---|---|---|
| `/metrics` | `$VOLVO_METRICS_ADDR`, default `:9090` | Prometheus text, `volvo_*` families |
| `/state` | `$VOLVO_HTTP_ADDR`, default `:8080` | the latest snapshot as JSON, for `volvo-ctl waybar` |
| `/healthz` | `$VOLVO_HTTP_ADDR` | process liveness |
| `/auth`, `/callback` | `127.0.0.1:20999` | the browser login, reachable only through `kubectl port-forward` |

Config is environment-only (`VOLVO_CONFIG_JSON` holds the contents of `~/.config/volvo/config.json`), suited to a Kubernetes `envFrom: secretRef`; tokens live on a PVC under `$VOLVO_DATA_DIR`. A full poll is 10 requests every 5 minutes; while the car is awake (a doors, windows or engine report under 10 minutes old) those three leaves are re-read every minute, which costs nothing while it sleeps. `volvo_auth_ok` drops to 0 when the refresh token is rejected; log back in with `kubectl -n volvo-exporter port-forward deploy/volvo-exporter 20999` and `http://localhost:20999/auth`.

Location is in `/state` for the pill but deliberately not exported to Prometheus.
