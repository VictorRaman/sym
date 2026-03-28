defmodule LemonMesh.CrdtTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias LemonMesh.Crdt.{GCounter, GSet, LwwRegister, OrMap, PNCounter}

  test "gcounter merge is commutative and idempotent" do
    left = GCounter.increment(GCounter.new(), "node-a", 5)
    right = GCounter.increment(GCounter.new(), "node-b", 3)

    assert GCounter.value(GCounter.merge(left, right)) == 8

    assert GCounter.to_map(GCounter.merge(left, right)) ==
             GCounter.to_map(GCounter.merge(right, left))

    assert GCounter.to_map(GCounter.merge(left, left)) == GCounter.to_map(left)
  end

  test "pncounter preserves increments and decrements across merge" do
    left =
      PNCounter.new()
      |> PNCounter.increment("node-a", 10)
      |> PNCounter.decrement("node-a", 3)

    right = PNCounter.increment(PNCounter.new(), "node-b", 5)

    assert PNCounter.value(PNCounter.merge(left, right)) == 12
  end

  test "gset merges by union" do
    left =
      GSet.new()
      |> GSet.insert("rag")
      |> GSet.insert("reasoning")

    right =
      GSet.new()
      |> GSet.insert("reasoning")
      |> GSet.insert("tool-use")

    merged = GSet.merge(left, right)

    assert GSet.contains?(merged, "rag")
    assert GSet.contains?(merged, "reasoning")
    assert GSet.contains?(merged, "tool-use")
    assert GSet.len(merged) == 3
  end

  test "lww register breaks timestamp ties by writer for deterministic merge" do
    left = LwwRegister.write(LwwRegister.new(), "model-a", 10, "node-a")
    right = LwwRegister.write(LwwRegister.new(), "model-b", 10, "node-b")

    merged = LwwRegister.merge(left, right)

    assert LwwRegister.read(merged) == "model-b"
    assert LwwRegister.read(LwwRegister.merge(right, left)) == "model-b"
  end

  test "or_map uses lww semantics per key" do
    left = OrMap.set(OrMap.new(), "model", "gpt-4", 1, "node-a")
    right = OrMap.set(OrMap.new(), "model", "claude-3", 5, "node-b")

    merged = OrMap.merge(left, right)

    assert OrMap.get(merged, "model") == "claude-3"
    assert OrMap.len(merged) == 1
  end

  property "gcounter merge laws hold for arbitrary states" do
    check all(
            left <- counter_map(),
            right <- counter_map(),
            extra <- counter_map()
          ) do
      left_counter = GCounter.new(left)
      right_counter = GCounter.new(right)
      extra_counter = GCounter.new(extra)

      assert GCounter.to_map(GCounter.merge(left_counter, right_counter)) ==
               GCounter.to_map(GCounter.merge(right_counter, left_counter))

      assert GCounter.to_map(GCounter.merge(left_counter, left_counter)) ==
               GCounter.to_map(left_counter)

      assert GCounter.to_map(
               GCounter.merge(GCounter.merge(left_counter, right_counter), extra_counter)
             ) ==
               GCounter.to_map(
                 GCounter.merge(left_counter, GCounter.merge(right_counter, extra_counter))
               )
    end
  end

  property "pncounter merge laws hold for arbitrary states" do
    check all(
            left <- pn_counter_map(),
            right <- pn_counter_map(),
            extra <- pn_counter_map()
          ) do
      left_counter = PNCounter.new(left)
      right_counter = PNCounter.new(right)
      extra_counter = PNCounter.new(extra)

      assert PNCounter.to_map(PNCounter.merge(left_counter, right_counter)) ==
               PNCounter.to_map(PNCounter.merge(right_counter, left_counter))

      assert PNCounter.to_map(PNCounter.merge(left_counter, left_counter)) ==
               PNCounter.to_map(left_counter)

      assert PNCounter.to_map(
               PNCounter.merge(PNCounter.merge(left_counter, right_counter), extra_counter)
             ) ==
               PNCounter.to_map(
                 PNCounter.merge(left_counter, PNCounter.merge(right_counter, extra_counter))
               )
    end
  end

  property "gset merge laws hold for arbitrary states" do
    check all(
            left <- string_set(),
            right <- string_set(),
            extra <- string_set()
          ) do
      left_set = GSet.new(left)
      right_set = GSet.new(right)
      extra_set = GSet.new(extra)

      assert GSet.to_list(GSet.merge(left_set, right_set)) ==
               GSet.to_list(GSet.merge(right_set, left_set))

      assert GSet.to_list(GSet.merge(left_set, left_set)) == GSet.to_list(left_set)

      assert GSet.to_list(GSet.merge(GSet.merge(left_set, right_set), extra_set)) ==
               GSet.to_list(GSet.merge(left_set, GSet.merge(right_set, extra_set)))
    end
  end

  property "lww register merge is deterministic and idempotent" do
    check all(
            left <- lww_register_input(),
            right <- lww_register_input(),
            extra <- lww_register_input()
          ) do
      left_register = LwwRegister.new(left)
      right_register = LwwRegister.new(right)
      extra_register = LwwRegister.new(extra)

      assert Map.from_struct(LwwRegister.merge(left_register, right_register)) ==
               Map.from_struct(LwwRegister.merge(right_register, left_register))

      assert Map.from_struct(LwwRegister.merge(left_register, left_register)) ==
               Map.from_struct(left_register)

      assert Map.from_struct(
               LwwRegister.merge(LwwRegister.merge(left_register, right_register), extra_register)
             ) ==
               Map.from_struct(
                 LwwRegister.merge(
                   left_register,
                   LwwRegister.merge(right_register, extra_register)
                 )
               )
    end
  end

  property "or_map merge is deterministic and associative" do
    check all(
            left <- or_map_input(),
            right <- or_map_input(),
            extra <- or_map_input()
          ) do
      left_map = OrMap.new(left)
      right_map = OrMap.new(right)
      extra_map = OrMap.new(extra)

      assert OrMap.to_map(OrMap.merge(left_map, right_map)) ==
               OrMap.to_map(OrMap.merge(right_map, left_map))

      assert OrMap.to_map(OrMap.merge(left_map, left_map)) == OrMap.to_map(left_map)

      assert OrMap.to_map(OrMap.merge(OrMap.merge(left_map, right_map), extra_map)) ==
               OrMap.to_map(OrMap.merge(left_map, OrMap.merge(right_map, extra_map)))
    end
  end

  defp counter_map do
    StreamData.map_of(
      StreamData.string(:alphanumeric, min_length: 1, max_length: 6),
      StreamData.integer(0..20),
      max_length: 4
    )
  end

  defp pn_counter_map do
    StreamData.fixed_map(%{
      increments: counter_map(),
      decrements: counter_map()
    })
  end

  defp string_set do
    StreamData.uniq_list_of(
      StreamData.string(:alphanumeric, min_length: 1, max_length: 8),
      max_length: 5
    )
  end

  defp lww_register_input do
    StreamData.fixed_map(%{
      value: StreamData.string(:alphanumeric, min_length: 0, max_length: 12),
      timestamp: StreamData.integer(0..20),
      writer: StreamData.string(:alphanumeric, min_length: 1, max_length: 6)
    })
  end

  defp or_map_input do
    register =
      StreamData.fixed_map(%{
        value: StreamData.string(:alphanumeric, min_length: 0, max_length: 12),
        timestamp: StreamData.integer(0..20),
        writer: StreamData.string(:alphanumeric, min_length: 1, max_length: 6)
      })

    StreamData.map_of(
      StreamData.string(:alphanumeric, min_length: 1, max_length: 6),
      register,
      max_length: 4
    )
  end
end
