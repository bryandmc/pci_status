defmodule PCIStatus.PlugTest do
  # async: false — these register a process under the reporter's global name.
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias PCIStatus.Plug, as: StatusPlug

  # Stands in for the real reporter by claiming its registered name, so the plug
  # reaches this instead without needing an injection seam in production code.
  defmodule StubReporter do
    use GenServer

    def start(snapshot),
      do: GenServer.start(__MODULE__, snapshot, name: PCIStatus.Reporter)

    @impl true
    def init(snapshot), do: {:ok, snapshot}

    @impl true
    def handle_call(:last_snapshot, _from, snapshot), do: {:reply, snapshot, snapshot}
  end

  # A check that records every invocation. The point of the readiness rewrite is
  # that serving a request must never run one of these.
  def tripwire do
    Agent.update(__MODULE__.Tripwire, &(&1 + 1))
    :up
  end

  setup do
    {:ok, _} = Agent.start_link(fn -> 0 end, name: __MODULE__.Tripwire)

    Application.put_env(:pci_status, :checks, [
      {:tripwire, PCIStatus.Checks.MFA, mfa: {__MODULE__, :tripwire, []}}
    ])

    on_exit(fn -> Application.delete_env(:pci_status, :checks) end)
    :ok
  end

  defp call(path, opts \\ [], headers \\ []) do
    headers
    |> Enum.reduce(conn(:get, path), fn {k, v}, c -> put_req_header(c, k, v) end)
    |> StatusPlug.call(opts)
  end

  defp body(conn), do: Jason.decode!(conn.resp_body)
  defp checks_run, do: Agent.get(__MODULE__.Tripwire, & &1)

  defp snapshot(checks, age) do
    {:ok, pid} = StubReporter.start(%{payload: %{checks: checks}, age_seconds: age})
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    :ok
  end

  describe "/health" do
    test "is 200 and runs no checks" do
      conn = call("/")

      assert conn.status == 200
      assert body(conn)["status"] == "ok"
      assert checks_run() == 0
    end

    test "does not disclose the build version" do
      resp = body(call("/"))

      refute Map.has_key?(resp, "version")
      refute Map.has_key?(resp, "git_sha")
    end
  end

  describe "/health/ready" do
    test "reports unknown, not healthy, before anything has been collected" do
      # No reporter registered at all — last_snapshot/2 catches the exit.
      conn = call("/ready")

      assert conn.status == 503
      assert body(conn)["status"] == "unknown"
      assert checks_run() == 0
    end

    test "serves the cached snapshot without running a single check" do
      snapshot(%{"database" => %{status: "up"}}, 5)

      conn = call("/ready")

      assert conn.status == 200
      assert body(conn)["status"] == "up"
      assert body(conn)["age_seconds"] == 5
      assert checks_run() == 0
    end

    test "503s on a down dependency, still without running checks" do
      snapshot(%{"database" => %{status: "down"}, "disk" => %{status: "up"}}, 5)

      conn = call("/ready")

      assert conn.status == 503
      assert body(conn)["status"] == "down"
      assert checks_run() == 0
    end

    test "degraded is surfaced as 503" do
      snapshot(%{"oban" => %{status: "degraded"}}, 5)

      assert call("/ready").status == 503
      assert body(call("/ready"))["status"] == "degraded"
    end

    test "a snapshot older than three intervals reads as stale, not healthy" do
      # Default interval is 60s, so the floor of 120s applies at 180s.
      snapshot(%{"database" => %{status: "up"}}, 10_000)

      conn = call("/ready")

      assert conn.status == 503
      assert body(conn)["status"] == "stale"
      assert checks_run() == 0
    end
  end

  describe "/health/full" do
    test "401s without a token and collects nothing" do
      conn = call("/full")

      assert conn.status == 401
      assert checks_run() == 0
    end

    test "401s on a wrong token" do
      Application.put_env(:pci_status, :token, "correct-horse")
      on_exit(fn -> Application.delete_env(:pci_status, :token) end)

      conn = call("/full", [], [{"authorization", "Bearer wrong"}])

      assert conn.status == 401
      assert checks_run() == 0
    end
  end

  test "an unknown path 404s" do
    assert call("/nope").status == 404
  end
end
