defmodule PCIStatus.Config do
  @moduledoc """
  Resolves the agent's configuration from `Application.get_env(:pci_status, …)`.

  Every value may be given literally or as `{:system, "VAR"}` /
  `{:system, "VAR", default}`, which is read at runtime. That keeps secrets
  out of compiled config while still allowing a plain value in dev.

      config :pci_status,
        url: "https://pacific-coast-insights.com/api/status",
        token: {:system, "PCI_STATUS_TOKEN"},
        otp_app: :ptp,
        service: "ptp-backend",
        repo: Ptp.Repo,
        interval: :timer.seconds(60)

  The agent is a no-op unless both a `:url` and a `:token` resolve, so an app
  that hasn't been provisioned in the portal yet simply doesn't report.
  """

  @default_url "https://pacific-coast-insights.com/api/status"
  @default_interval :timer.seconds(60)
  @default_timeout :timer.seconds(10)
  # Long enough that a slow-but-alive dependency still lands in the report,
  # short enough that it can't push us past the tick interval.
  @default_check_timeout :timer.seconds(5)

  @doc "The full ingest URL to POST snapshots to."
  def url, do: get(:url, @default_url)

  @doc "Bearer token identifying this app to the portal. `nil` disables reporting."
  def token, do: get(:token, nil)

  @doc "Milliseconds between reports."
  def interval, do: get(:interval, @default_interval)

  @doc "HTTP timeout for a single report POST, in milliseconds."
  def timeout, do: get(:timeout, @default_timeout)

  @doc "Per-check timeout, in milliseconds. A check that exceeds it reports `down`."
  def check_timeout, do: get(:check_timeout, @default_check_timeout)

  @doc "The host application, used for the version string and app-env lookups."
  def otp_app, do: get(:otp_app, nil)

  @doc "Human-readable service name included in the payload."
  def service, do: get(:service, otp_app() && to_string(otp_app()))

  @doc "Deployment environment label (`\"prod\"`, `\"staging\"`, …)."
  def environment, do: get(:environment, {:system, "PCI_STATUS_ENV", default_environment()})

  @doc "The Ecto repo to introspect for database checks and pool stats. Optional."
  def repo, do: get(:repo, nil)

  @doc "Filesystem whose usage is reported as `disk_percent`."
  def disk_mount, do: get(:disk_mount, "/")

  @doc """
  `{module, function, args}` returning a flat map of extra application facts.
  Merged into the payload's `application` section, so the host app can publish
  its own domain-level numbers without this library knowing anything about them.
  """
  def extra, do: get(:extra, nil)

  @doc "Whether reporting is switched on at all. Defaults to true."
  def enabled?, do: get(:enabled, true) not in [false, "false", "0"]

  @doc """
  Configured checks, as a list of `{name, module, opts}`.

  Accepts the looser forms `{name, module}` and `{name, {m, f, a}}` too. When
  unset, a sensible default set is derived from the rest of the config.
  """
  def checks do
    case get(:checks, nil) do
      nil -> default_checks()
      list when is_list(list) -> Enum.map(list, &normalize_check/1)
    end
  end

  defp normalize_check({name, module}) when is_atom(module), do: {name, module, []}
  defp normalize_check({name, module, opts}) when is_atom(module), do: {name, module, opts}

  defp normalize_check({name, {m, f, a}}),
    do: {name, PCIStatus.Checks.MFA, mfa: {m, f, a}}

  defp default_checks do
    repo_check =
      case repo() do
        nil -> []
        repo -> [{:database, PCIStatus.Checks.Repo, repo: repo}]
      end

    oban_check =
      if repo() && PCIStatus.Runtime.loaded?(Oban),
        do: [{:oban, PCIStatus.Checks.Oban, repo: repo()}],
        else: []

    repo_check ++
      oban_check ++
      [
        {:disk, PCIStatus.Checks.Disk, mount: disk_mount()},
        {:memory, PCIStatus.Checks.Memory, []}
      ]
  end

  @doc """
  Reads a config key, resolving `{:system, var}` tuples at call time.
  """
  def get(key, default) do
    :pci_status
    |> Application.get_env(key, default)
    |> resolve(default)
  end

  defp resolve({:system, var}, default), do: resolve({:system, var, default}, default)

  defp resolve({:system, var, fallback}, _default) do
    case System.get_env(var) do
      nil -> fallback
      "" -> fallback
      value -> value
    end
  end

  defp resolve({:mfa, m, f, a}, _default), do: apply(m, f, a)
  defp resolve(value, _default), do: value

  defp default_environment do
    cond do
      function_exported?(Mix, :env, 0) -> to_string(apply(Mix, :env, []))
      true -> "prod"
    end
  end
end
