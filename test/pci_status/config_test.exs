defmodule PCIStatus.ConfigTest do
  use ExUnit.Case, async: false

  alias PCIStatus.Config

  setup do
    original = Application.get_all_env(:pci_status)

    on_exit(fn ->
      for {key, _} <- Application.get_all_env(:pci_status) do
        Application.delete_env(:pci_status, key)
      end

      for {key, value} <- original, do: Application.put_env(:pci_status, key, value)
    end)

    :ok
  end

  describe "get/2" do
    test "returns literal values" do
      Application.put_env(:pci_status, :service, "literal")
      assert Config.service() == "literal"
    end

    test "resolves {:system, var} at call time" do
      Application.put_env(:pci_status, :token, {:system, "PCI_STATUS_TEST_TOKEN"})
      assert Config.token() == nil

      System.put_env("PCI_STATUS_TEST_TOKEN", "secret")
      on_exit(fn -> System.delete_env("PCI_STATUS_TEST_TOKEN") end)

      # Read at call time, not at boot — so rotating the env var in a running
      # release takes effect on the next report.
      assert Config.token() == "secret"
    end

    test "an empty env var falls back rather than reporting with a blank token" do
      System.put_env("PCI_STATUS_TEST_EMPTY", "")
      on_exit(fn -> System.delete_env("PCI_STATUS_TEST_EMPTY") end)

      Application.put_env(:pci_status, :token, {:system, "PCI_STATUS_TEST_EMPTY", "fallback"})
      assert Config.token() == "fallback"
    end
  end

  describe "enabled?/0" do
    test "defaults to true" do
      assert Config.enabled?()
    end

    test "treats string falsey values as off, for env-var driven config" do
      for value <- [false, "false", "0"] do
        Application.put_env(:pci_status, :enabled, value)
        refute Config.enabled?()
      end
    end
  end

  describe "checks/0" do
    test "normalises the shorthand forms" do
      Application.put_env(:pci_status, :checks, [
        {:bare, PCIStatus.Checks.Memory},
        {:with_opts, PCIStatus.Checks.Disk, mount: "/"},
        {:mfa, {IO, :puts, ["hi"]}}
      ])

      assert [
               {:bare, PCIStatus.Checks.Memory, []},
               {:with_opts, PCIStatus.Checks.Disk, mount: "/"},
               {:mfa, PCIStatus.Checks.MFA, mfa: {IO, :puts, ["hi"]}}
             ] = Config.checks()
    end

    test "without a repo, the defaults are host-level only" do
      Application.delete_env(:pci_status, :checks)
      Application.delete_env(:pci_status, :repo)

      names = Config.checks() |> Enum.map(&elem(&1, 0))
      assert :disk in names
      assert :memory in names
      refute :database in names
    end

    test "a configured repo adds a database check" do
      Application.delete_env(:pci_status, :checks)
      Application.put_env(:pci_status, :repo, SomeApp.Repo)

      assert {:database, PCIStatus.Checks.Repo, repo: SomeApp.Repo} =
               Config.checks() |> List.first()
    end
  end
end
