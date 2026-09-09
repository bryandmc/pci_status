if Code.ensure_loaded?(Plug.Conn) do
  defmodule PCIStatus.Plug do
    @moduledoc """
    Exposes the same data the reporter pushes, over HTTP.

    Mount it in your router:

        forward "/health", PCIStatus.Plug

    which gives you two endpoints:

    | Path           | Cost | Meaning |
    |----------------|------|---------|
    | `/health`      | free | The VM is up and serving. Always 200. |
    | `/health/full` | live | The entire status payload, as JSON. Token required. |

    `/health` is what the portal's poller and any load balancer should hit — it
    must not touch the database, or a slow query turns into a cascade of
    instances being marked unhealthy and cycled. It answers a status code and
    the service name, and nothing else.

    `/full` leaks infrastructure detail, so it requires the same bearer token
    the reporter uses. Pass `public: true` to open it up in dev.

    ## There used to be a `/health/ready`

    It served the reporter's cached snapshot: 200 if every check was up, 503
    otherwise, with `age_seconds` and the whole `checks` map.

    That map was the problem. `PCIStatus.Checks.normalize/1` merges each
    check's `detail` into its entry, so an endpoint with no token in front of
    it answered with whatever the host's checks happened to carry — free disk
    and free RAM from the built-in ones, and in one consuming app the mail
    sender address, the count of bouncing customer addresses, how much money
    was stuck unrefunded, and how long ago the last payment landed. Which is to
    say: a readiness probe that told anyone who asked how the business was
    doing.

    Trimming it to a bare status would have been the other way out, and is the
    right shape if a probe is ever wanted again — status code only, no body
    worth reading. It is removed rather than trimmed because nothing was
    polling it: the portal polls `/health` and collects through the reporter,
    and no deployment here runs a load balancer that asks for readiness. An
    endpoint nobody calls is not worth the care it needs to stay safe.

        forward "/health", PCIStatus.Plug, public: Mix.env() == :dev
    """

    @behaviour Plug

    import Plug.Conn

    alias PCIStatus.{Collector, Config}

    @impl true
    def init(opts), do: opts

    @impl true
    def call(%Plug.Conn{path_info: []} = conn, _opts), do: liveness(conn)
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
