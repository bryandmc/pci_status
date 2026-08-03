defmodule PCIStatus.Runtime do
  @moduledoc """
  Optional-integration plumbing.

  This library deliberately does not depend on Ecto, Postgrex or Oban — it
  reaches them by name at runtime instead. That means dropping `:pci_status`
  into a brand-new app never drags in a database stack it doesn't have, and
  never constrains the versions of one it does.

  `Module.concat/1` is used rather than a literal alias so the compiler doesn't
  emit "module is not available" warnings in apps that lack the integration.
  """

  @doc "True when `module` is loadable in the running system."
  def loaded?(module) when is_atom(module) do
    Code.ensure_loaded?(module)
  end

  @doc """
  Runs a SQL query through an Ecto repo without depending on Ecto.

  Returns `{:ok, %{rows: rows, num_rows: n}}`, or `{:error, reason}` when the
  repo isn't configured, isn't running, or the query fails.
  """
  def sql_query(repo, statement, params \\ [], opts \\ [])

  def sql_query(nil, _statement, _params, _opts), do: {:error, :no_repo}

  def sql_query(repo, statement, params, opts) do
    sql = Module.concat([:Ecto, :Adapters, :SQL])

    cond do
      not loaded?(repo) ->
        {:error, :no_repo}

      not loaded?(sql) ->
        {:error, :no_ecto_sql}

      is_nil(Process.whereis(repo)) ->
        {:error, :repo_not_started}

      true ->
        try do
          apply(sql, :query, [repo, statement, params, opts])
        rescue
          e -> {:error, Exception.message(e)}
        catch
          :exit, reason -> {:error, exit_reason(reason)}
        end
    end
  end

  @doc "Same as `sql_query/4` but returns just the first cell, or `nil`."
  def sql_one(repo, statement, params \\ [], opts \\ []) do
    case sql_query(repo, statement, params, opts) do
      {:ok, %{rows: [[value | _] | _]}} -> value
      _ -> nil
    end
  end

  @doc "Configured pool size for an Ecto repo, or `nil`."
  def pool_size(nil), do: nil

  def pool_size(repo) do
    if loaded?(repo) and function_exported?(repo, :config, 0) do
      repo.config()[:pool_size]
    end
  end

  defp exit_reason({:timeout, _}), do: :timeout
  defp exit_reason({:noproc, _}), do: :repo_not_started
  defp exit_reason(reason), do: inspect(reason)
end
