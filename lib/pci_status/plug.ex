if Code.ensure_loaded?(Plug.Conn) do
  defmodule PCIStatus.Plug do
    @moduledoc """
    Exposes the same data the reporter pushes, over HTTP.

    Mount it in your router:

        forward "/health", PCIStatus.Plug

    which gives you three endpoints:

    | Path            | Cost  | Meaning |
    |-----------------|-------|---------|
    | `/health`       | free  | The VM is up and serving. Always 200. |
    | `/health/ready`  | cheap | Runs the checks. 200 if all up, 503 otherwise. |
    | `/health/full`  | full  | The entire status payload, as JSON. |

    The split matters. `/health` is what the portal's poller and any load
    balancer should hit — it must not touch the database, or a slow query
    turns into a cascade of instances being marked unhealthy and cycled. Put
    dependency checking behind `/ready`, where a failure means "stop sending
    me traffic", not "restart me".

    `/full` leaks infrastructure detail, so it requires the same bearer token
    the reporter uses. Pass `public: true` to open it up in dev.

        forward "/health", PCIStatus.Plug, public: Mix.env() == :dev
    """

    @behaviour Plug

    import Plug.Conn

    alias PCIStatus.{Build, Checks, Collector, Config}

    @impl true
    def init(opts), do: opts

    @impl true
    def call(%Plug.Conn{path_info: []} = conn, _opts), do: liveness(conn)
    def call(%Plug.Conn{path_info: ["ready"]} = conn, _opts), do: readiness(conn)
    def call(%Plug.Conn{path_info: ["full"]} = conn, opts), do: full(conn, opts)
    def call(conn, _opts), do: send_json(conn, 404, %{error: "not found"})

    # Deliberately touches nothing external.
    defp liveness(conn) do
      send_json(conn, 200, %{
        status: "ok",
        service: Config.service(),
        version: Build.version()
      })
    end

    defp readiness(conn) do
      checks = Checks.run_all(Config.checks(), Config.check_timeout())

      {status_code, overall} =
        cond do
          Enum.any?(checks, fn {_, c} -> c.status == "down" end) -> {503, "down"}
          Enum.any?(checks, fn {_, c} -> c.status == "degraded" end) -> {503, "degraded"}
          true -> {200, "up"}
        end

      send_json(conn, status_code, %{status: overall, checks: checks})
    end

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
