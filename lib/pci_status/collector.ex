defmodule PCIStatus.Collector do
  @moduledoc """
  Assembles the full status payload.

  The wire shape is fixed by what the portal renders:

    * `checks` — map of name to `%{status, latency_ms, message, …}`. Every
      entry **must** carry a `status` key; ingest pattern-matches on it.
    * `system` — host gauges. `cpu_percent`, `memory_percent`, `disk_percent`
      and `uptime_seconds` drive the charts; the rest is detail.
    * `application` — a **flat** map of scalars, rendered as a key/value grid.
      Nested maps would render as inspected garbage, so `flatten/1` enforces it.
  """

  alias PCIStatus.{Beam, Build, Checks, Config, Runtime, System}

  @doc """
  Runs every check and gathers every metric. Returns the payload as a map with
  atom keys, ready for JSON encoding.
  """
  def collect do
    %{
      version: Build.version(),
      service: Config.service(),
      timestamp: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      # Tells the portal how long to wait before calling this app stale, so
      # liveness detection tunes itself instead of needing a matching setting
      # on both sides.
      interval_seconds: max(div(Config.interval(), 1000), 1),
      checks: Checks.run_all(Config.checks(), Config.check_timeout()),
      system: System.collect(Config.disk_mount()),
      application: application()
    }
  end

  @doc "The `application` section on its own: build info, VM stats, DB stats, host extras."
  def application do
    Build.info()
    |> Map.merge(Beam.collect())
    |> Map.merge(database())
    |> Map.merge(extra())
    |> flatten()
  end

  # --- database ---

  defp database do
    repo = Config.repo()

    if is_nil(repo) do
      %{}
    else
      %{
        db_pool_size: Runtime.pool_size(repo),
        db_size_mb: db_size_mb(repo),
        db_connections: db_connections(repo),
        db_max_connections: db_setting(repo, "max_connections")
      }
      |> Map.merge(oban_counts(repo))
    end
  end

  defp db_size_mb(repo) do
    case Runtime.sql_one(repo, "SELECT pg_database_size(current_database())", [], timeout: 3_000) do
      bytes when is_integer(bytes) -> Float.round(bytes / 1024 / 1024, 1)
      _ -> nil
    end
  end

  defp db_connections(repo) do
    Runtime.sql_one(
      repo,
      "SELECT count(*) FROM pg_stat_activity WHERE datname = current_database()",
      [],
      timeout: 3_000
    )
  end

  defp db_setting(repo, name) do
    case Runtime.sql_one(repo, "SELECT current_setting($1)", [name], timeout: 3_000) do
      value when is_binary(value) -> to_integer(value)
      _ -> nil
    end
  end

  # Mirrors the Oban check's numbers into the flat grid, where they're easier
  # to scan over time than inside a check's detail blob.
  defp oban_counts(repo) do
    if Runtime.loaded?(Oban) do
      case Runtime.sql_query(repo, "SELECT state, count(*) FROM oban_jobs GROUP BY state", [],
             timeout: 3_000
           ) do
        {:ok, %{rows: rows}} ->
          Map.new(rows, fn [state, count] -> {:"oban_#{state}", count} end)

        _ ->
          %{}
      end
    else
      %{}
    end
  end

  # --- host-supplied extras ---

  defp extra do
    case Config.extra() do
      {m, f, a} ->
        case apply(m, f, a) do
          map when is_map(map) -> map
          _ -> %{}
        end

      _ ->
        %{}
    end
  rescue
    e ->
      require Logger
      Logger.warning("[pci_status] extra/0 callback failed: #{Exception.message(e)}")
      %{}
  end

  # --- flattening ---

  @doc """
  Coerces a map into flat string-keyed scalars, dropping nils.

  Nested maps are flattened with dotted keys rather than dropped, so a host
  app returning structured extras still gets something readable in the portal
  instead of `%{a: 1}` rendered through `to_string/1`.
  """
  def flatten(map, prefix \\ nil) do
    Enum.reduce(map, %{}, fn {key, value}, acc ->
      key = if prefix, do: "#{prefix}.#{key}", else: to_string(key)

      case value do
        nil -> acc
        %DateTime{} = dt -> Map.put(acc, key, DateTime.to_iso8601(dt))
        %NaiveDateTime{} = dt -> Map.put(acc, key, NaiveDateTime.to_iso8601(dt))
        %Date{} = d -> Map.put(acc, key, Date.to_iso8601(d))
        %_{} = struct -> Map.put(acc, key, inspect(struct))
        %{} = nested -> Map.merge(acc, flatten(nested, key))
        v when is_binary(v) or is_number(v) or is_boolean(v) -> Map.put(acc, key, v)
        v when is_atom(v) -> Map.put(acc, key, to_string(v))
        v when is_list(v) -> Map.put(acc, key, Enum.join(List.wrap(v), ", "))
        v -> Map.put(acc, key, inspect(v))
      end
    end)
  end

  defp to_integer(value) do
    case Integer.parse(value) do
      {n, _} -> n
      :error -> nil
    end
  end
end
