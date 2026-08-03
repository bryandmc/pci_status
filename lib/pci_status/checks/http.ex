defmodule PCIStatus.Checks.HTTP do
  @moduledoc """
  Fetches a URL and asserts on the response status.

  Use it for sidecars that speak HTTP — OSRM, a scraper control plane, an
  internal API. Options:

    * `:url` (required)
    * `:expect` — accepted status codes, an integer, list or range (default `200..299`)
    * `:method` — `:get` or `:head` (default `:get`)
    * `:timeout` — milliseconds (default 3000)
    * `:degrade_on_slow_ms` — report `:degraded` rather than `:up` above this latency
  """
  @behaviour PCIStatus.Check

  @impl true
  def run(opts) do
    url = Keyword.fetch!(opts, :url)
    expect = Keyword.get(opts, :expect, 200..299)
    method = Keyword.get(opts, :method, :get)
    timeout = Keyword.get(opts, :timeout, 3_000)
    slow_ms = Keyword.get(opts, :degrade_on_slow_ms)

    started = System.monotonic_time(:millisecond)

    request =
      Req.new(
        url: url,
        method: method,
        receive_timeout: timeout,
        connect_options: [timeout: timeout],
        retry: false,
        # A status check should report a 500, not raise on one.
        decode_body: false
      )

    case Req.request(request) do
      {:ok, %Req.Response{status: status}} ->
        elapsed = System.monotonic_time(:millisecond) - started
        classify(status, expect, elapsed, slow_ms)

      {:error, %{__exception__: true} = e} ->
        {:down, Exception.message(e)}

      {:error, reason} ->
        {:down, inspect(reason)}
    end
  end

  defp classify(status, expect, elapsed, slow_ms) do
    cond do
      not acceptable?(status, expect) ->
        {:down, "HTTP #{status}", %{status_code: status}}

      is_integer(slow_ms) and elapsed > slow_ms ->
        {:degraded, "HTTP #{status}, slow (#{elapsed}ms > #{slow_ms}ms)", %{status_code: status}}

      true ->
        {:up, "HTTP #{status}", %{status_code: status}}
    end
  end

  defp acceptable?(status, expect) when is_integer(expect), do: status == expect
  defp acceptable?(status, %Range{} = expect), do: status in expect
  defp acceptable?(status, expect) when is_list(expect), do: status in expect
end
