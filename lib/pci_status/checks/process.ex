defmodule PCIStatus.Checks.Process do
  @moduledoc """
  Asserts a named process is registered and alive.

  Useful for singleton workers whose absence is invisible otherwise — a sync
  lock, a poller, a connection manager. Reports the process's message queue
  length too, since a live-but-drowning process is its own failure mode.

  Options: `:name` (required), `:max_queue` (default 10_000).
  """
  @behaviour PCIStatus.Check

  @impl true
  def run(opts) do
    name = Keyword.fetch!(opts, :name)
    max_queue = Keyword.get(opts, :max_queue, 10_000)

    case Elixir.Process.whereis(name) do
      nil ->
        {:down, "#{inspect(name)} is not registered"}

      pid ->
        queue = queue_len(pid)

        cond do
          is_integer(queue) and queue > max_queue ->
            {:degraded, "message queue at #{queue}", %{message_queue_len: queue}}

          true ->
            {:up, "alive", %{message_queue_len: queue}}
        end
    end
  end

  defp queue_len(pid) do
    case Elixir.Process.info(pid, :message_queue_len) do
      {:message_queue_len, n} -> n
      _ -> nil
    end
  end
end
