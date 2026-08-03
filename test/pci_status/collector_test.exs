defmodule PCIStatus.CollectorTest do
  use ExUnit.Case, async: true

  alias PCIStatus.Collector

  describe "flatten/1" do
    test "keeps scalars and stringifies keys" do
      assert Collector.flatten(%{count: 3, name: "x", ok: true, ratio: 1.5}) == %{
               "count" => 3,
               "name" => "x",
               "ok" => true,
               "ratio" => 1.5
             }
    end

    test "drops nils so the portal grid stays readable" do
      assert Collector.flatten(%{present: 1, absent: nil}) == %{"present" => 1}
    end

    test "flattens nested maps with dotted keys rather than dropping them" do
      # The portal renders this section with to_string/1, so a nested map would
      # otherwise show up as inspected garbage.
      assert Collector.flatten(%{shopify: %{configured: true, shop: "acme"}}) == %{
               "shopify.configured" => true,
               "shopify.shop" => "acme"
             }
    end

    test "renders date and time structs as ISO8601" do
      flat =
        Collector.flatten(%{
          at: ~U[2026-08-03 12:00:00Z],
          naive: ~N[2026-08-03 12:00:00],
          day: ~D[2026-08-03]
        })

      assert flat["at"] == "2026-08-03T12:00:00Z"
      assert flat["naive"] == "2026-08-03T12:00:00"
      assert flat["day"] == "2026-08-03"
    end

    test "atoms become strings and lists are joined" do
      flat = Collector.flatten(%{mod: Ptp.Repo, queues: [:default, :ingest]})
      assert flat["mod"] == "Elixir.Ptp.Repo"
      assert flat["queues"] == "default, ingest"
    end

    test "unexpected terms are inspected rather than crashing the report" do
      assert %{"pid" => "#PID" <> _} = Collector.flatten(%{pid: self()})
    end

    test "every value is JSON-encodable" do
      flat =
        Collector.flatten(%{
          a: 1,
          b: nil,
          c: %{d: self()},
          e: ~U[2026-08-03 12:00:00Z],
          f: [:x, :y]
        })

      assert {:ok, _} = Jason.encode(flat)
    end
  end

  describe "collect/0" do
    test "produces the shape the portal ingests" do
      payload = Collector.collect()

      assert is_binary(payload.version)
      assert is_binary(payload.timestamp)
      assert {:ok, _, _} = DateTime.from_iso8601(payload.timestamp)
      assert is_integer(payload.interval_seconds) and payload.interval_seconds > 0
      assert is_map(payload.checks)
      assert is_map(payload.system)
      assert is_map(payload.application)
    end

    test "the four charted system gauges are always present" do
      system = Collector.collect().system

      for key <- [:cpu_percent, :memory_percent, :disk_percent, :uptime_seconds] do
        assert Map.has_key?(system, key), "missing charted gauge #{key}"
      end
    end

    test "every check carries a status key" do
      # Ingest pattern-matches `%{"status" => status}` on each check, so an
      # entry without one is a 500 on the portal, not a degraded reading.
      for {name, check} <- Collector.collect().checks do
        assert Map.has_key?(check, :status), "check #{name} has no status"
        assert check.status in ~w(up degraded down)
      end
    end

    test "the application section is flat scalars only" do
      for {key, value} <- Collector.collect().application do
        assert is_binary(key)

        assert is_binary(value) or is_number(value) or is_boolean(value),
               "application.#{key} is not a scalar: #{inspect(value)}"
      end
    end

    test "the whole payload is JSON-encodable" do
      assert {:ok, json} = Jason.encode(Collector.collect())
      assert byte_size(json) > 0
    end
  end
end
