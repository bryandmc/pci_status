defmodule PCIStatus do
  @moduledoc """
  Status reporting agent for the Pacific Coast Insights portal.

  Add `PCIStatus.Reporter` to your supervision tree and it periodically POSTs
  a full picture of the service — dependency checks, host metrics, VM
  internals, database stats and whatever domain facts you want to publish —
  to the portal's `/api/status` endpoint.

      # config/runtime.exs
      config :pci_status,
        otp_app: :my_app,
        service: "my-app",
        repo: MyApp.Repo,
        token: {:system, "PCI_STATUS_TOKEN"}

      # lib/my_app/application.ex
      children = [MyApp.Repo, MyAppWeb.Endpoint, PCIStatus.Reporter]

  With no token configured the reporter doesn't start, so this is safe to
  leave wired up in dev and test.

  See `PCIStatus.Config` for every option, `PCIStatus.Check` for writing your
  own checks, and `PCIStatus.Plug` for the matching HTTP endpoints.
  """

  @doc """
  Builds the current payload without sending it. Handy in `iex` to see exactly
  what the portal will receive.
  """
  defdelegate collect(), to: PCIStatus.Collector

  @doc "Sends a report immediately. Returns `{:ok, status_code}` or `{:error, reason}`."
  defdelegate report_now(), to: PCIStatus.Reporter

  @doc "Runs the configured checks and returns them, without reporting."
  def checks do
    PCIStatus.Checks.run_all(PCIStatus.Config.checks(), PCIStatus.Config.check_timeout())
  end

  @doc """
  Overall health as a single atom, derived from the checks: `:up`, `:degraded`
  or `:down`.
  """
  def health do
    checks = checks()

    cond do
      Enum.any?(checks, fn {_, c} -> c.status == "down" end) -> :down
      Enum.any?(checks, fn {_, c} -> c.status == "degraded" end) -> :degraded
      true -> :up
    end
  end
end
