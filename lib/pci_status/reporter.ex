defmodule PCIStatus.Reporter do
  @moduledoc """
  Periodically collects a status payload and POSTs it to the portal.

  Add it to your supervision tree — after the repo and endpoint, so its first
  report describes a fully-booted app:

      children = [
        MyApp.Repo,
        MyAppWeb.Endpoint,
        PCIStatus.Reporter
      ]

  ## Failure behaviour

  This process exists to report problems, so it must never *become* one:

    * Collection and delivery run in a monitored task with a hard timeout; a
      wedged HTTP call or a hung check cannot block the next tick.
    * Any crash is logged and swallowed — the reporter neither dies nor takes
      its supervisor down.
    * Delivery failures back off exponentially to `@max_backoff`, so an
      unreachable portal doesn't turn into a request flood.
    * Each interval is jittered ±10% so a fleet restarted together doesn't
      settle into a synchronised thundering herd.

  A 401 is treated as fatal-but-quiet: the token is wrong, retrying faster
  won't help, so it logs once at error and keeps ticking at the base interval.
  """

  use GenServer
  require Logger

  alias PCIStatus.{Collector, Config}

  @max_backoff :timer.minutes(5)
  @initial_delay :timer.seconds(5)
  @jitter_pct 10

  defstruct [:interval, :backoff, :last_result, :last_reported_at, :warned_unauthorized]

  # --- API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Sends a report immediately, out of band. Returns `{:ok, status}` or
  `{:error, reason}`. Useful from a release remote shell to confirm wiring.
  """
  def report_now(server \\ __MODULE__, timeout \\ 30_000) do
    GenServer.call(server, :report_now, timeout)
  end

  @doc "Last delivery outcome and when it happened, without triggering a report."
  def last_result(server \\ __MODULE__) do
    GenServer.call(server, :last_result)
  end

  # --- Callbacks ---

  @impl true
  def init(_opts) do
    cond do
      not Config.enabled?() ->
        Logger.info("[pci_status] reporting disabled by config")
        :ignore

      is_nil(Config.token()) ->
        Logger.info("[pci_status] no token configured — status reporting is off")
        :ignore

      true ->
        # The first `:cpu_sup.util/0` reading covers everything since os_mon
        # booted and is therefore meaningless. Burn it now so the first real
        # report carries a genuine interval measurement.
        prime_cpu()

        interval = Config.interval()
        Process.send_after(self(), :tick, @initial_delay)

        {:ok, %__MODULE__{interval: interval, backoff: interval}}
    end
  end

  @impl true
  def handle_info(:tick, state) do
    state = do_report(state)
    Process.send_after(self(), :tick, jitter(state.backoff))
    {:noreply, state}
  end

  # A late reply from a task we already gave up on.
  def handle_info({ref, _result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_call(:report_now, _from, state) do
    state = do_report(state)
    {:reply, state.last_result, state}
  end

  def handle_call(:last_result, _from, state) do
    {:reply, %{result: state.last_result, at: state.last_reported_at}, state}
  end

  # --- Reporting ---

  defp do_report(state) do
    started = System.monotonic_time(:millisecond)
    timeout = Config.timeout() + Config.check_timeout() + 2_000

    result =
      case run_with_timeout(&collect_and_send/0, timeout) do
        {:ok, result} -> result
        {:error, :timeout} -> {:error, "report timed out after #{timeout}ms"}
      end

    duration = System.monotonic_time(:millisecond) - started
    emit_telemetry(result, duration)

    state
    |> Map.put(:last_result, result)
    |> Map.put(:last_reported_at, DateTime.utc_now())
    |> apply_backoff(result)
  end

  defp collect_and_send do
    payload = Collector.collect()

    Req.post(Config.url(),
      json: payload,
      headers: [
        {"authorization", "Bearer #{Config.token()}"},
        {"user-agent", "pci_status/#{version()} (#{Config.service()})"}
      ],
      receive_timeout: Config.timeout(),
      connect_options: [timeout: Config.timeout()],
      retry: false
    )
    |> case do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        {:ok, status}

      {:ok, %Req.Response{status: 401}} ->
        {:error, :unauthorized}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, "HTTP #{status}: #{summarize(body)}"}

      {:error, %{__exception__: true} = e} ->
        {:error, Exception.message(e)}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  rescue
    e -> {:error, Exception.message(e)}
  catch
    kind, reason -> {:error, "#{kind}: #{inspect(reason)}"}
  end

  # Runs `fun` in a task we're willing to abandon. Shutting the task down on
  # timeout is what stops a wedged socket from leaking a process per tick.
  defp run_with_timeout(fun, timeout) do
    task = Task.async(fun)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> {:ok, result}
      {:exit, reason} -> {:ok, {:error, "crashed: #{inspect(reason)}"}}
      nil -> {:error, :timeout}
    end
  end

  # --- Backoff ---

  defp apply_backoff(state, {:ok, _status}) do
    if match?({:error, _}, state.last_result) or state.backoff != state.interval do
      Logger.info("[pci_status] reporting recovered")
    end

    %{state | backoff: state.interval, warned_unauthorized: false}
  end

  defp apply_backoff(state, {:error, :unauthorized}) do
    unless state.warned_unauthorized do
      Logger.error(
        "[pci_status] portal rejected the API token (401). Check PCI_STATUS_TOKEN against " <>
          "the app's token in the portal. Not backing off — fix the token and it resumes."
      )
    end

    # No backoff: a wrong token is a config bug, not portal load. Keep the
    # steady heartbeat so it starts working the moment the token is fixed.
    %{state | backoff: state.interval, warned_unauthorized: true}
  end

  defp apply_backoff(state, {:error, reason}) do
    next = min(state.backoff * 2, @max_backoff)

    Logger.warning(
      "[pci_status] report failed (#{inspect(reason)}); retrying in #{div(next, 1000)}s"
    )

    %{state | backoff: next}
  end

  # --- helpers ---

  defp jitter(interval) do
    spread = div(interval * @jitter_pct, 100)
    interval - spread + :rand.uniform(max(spread * 2, 1))
  end

  defp prime_cpu do
    :cpu_sup.util()
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp emit_telemetry(result, duration) do
    status = if match?({:ok, _}, result), do: :ok, else: :error

    :telemetry.execute(
      [:pci_status, :report, :stop],
      %{duration_ms: duration},
      %{status: status, result: result}
    )
  rescue
    _ -> :ok
  end

  defp summarize(body) when is_binary(body), do: String.slice(body, 0, 200)
  defp summarize(body), do: body |> inspect() |> String.slice(0, 200)

  defp version do
    case Application.spec(:pci_status, :vsn) do
      nil -> "dev"
      vsn -> List.to_string(vsn)
    end
  end
end
