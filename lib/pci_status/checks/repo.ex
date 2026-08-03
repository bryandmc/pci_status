defmodule PCIStatus.Checks.Repo do
  @moduledoc """
  Round-trips `SELECT 1` through an Ecto repo.

  This is the check that matters most: it exercises the pool, the connection
  and the server together. A repo that's up but whose pool is exhausted will
  time out here, which is exactly the signal you want.

  Options: `:repo` (required), `:timeout` (default 3000ms).
  """
  @behaviour PCIStatus.Check

  alias PCIStatus.Runtime

  @impl true
  def run(opts) do
    repo = Keyword.get(opts, :repo)
    timeout = Keyword.get(opts, :timeout, 3_000)

    case Runtime.sql_query(repo, "SELECT 1", [], timeout: timeout) do
      {:ok, %{rows: [[1]]}} -> {:up, "SELECT 1"}
      {:ok, other} -> {:degraded, "unexpected result: #{inspect(other)}"}
      {:error, :no_repo} -> {:down, "no repo configured"}
      {:error, :repo_not_started} -> {:down, "repo process not running"}
      {:error, :no_ecto_sql} -> {:down, "ecto_sql not available"}
      {:error, reason} -> {:down, describe(reason)}
    end
  end

  defp describe(reason) when is_binary(reason), do: reason
  defp describe(:timeout), do: "query timed out"
  defp describe(reason), do: inspect(reason)
end
