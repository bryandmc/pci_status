defmodule PCIStatus.FakeChecks do
  @moduledoc false

  defmodule Up do
    @behaviour PCIStatus.Check
    @impl true
    def run(_opts), do: {:up, "fine"}
  end

  defmodule Degraded do
    @behaviour PCIStatus.Check
    @impl true
    def run(_opts), do: {:degraded, "queue backing up", %{depth: 42}}
  end

  defmodule Down do
    @behaviour PCIStatus.Check
    @impl true
    def run(_opts), do: {:down, "connection refused"}
  end

  defmodule Raising do
    @behaviour PCIStatus.Check
    @impl true
    def run(_opts), do: raise("boom")
  end

  defmodule Exiting do
    @behaviour PCIStatus.Check
    @impl true
    def run(_opts), do: exit(:kaboom)
  end

  defmodule Hanging do
    @behaviour PCIStatus.Check
    @impl true
    def run(_opts) do
      Process.sleep(:infinity)
      :up
    end
  end

  defmodule Malformed do
    @behaviour PCIStatus.Check
    @impl true
    def run(_opts), do: :probably_fine
  end
end
