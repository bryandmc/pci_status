defmodule PCIStatus.Checks.MFA do
  @moduledoc """
  Escape hatch: runs an arbitrary function as a check.

  The return value goes through `PCIStatus.Checks.normalize/1`, so `:ok`,
  `true`, `{:error, "reason"}` and the full `{status, message, detail}` form
  all work.

      {:shopify, PCIStatus.Checks.MFA, mfa: {MyApp.Shopify, :ping, []}}

  The shorthand `{:shopify, {MyApp.Shopify, :ping, []}}` in `:checks` config
  expands to exactly this.
  """
  @behaviour PCIStatus.Check

  @impl true
  def run(opts) do
    {m, f, a} = Keyword.fetch!(opts, :mfa)
    apply(m, f, a)
  end
end
