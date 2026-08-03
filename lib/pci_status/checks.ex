defmodule PCIStatus.Checks do
  @moduledoc """
  Runs the configured checks concurrently and normalises their results into
  the wire shape the portal expects.

  Each check runs in its own task with an individual timeout, so one wedged
  dependency neither stalls the report nor hides the others — it just shows up
  as `down: "timed out after 5000ms"` while everything else reports normally.
  """

  require Logger

  @doc """
  Runs `checks` (a list of `{name, module, opts}`) and returns a map of

      %{"database" => %{status: "up", latency_ms: 3, message: "SELECT 1"}}

  The `status` key is always present and always one of `"up"`, `"degraded"`,
  `"down"` — the portal's ingest pattern-matches on it.
  """
  def run_all(checks, timeout \\ 5_000) do
    checks
    |> Task.async_stream(&run_one(&1, timeout),
      timeout: timeout + 500,
      on_timeout: :kill_task,
      ordered: true
    )
    |> Enum.zip(checks)
    |> Map.new(fn
      {{:ok, result}, {name, _module, _opts}} ->
        {to_string(name), result}

      # The task itself was killed — the check blocked past even its own
      # internal timeout (uninterruptible NIF, wedged port, …).
      {{:exit, reason}, {name, _module, _opts}} ->
        {to_string(name), timed_out(reason, timeout)}
    end)
  end

  defp run_one({name, module, opts}, timeout) do
    started = System.monotonic_time(:millisecond)

    result =
      try do
        module.run(opts)
      rescue
        e -> {:down, Exception.message(e)}
      catch
        :exit, {:timeout, _} -> {:down, "timed out after #{timeout}ms"}
        :exit, reason -> {:down, "exited: #{inspect(reason)}"}
        kind, reason -> {:down, "#{kind}: #{inspect(reason)}"}
      end

    elapsed = System.monotonic_time(:millisecond) - started

    result
    |> normalize()
    |> Map.put(:latency_ms, elapsed)
    |> tap(&log_if_unhealthy(name, &1))
  end

  defp timed_out(:timeout, timeout),
    do: %{status: "down", message: "timed out after #{timeout}ms", latency_ms: timeout}

  defp timed_out(reason, timeout),
    do: %{status: "down", message: "check crashed: #{inspect(reason)}", latency_ms: timeout}

  @doc """
  Coerces a check's return value into `%{status: binary, message: binary | nil}`.

  Deliberately permissive: `PCIStatus.Checks.MFA` lets host apps plug in
  arbitrary functions, and it's better to accept `true`/`:ok` than to make
  everyone learn a tuple format.
  """
  def normalize(:up), do: %{status: "up", message: nil}
  def normalize(:ok), do: %{status: "up", message: nil}
  def normalize(true), do: %{status: "up", message: nil}
  def normalize(:degraded), do: %{status: "degraded", message: nil}
  def normalize(:down), do: %{status: "down", message: nil}
  def normalize(:error), do: %{status: "down", message: nil}
  def normalize(false), do: %{status: "down", message: nil}

  def normalize({status, message}) when status in [:up, :ok, :degraded, :down, :error],
    do: %{status: status_string(status), message: stringify(message)}

  def normalize({status, message, detail})
      when status in [:up, :ok, :degraded, :down, :error] and is_map(detail) do
    detail
    |> Map.new(fn {k, v} -> {k, v} end)
    |> Map.merge(%{status: status_string(status), message: stringify(message)})
  end

  # Anything else is a check that didn't follow the contract. Report it as
  # down rather than silently treating an unknown value as healthy.
  def normalize(other),
    do: %{status: "down", message: "malformed check result: #{inspect(other)}"}

  defp status_string(:ok), do: "up"
  defp status_string(:error), do: "down"
  defp status_string(status), do: to_string(status)

  defp stringify(nil), do: nil
  defp stringify(message) when is_binary(message), do: String.slice(message, 0, 500)
  defp stringify(message), do: message |> inspect() |> String.slice(0, 500)

  defp log_if_unhealthy(_name, %{status: "up"}), do: :ok

  defp log_if_unhealthy(name, %{status: status, message: message}) do
    Logger.warning("[pci_status] check #{name} is #{status}: #{message || "no detail"}")
  end
end
