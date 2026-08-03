defmodule PCIStatus.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/bryandmc/pci_status"

  def project do
    [
      app: :pci_status,
      version: @version,
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      description:
        "Liveness, health and deep-diagnostic reporting agent for the Pacific Coast Insights portal.",
      package: package(),
      docs: docs(),
      source_url: @source_url
    ]
  end

  # `:os_mon` is the whole reason host apps don't have to think about system
  # metrics — declaring it here starts it in every consumer automatically.
  def application do
    [extra_applications: [:logger, :os_mon]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Deliberately minimal. Ecto, Oban and Postgres are reached through runtime
  # dispatch (see `PCIStatus.Runtime`) rather than declared deps, so dropping
  # this library into a new app never drags in or constrains anything.
  defp deps do
    [
      {:req, "~> 0.5"},
      {:jason, "~> 1.2"},
      {:telemetry, "~> 1.0"},
      {:plug, "~> 1.14", optional: true},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url}
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md"],
      groups_for_modules: [
        Collectors: [PCIStatus.System, PCIStatus.Beam, PCIStatus.Build],
        Checks: [
          PCIStatus.Check,
          PCIStatus.Checks,
          PCIStatus.Checks.Repo,
          PCIStatus.Checks.HTTP,
          PCIStatus.Checks.Oban,
          PCIStatus.Checks.Disk,
          PCIStatus.Checks.Memory,
          PCIStatus.Checks.Process,
          PCIStatus.Checks.MFA
        ]
      ]
    ]
  end

  defp aliases do
    [
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"]
    ]
  end
end
