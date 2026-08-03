defmodule PCIStatus.Checks.Memory do
  @moduledoc """
  Threshold check on host memory pressure.

  Measured against *available* memory, not free — page cache is reclaimable,
  so free-memory alarms fire constantly on a healthy Linux box and teach you
  to ignore them.

  Options: `:warn_percent` (default 85), `:crit_percent` (default 95).
  """
  @behaviour PCIStatus.Check

  alias PCIStatus.System, as: Sys

  @impl true
  def run(opts) do
    warn = Keyword.get(opts, :warn_percent, 85)
    crit = Keyword.get(opts, :crit_percent, 95)

    metrics = Sys.collect()

    case metrics.memory_percent do
      nil ->
        {:degraded, "no memory data available"}

      percent ->
        message =
          "#{trunc(percent)}% used (#{metrics.memory_available_mb}MB available of #{metrics.memory_total_mb}MB)"

        cond do
          percent >= crit -> {:down, message}
          percent >= warn -> {:degraded, message}
          true -> {:up, message}
        end
    end
  end
end
