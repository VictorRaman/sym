defmodule LemonMesh.CausalClockTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias LemonMesh.CausalClock

  test "tick increments a node counter" do
    clock =
      CausalClock.new()
      |> CausalClock.tick("node-a")
      |> CausalClock.tick("node-a")

    assert CausalClock.get(clock, "node-a") == 2
    assert CausalClock.get(clock, "node-b") == 0
  end

  test "merge takes the component-wise maximum" do
    left =
      CausalClock.new(%{"node-a" => 2})

    right =
      CausalClock.new(%{"node-a" => 1, "node-b" => 1})

    merged = CausalClock.merge(left, right)

    assert CausalClock.to_map(merged) == %{"node-a" => 2, "node-b" => 1}
  end

  test "compare returns before, after, equal, and concurrent" do
    base = CausalClock.new()
    after_a = CausalClock.tick(base, "node-a")
    after_b = CausalClock.tick(base, "node-b")

    assert CausalClock.compare(base, after_a) == :before
    assert CausalClock.compare(after_a, base) == :after
    assert CausalClock.compare(after_a, after_a) == :equal
    assert CausalClock.compare(after_a, after_b) == :concurrent
  end

  property "merge is commutative, associative, and idempotent for arbitrary clocks" do
    check all(
            left <- clock_map(),
            right <- clock_map(),
            extra <- clock_map()
          ) do
      left_clock = CausalClock.new(left)
      right_clock = CausalClock.new(right)
      extra_clock = CausalClock.new(extra)

      assert CausalClock.to_map(CausalClock.merge(left_clock, right_clock)) ==
               CausalClock.to_map(CausalClock.merge(right_clock, left_clock))

      assert CausalClock.to_map(CausalClock.merge(left_clock, left_clock)) ==
               CausalClock.to_map(left_clock)

      assert CausalClock.to_map(
               CausalClock.merge(CausalClock.merge(left_clock, right_clock), extra_clock)
             ) ==
               CausalClock.to_map(
                 CausalClock.merge(left_clock, CausalClock.merge(right_clock, extra_clock))
               )
    end
  end

  defp clock_map do
    StreamData.map_of(
      StreamData.string(:alphanumeric, min_length: 1, max_length: 6),
      StreamData.integer(0..8),
      max_length: 4
    )
  end
end
