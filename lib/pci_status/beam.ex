defmodule PCIStatus.Beam do
  @moduledoc """
  VM-level diagnostics: the numbers you actually want when a node is sick.

  Process/port/atom/ETS counts are reported alongside their limits, because
  the absolute number is meaningless without it — 300k processes is fine at
  the default limit of 1M and fatal at 262k. Atom count is included for the
  same reason: atom exhaustion is unrecoverable and creeps up silently.

  All keys are flat scalars so the portal can render them in a key/value grid.
  """

  @doc "Collects VM metrics as a flat map of scalars."
  def collect do
    memory = safe(fn -> :erlang.memory() end, [])

    %{}
    |> Map.merge(runtime_facts())
    |> Map.merge(limits())
    |> Map.merge(memory_breakdown(memory))
    |> Map.merge(scheduler_facts())
  end

  defp runtime_facts do
    %{
      node: to_string(Node.self()),
      otp_release: safe(fn -> List.to_string(:erlang.system_info(:otp_release)) end),
      erts_version: safe(fn -> List.to_string(:erlang.system_info(:version)) end),
      elixir_version: System.version(),
      beam_uptime_seconds:
        safe(fn ->
          {total_ms, _} = :erlang.statistics(:wall_clock)
          div(total_ms, 1000)
        end),
      connected_nodes: length(Node.list())
    }
  end

  defp limits do
    %{
      beam_processes: count(:process_count),
      beam_process_limit: count(:process_limit),
      beam_process_pct: pct(count(:process_count), count(:process_limit)),
      beam_ports: count(:port_count),
      beam_port_limit: count(:port_limit),
      beam_atoms: count(:atom_count),
      beam_atom_limit: count(:atom_limit),
      beam_atom_pct: pct(count(:atom_count), count(:atom_limit)),
      beam_ets_tables: count(:ets_count)
    }
  end

  defp memory_breakdown(memory) do
    %{
      beam_memory_total_mb: to_mb(memory[:total]),
      beam_memory_processes_mb: to_mb(memory[:processes]),
      beam_memory_binary_mb: to_mb(memory[:binary]),
      beam_memory_ets_mb: to_mb(memory[:ets]),
      beam_memory_atom_mb: to_mb(memory[:atom]),
      beam_memory_code_mb: to_mb(memory[:code])
    }
  end

  defp scheduler_facts do
    %{
      beam_schedulers: count(:schedulers_online),
      beam_run_queue: safe(fn -> :erlang.statistics(:run_queue) end),
      beam_gc_count:
        safe(fn ->
          {gcs, _words_reclaimed, _} = :erlang.statistics(:garbage_collection)
          gcs
        end),
      beam_reductions:
        safe(fn ->
          {total, _since_last} = :erlang.statistics(:reductions)
          total
        end)
    }
  end

  defp count(key), do: safe(fn -> :erlang.system_info(key) end)

  defp pct(used, limit) when is_integer(used) and is_integer(limit) and limit > 0,
    do: Float.round(used / limit * 100, 1)

  defp pct(_, _), do: nil

  defp to_mb(nil), do: nil
  defp to_mb(bytes) when is_integer(bytes), do: Float.round(bytes / 1024 / 1024, 1)
  defp to_mb(_), do: nil

  defp safe(fun, default \\ nil) do
    fun.()
  rescue
    _ -> default
  catch
    _, _ -> default
  end
end
