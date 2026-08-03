defmodule PCIStatus.Checks.Oban do
  @moduledoc """
  Reports Oban queue health by reading `oban_jobs` directly.

  Going to the table rather than through Oban's API keeps this working across
  Oban versions and doesn't require the library as a dependency. It also
  surfaces the state that actually indicates trouble: a growing `available`
  backlog (workers can't keep up) or accumulating `discarded` jobs (work is
  being silently dropped).

  Options: `:repo` (required), `:table` (default `"oban_jobs"`),
  `:max_available` (default 1000), `:max_retryable` (default 100),
  `:max_discarded` (default 0 — any discard is worth surfacing).
  """
  @behaviour PCIStatus.Check

  alias PCIStatus.Runtime

  @impl true
  def run(opts) do
    repo = Keyword.get(opts, :repo)
    table = Keyword.get(opts, :table, "oban_jobs")

    case Runtime.sql_query(repo, "SELECT state, count(*) FROM #{table} GROUP BY state", [],
           timeout: 3_000
         ) do
      {:ok, %{rows: rows}} ->
        rows
        |> Map.new(fn [state, count] -> {state, count} end)
        |> assess(opts)

      {:error, :no_repo} ->
        {:down, "no repo configured"}

      {:error, reason} ->
        {:down, describe(reason)}
    end
  end

  defp assess(counts, opts) do
    available = Map.get(counts, "available", 0)
    executing = Map.get(counts, "executing", 0)
    retryable = Map.get(counts, "retryable", 0)
    discarded = Map.get(counts, "discarded", 0)
    scheduled = Map.get(counts, "scheduled", 0)

    detail = %{
      available: available,
      executing: executing,
      retryable: retryable,
      discarded: discarded,
      scheduled: scheduled
    }

    summary = "#{executing} executing, #{available} available"

    cond do
      discarded > Keyword.get(opts, :max_discarded, 0) ->
        {:degraded, "#{discarded} discarded jobs", detail}

      available > Keyword.get(opts, :max_available, 1_000) ->
        {:degraded, "backlog of #{available} available jobs", detail}

      retryable > Keyword.get(opts, :max_retryable, 100) ->
        {:degraded, "#{retryable} jobs retrying", detail}

      true ->
        {:up, summary, detail}
    end
  end

  defp describe(reason) when is_binary(reason) do
    if String.contains?(reason, "does not exist"),
      do: "oban_jobs table missing — migrations not run?",
      else: reason
  end

  defp describe(reason), do: inspect(reason)
end
