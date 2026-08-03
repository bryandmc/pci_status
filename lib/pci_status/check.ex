defmodule PCIStatus.Check do
  @moduledoc """
  Behaviour for a single dependency check.

  A check answers one question — "can I still talk to this thing?" — and says
  so in one of three states:

    * `:up` — working
    * `:degraded` — reachable but unhealthy (queue backing up, disk filling)
    * `:down` — broken

  Return a bare atom, a `{status, message}` tuple, or `{status, message, detail}`
  where `detail` is a flat map of extra scalars shown alongside the check in
  the portal. Latency is measured by the runner; checks never report it.

      defmodule MyApp.Checks.Redis do
        @behaviour PCIStatus.Check

        @impl true
        def run(opts) do
          case Redix.command(opts[:conn], ["PING"]) do
            {:ok, "PONG"} -> :up
            {:error, reason} -> {:down, inspect(reason)}
          end
        end
      end

  A check that raises or times out is recorded as `:down` with the reason as
  its message — it can never take the reporter down with it.
  """

  @type status :: :up | :degraded | :down
  @type result ::
          status
          | {status, String.t() | nil}
          | {status, String.t() | nil, map()}

  @callback run(opts :: keyword()) :: result
end
