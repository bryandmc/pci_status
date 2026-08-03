defmodule PCIStatus.System do
  @moduledoc """
  Host-level metrics, gathered from `:os_mon` with `/proc` as a fallback.

  Every field is best-effort: any probe that isn't available on the running
  platform yields `nil` rather than raising, so a report never fails because
  of a missing metric. The four keys the portal charts — `cpu_percent`,
  `memory_percent`, `disk_percent`, `uptime_seconds` — are always present,
  even if null.
  """

  @doc """
  Collects host metrics for the given mount point.

  `cpu_percent` is CPU utilisation *since the previous call* to this function,
  which is why the reporter primes it once at boot: the very first reading of
  `:cpu_sup.util/0` covers the whole time since `:os_mon` started and would
  otherwise report a misleadingly flat number.
  """
  def collect(mount \\ "/") do
    mem = memory_data()

    %{
      cpu_percent: cpu_percent(),
      memory_percent: memory_percent(mem),
      disk_percent: nil,
      uptime_seconds: uptime_seconds()
    }
    |> Map.merge(load_averages())
    |> Map.merge(memory_detail(mem))
    |> Map.merge(disk(mount))
    |> Map.merge(host_facts())
  end

  # --- CPU ---

  defp cpu_percent do
    safe(fn ->
      case :cpu_sup.util() do
        value when is_float(value) -> round1(value)
        value when is_integer(value) -> value * 1.0
        _ -> nil
      end
    end)
  end

  defp load_averages do
    %{
      load_avg_1: load(&:cpu_sup.avg1/0),
      load_avg_5: load(&:cpu_sup.avg5/0),
      load_avg_15: load(&:cpu_sup.avg15/0),
      cpu_count: safe(fn -> :erlang.system_info(:logical_processors_online) end)
    }
  end

  # `:cpu_sup` reports load average scaled by 256.
  defp load(fun) do
    safe(fn ->
      case fun.() do
        n when is_integer(n) -> round2(n / 256)
        _ -> nil
      end
    end)
  end

  # --- Memory ---

  defp memory_data do
    safe(fn -> :memsup.get_system_memory_data() end, [])
  end

  defp memory_percent(mem) do
    with total when is_integer(total) and total > 0 <- total_memory(mem),
         available when is_integer(available) <- available_memory(mem) do
      round1((total - available) / total * 100)
    else
      _ -> nil
    end
  end

  defp memory_detail(mem) do
    total = total_memory(mem)
    available = available_memory(mem)
    total_swap = mem[:total_swap]
    free_swap = mem[:free_swap]

    %{
      memory_total_mb: to_mb(total),
      memory_available_mb: to_mb(available),
      memory_used_mb: to_mb(total && available && total - available),
      memory_cached_mb: to_mb(mem[:cached_memory]),
      memory_buffered_mb: to_mb(mem[:buffered_memory]),
      swap_total_mb: to_mb(total_swap),
      swap_percent: swap_percent(total_swap, free_swap)
    }
  end

  defp total_memory(mem), do: mem[:system_total_memory] || mem[:total_memory]

  # `:available_memory` is the honest number on modern Linux (it accounts for
  # reclaimable page cache). Older systems only expose free/cached/buffered.
  defp available_memory(mem) do
    case mem[:available_memory] do
      n when is_integer(n) ->
        n

      _ ->
        free = mem[:free_memory]
        if is_integer(free), do: free + (mem[:cached_memory] || 0) + (mem[:buffered_memory] || 0)
    end
  end

  defp swap_percent(total, free) when is_integer(total) and is_integer(free) and total > 0,
    do: round1((total - free) / total * 100)

  defp swap_percent(_, _), do: nil

  # --- Disk ---

  @doc """
  Usage for a single mount point: `%{disk_percent:, disk_total_gb:, disk_free_gb:, disk_mount:}`.

  Picks the longest mount path that prefixes `mount`, which is how the kernel
  resolves it — so asking for `/var/lib/app` correctly reports the dedicated
  volume mounted at `/var/lib` rather than the root filesystem.
  """
  def disk(mount \\ "/") do
    case disk_entry(mount) do
      {path, total_kb, percent} ->
        %{
          disk_percent: percent * 1.0,
          disk_total_gb: round1(total_kb / 1024 / 1024),
          disk_free_gb: round1(total_kb * (100 - percent) / 100 / 1024 / 1024),
          disk_mount: path
        }

      nil ->
        %{disk_percent: nil, disk_total_gb: nil, disk_free_gb: nil, disk_mount: mount}
    end
  end

  defp disk_entry(mount) do
    safe(fn ->
      :disksup.get_disk_data()
      |> Enum.map(fn {path, total_kb, percent} -> {List.to_string(path), total_kb, percent} end)
      # `[{"none", 0, 0}]` is os_mon's "I have no data yet" placeholder.
      |> Enum.reject(fn {path, total_kb, _} -> path == "none" or total_kb == 0 end)
      |> Enum.filter(fn {path, _, _} -> String.starts_with?(mount, path) end)
      |> Enum.max_by(fn {path, _, _} -> String.length(path) end, fn -> nil end)
    end)
  end

  # --- Host facts ---

  defp uptime_seconds do
    case read_proc_uptime() do
      nil ->
        # Not Linux: fall back to how long the VM has been up. Less accurate as
        # a host metric, but never absent.
        safe(fn ->
          {total_ms, _since_last} = :erlang.statistics(:wall_clock)
          div(total_ms, 1000)
        end)

      seconds ->
        seconds
    end
  end

  defp read_proc_uptime do
    case File.read("/proc/uptime") do
      {:ok, contents} ->
        contents
        |> String.split(" ", parts: 2)
        |> List.first()
        |> Float.parse()
        |> case do
          {seconds, _} -> trunc(seconds)
          :error -> nil
        end

      _ ->
        nil
    end
  end

  defp host_facts do
    %{
      hostname: safe(fn -> :inet.gethostname() |> elem(1) |> List.to_string() end),
      os: os_string(),
      kernel: kernel_version(),
      arch: safe(fn -> :erlang.system_info(:system_architecture) |> List.to_string() end)
    }
  end

  defp os_string do
    safe(fn ->
      case :os.type() do
        {family, name} -> "#{family}/#{name}"
        family -> to_string(family)
      end
    end)
  end

  defp kernel_version do
    case File.read("/proc/sys/kernel/osrelease") do
      {:ok, contents} -> String.trim(contents)
      _ -> safe(fn -> :os.version() |> Tuple.to_list() |> Enum.join(".") end)
    end
  end

  # --- helpers ---

  defp to_mb(nil), do: nil
  defp to_mb(bytes) when is_integer(bytes), do: div(bytes, 1024 * 1024)
  defp to_mb(_), do: nil

  defp round1(n) when is_number(n), do: Float.round(n * 1.0, 1)
  defp round1(_), do: nil

  defp round2(n) when is_number(n), do: Float.round(n * 1.0, 2)
  defp round2(_), do: nil

  defp safe(fun, default \\ nil) do
    fun.()
  rescue
    _ -> default
  catch
    _, _ -> default
  end
end
