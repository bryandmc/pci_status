if Code.ensure_loaded?(Plug.Conn) do
  defmodule PCIStatus.Plug do
    @moduledoc """
    Exposes the same data the reporter pushes, over HTTP.

    Mount it in your router:

        forward "/health", PCIStatus.Plug

    which gives you three endpoints:

    | Path            | Cost | Meaning |
    |-----------------|------|---------|
    | `/health`       | free | The VM is up and serving. Always 200. |
    | `/health/ready` | free | Last known check state. 200 if all up, 503 otherwise. |
    | `/health/full`  | live | The entire status payload, as JSON. Token required. |

    The split matters. `/health` is what the portal's poller and any load
    balancer should hit — it must not touch the database, or a slow query
    turns into a cascade of instances being marked unhealthy and cycled. A
    failure at `/ready` means "stop sending me traffic", not "restart me".

    **Neither unauthenticated endpoint runs a check.** `/ready` reads the
    snapshot the reporter already collected on its own timer, so no amount of
    anonymous traffic can generate database load — the tradeoff is staleness,
    which it reports as `age_seconds`. Only `/full`, behind the bearer token,
    collects live.

    `/full` leaks infrastructure detail, so it requires the same bearer token
    the reporter uses. Pass `public: true` to open it up in dev.

        forward "/health", PCIStatus.Plug, public: Mix.env() == :dev
    """

    @behaviour Plug

    import Plug.Conn

    alias PCIStatus.{Collector, Config, Reporter}

    @impl true
    def init(opts), do: opts

    @impl true
    def call(%Plug.Conn{path_info: []} = conn, _opts), do: liveness(conn)
    def call(%Plug.Conn{path_info: ["ready"]} = conn, _opts), do: readiness(conn)
    def call(%Plug.Conn{path_info: ["full"]} = conn, opts), do: full(conn, opts)
    def call(conn, _opts), do: send_json(conn, 404, %{error: "not found"})

    # Deliberately touches nothing external.
    #
    # No version here. This endpoint is unauthenticated, and `Build.version/0`
    # carries the git SHA — which tells anyone who asks exactly which commit is
    # running, and therefore exactly which known issues apply to it. A liveness
    # probe needs the status code and nothing else; the version is still in the
    # token-gated payload for anyone entitled to it.
    defp liveness(conn) do
      send_json(conn, 200, %{status: "ok", service: Config.service()})
    end

    # Serves the reporter's last collected snapshot. It never runs a check.
    #
    # That is the whole point. This endpoint is unauthenticated, and the default
    # check set queries the database — so running checks per request lets an
    # anonymous caller generate database load and task churn at whatever rate it
    # likes. Reading cached state is O(1) and cannot be turned into a lever.
    #
    # The cost is staleness, bounded by the report interval and published as
    # `age_seconds` so a consumer can judge it.
    defp readiness(conn) do
      case Reporter.last_snapshot() do
        nil ->
          # Nothing collected yet: booting, or reporting is switched off. This
          # is not the same as healthy, and answering 200 would let a genuinely
          # broken app read as ready for its entire life.
          send_json(conn, 503, %{
            status: "unknown",
            reason: "no snapshot collected yet"
          })

        %{payload: payload, age_seconds: age} ->
          checks = Map.get(payload, :checks) || %{}
          {status_code, overall} = summarize(checks, age)

          send_json(conn, status_code, %{
            status: overall,
            age_seconds: age,
            checks: checks
          })
      end
    end

    # Stale is deliberately distinct from down: down means a check failed,
    # stale means the reporter stopped collecting and we no longer know. Mirrors
    # the portal's own rule — three intervals, floor of two minutes — so both
    # ends call an app stale at the same moment.
    defp summarize(checks, age) do
      cond do
        age > stale_after() -> {503, "stale"}
        any_status?(checks, "down") -> {503, "down"}
        any_status?(checks, "degraded") -> {503, "degraded"}
        true -> {200, "up"}
      end
    end

    defp any_status?(checks, status) do
      Enum.any?(checks, fn {_name, check} -> Map.get(check, :status) == status end)
    end

    defp stale_after, do: max(div(Config.interval(), 1000) * 3, 120)

    defp full(conn, opts) do
      if Keyword.get(opts, :public, false) or authorized?(conn) do
        send_json(conn, 200, Collector.collect())
      else
        send_json(conn, 401, %{error: "unauthorized"})
      end
    end

    defp authorized?(conn) do
      with [header] <- get_req_header(conn, "authorization"),
           "Bearer " <> presented <- String.trim(header),
           token when is_binary(token) <- Config.token() do
        Plug.Crypto.secure_compare(presented, token)
      else
        _ -> false
      end
    end

    defp send_json(conn, status, body) do
      conn
      |> put_resp_content_type("application/json")
      |> put_resp_header("cache-control", "no-store")
      |> send_resp(status, Jason.encode_to_iodata!(body))
      |> halt()
    end
  end
end
