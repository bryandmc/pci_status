# pci_status

Liveness, health and deep-diagnostic reporting agent for the
[Pacific Coast Insights](https://pacific-coast-insights.com) portal.

Drop it into any Elixir app, give it a token, and the portal gets a complete
picture of that service every minute: dependency checks, host metrics, VM
internals, database stats, and whatever domain facts the app wants to publish.

## Install

```elixir
# mix.exs
{:pci_status, github: "bryandmc/pci_status"}
```

## Configure

```elixir
# config/runtime.exs
config :pci_status,
  otp_app: :my_app,
  service: "my-app",
  repo: MyApp.Repo,
  token: {:system, "PCI_STATUS_TOKEN"},
  url: "https://pacific-coast-insights.com/api/status",
  interval: :timer.seconds(60)
```

```elixir
# lib/my_app/application.ex — after the repo and endpoint, so the first
# report describes a fully-booted app
children = [MyApp.Repo, MyAppWeb.Endpoint, PCIStatus.Reporter]
```

Get the token from the app's detail panel in the portal (`/portal/projects/:id`
→ the app → **API Token**).

**Without a token the reporter doesn't start.** That's deliberate: it's safe to
leave wired up in dev and test, and an app that hasn't been provisioned in the
portal yet simply stays quiet.

Every option accepts `{:system, "VAR"}` or `{:system, "VAR", default}`, resolved
at call time — rotating a token in a running release takes effect on the next
report, with no restart.

| Option | Default | |
|---|---|---|
| `:url` | the production portal | Ingest endpoint |
| `:token` | `nil` | Bearer token. `nil` disables reporting |
| `:interval` | 60s | Between reports. Also sent to the portal, which uses it to decide when this app has gone stale |
| `:timeout` | 10s | HTTP timeout for one report |
| `:check_timeout` | 5s | Per-check timeout |
| `:otp_app` | — | Host app, for the version string |
| `:service` | `:otp_app` | Display name |
| `:environment` | `Mix.env()` | Or `PCI_STATUS_ENV` |
| `:repo` | `nil` | Ecto repo to introspect. Enables the database + Oban checks |
| `:disk_mount` | `"/"` | Filesystem reported as `disk_percent` |
| `:checks` | derived | See below |
| `:extra` | `nil` | `{m, f, a}` returning a flat map of your own facts |
| `:enabled` | `true` | Master switch |

## HTTP endpoints

```elixir
# router.ex
forward "/health", PCIStatus.Plug
```

| Path | Cost | Meaning |
|---|---|---|
| `/health` | free | The VM is up and serving. Always 200 |
| `/health/ready` | cheap | Runs the checks. 200 if all up, 503 otherwise |
| `/health/full` | full | The entire payload as JSON. Requires the bearer token |

The split is load-bearing. `/health` is what the portal's poller and any load
balancer should hit, and it must not touch the database — otherwise one slow
query marks every instance unhealthy and cycles the fleet. Dependency checking
belongs behind `/ready`, where a failure means "stop sending me traffic", not
"restart me".

## Checks

With a `:repo` configured you get `database`, `oban`, `disk` and `memory` for
free. Override the list to add your own:

```elixir
config :pci_status,
  checks: [
    {:database, PCIStatus.Checks.Repo, repo: MyApp.Repo},
    {:oban, PCIStatus.Checks.Oban, repo: MyApp.Repo, max_available: 500},
    {:osrm, PCIStatus.Checks.HTTP, url: "http://localhost:5001/health", degrade_on_slow_ms: 500},
    {:disk, PCIStatus.Checks.Disk, mount: "/var/lib/postgresql", crit_percent: 85},
    {:memory, PCIStatus.Checks.Memory, []},
    {:sync_lock, PCIStatus.Checks.Process, name: MyApp.SyncLock},
    {:shopify, {MyApp.Shopify, :ping, []}}
  ]
```

Built-ins: `Repo`, `HTTP`, `Oban`, `Disk`, `Memory`, `Process`, `MFA`.
Write your own by implementing `PCIStatus.Check` — return `:up`, `:degraded`,
`:down`, or a `{status, message}` / `{status, message, detail}` tuple.

Checks run concurrently, each with its own timeout. A check that hangs, raises
or exits is recorded as `down` with the reason as its message; it can't stall
the report or hide the other checks' results.

## Publishing your own facts

```elixir
config :pci_status, extra: {MyApp.Status, :extra, []}

defmodule MyApp.Status do
  def extra do
    %{
      orders_today: MyApp.Orders.count_today(),
      drivers_on_shift: MyApp.Drivers.on_shift_count(),
      shopify: %{configured: MyApp.Shopify.configured?(), last_sync_at: MyApp.Shopify.last_sync_at()}
    }
  end
end
```

Nested maps are flattened to dotted keys (`shopify.configured`) and nils are
dropped, because the portal renders this section as a flat key/value grid. A
callback that raises is logged and skipped — it never fails the report.

## Build provenance

The portal announces a deploy when the reported `version` changes, so it needs
to move when the code does. Inside a release there's no `.git` and no Mix, so
inject it at build time:

```dockerfile
ARG GIT_SHA
ENV GIT_SHA=${GIT_SHA}
```

```bash
docker build --build-arg GIT_SHA=$(git rev-parse --short HEAD) .
```

Also read, if set: `GIT_BRANCH`, `BUILT_AT`, `DEPLOYED_AT`, `RELEASE_NAME`,
`RELEASE_VSN`. Without any of them you still get the OTP application version.

## Operating it

```elixir
PCIStatus.collect()      # the exact payload, without sending it
PCIStatus.checks()       # just the checks
PCIStatus.health()       # :up | :degraded | :down
PCIStatus.report_now()   # send immediately; {:ok, 201} or {:error, reason}
PCIStatus.Reporter.last_result()
```

The reporter is built so it can never become the outage:

- Collection and delivery run in a task with a hard timeout — a wedged socket
  can't block the next tick or leak a process per interval.
- Failures back off exponentially to 5 minutes, so an unreachable portal
  doesn't turn into a request flood.
- Intervals are jittered ±10%, so a fleet restarted together doesn't settle
  into a synchronised thundering herd.
- A 401 logs once at error and keeps the steady heartbeat — a wrong token is a
  config bug, and backing off just delays recovery once it's fixed.

Telemetry: `[:pci_status, :report, :stop]` with `%{duration_ms:}` and
`%{status: :ok | :error, result:}`.

## Notes

`:os_mon` is started for you (it's in this library's `extra_applications`).
It raises `disk_almost_full` and `system_memory_high_watermark` SASL alarms at
its own thresholds, independent of this library's disk/memory checks; tune via
`config :os_mon, disk_almost_full_threshold: 0.9` if the log noise bothers you.
