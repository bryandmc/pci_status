defmodule PCIStatus.Checks.Disk do
  @moduledoc """
  Threshold check on filesystem usage.

  A full disk takes down Postgres, log rotation and the release itself, so it
  is worth an explicit check rather than leaving it as a gauge nobody reads.

  Options: `:mount` (default `"/"`), `:warn_percent` (default 80),
  `:crit_percent` (default 90).
  """
  @behaviour PCIStatus.Check

  alias PCIStatus.System, as: Sys

  @impl true
  def run(opts) do
    mount = Keyword.get(opts, :mount, "/")
    warn = Keyword.get(opts, :warn_percent, 80)
    crit = Keyword.get(opts, :crit_percent, 90)

    case Sys.disk(mount) do
      %{disk_percent: nil} ->
        {:degraded, "no disk data for #{mount}"}

      %{disk_percent: percent, disk_free_gb: free, disk_mount: path} ->
        message = "#{trunc(percent)}% used on #{path} (#{free}GB free)"

        cond do
          percent >= crit -> {:down, message}
          percent >= warn -> {:degraded, message}
          true -> {:up, message}
        end
    end
  end
end
