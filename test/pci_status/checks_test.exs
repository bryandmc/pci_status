defmodule PCIStatus.ChecksTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias PCIStatus.Checks
  alias PCIStatus.FakeChecks

  describe "normalize/1" do
    test "accepts the documented tuple forms" do
      assert %{status: "up", message: nil} = Checks.normalize(:up)
      assert %{status: "degraded", message: "slow"} = Checks.normalize({:degraded, "slow"})
      assert %{status: "down", message: "gone"} = Checks.normalize({:down, "gone"})
    end

    test "accepts the loose forms host apps reach for" do
      assert %{status: "up"} = Checks.normalize(:ok)
      assert %{status: "up"} = Checks.normalize(true)
      assert %{status: "down"} = Checks.normalize(false)
      assert %{status: "down", message: "nope"} = Checks.normalize({:error, "nope"})
    end

    test "merges detail maps alongside status" do
      assert %{status: "degraded", message: "busy", depth: 42} =
               Checks.normalize({:degraded, "busy", %{depth: 42}})
    end

    test "detail cannot overwrite status" do
      assert %{status: "up"} = Checks.normalize({:up, nil, %{status: "down"}})
    end

    test "an unrecognised return value is down, not silently healthy" do
      assert %{status: "down", message: "malformed check result: :probably_fine"} =
               Checks.normalize(:probably_fine)
    end

    test "non-binary messages are inspected and truncated" do
      assert %{message: "{:error, :enoent}"} = Checks.normalize({:down, {:error, :enoent}})

      long = String.duplicate("x", 900)
      assert %{message: msg} = Checks.normalize({:down, long})
      assert byte_size(msg) == 500
    end
  end

  describe "run_all/2" do
    test "every result carries a status and a latency" do
      checks = [
        {:a, FakeChecks.Up, []},
        {:b, FakeChecks.Degraded, []},
        {:c, FakeChecks.Down, []}
      ]

      results = with_quiet_log(fn -> Checks.run_all(checks) end)

      assert %{"a" => a, "b" => b, "c" => c} = results
      assert a.status == "up"
      assert b.status == "degraded"
      assert b.depth == 42
      assert c.status == "down"

      for {_name, result} <- results do
        assert is_integer(result.latency_ms)
        assert result.status in ~w(up degraded down)
      end
    end

    test "a raising check is recorded as down, not propagated" do
      capture_log(fn ->
        assert %{"boom" => %{status: "down", message: "boom"}} =
                 Checks.run_all([{:boom, FakeChecks.Raising, []}])
      end)
    end

    test "an exiting check is recorded as down" do
      capture_log(fn ->
        assert %{"dead" => %{status: "down", message: message}} =
                 Checks.run_all([{:dead, FakeChecks.Exiting, []}])

        assert message =~ "kaboom"
      end)
    end

    test "a hanging check times out without stalling the others" do
      checks = [
        {:hang, FakeChecks.Hanging, []},
        {:fine, FakeChecks.Up, []}
      ]

      capture_log(fn ->
        results = Checks.run_all(checks, 100)

        assert %{status: "down", message: message} = results["hang"]
        assert message =~ "timed out"
        # The point of the whole design: one wedged dependency must not hide
        # the health of everything else.
        assert %{status: "up"} = results["fine"]
      end)
    end

    test "names survive timeouts, so results stay attributable" do
      checks = [
        {:first, FakeChecks.Up, []},
        {:hang, FakeChecks.Hanging, []},
        {:last, FakeChecks.Up, []}
      ]

      capture_log(fn ->
        results = Checks.run_all(checks, 100)
        assert Map.keys(results) |> Enum.sort() == ["first", "hang", "last"]
      end)
    end

    test "unhealthy checks are logged" do
      log = capture_log(fn -> Checks.run_all([{:db, FakeChecks.Down, []}]) end)
      assert log =~ "check db is down: connection refused"
    end
  end

  # Unhealthy checks log by design; this keeps that noise out of test output
  # while still returning the value under test.
  defp with_quiet_log(fun) do
    {result, _log} = ExUnit.CaptureLog.with_log(fun)
    result
  end
end
