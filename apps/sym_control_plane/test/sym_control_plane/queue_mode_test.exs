defmodule LemonControlPlane.QueueModeTest do
  use ExUnit.Case, async: true

  alias LemonControlPlane.QueueMode

  describe "parse/2" do
    test "falls back to collect defaults for agent/chat callers" do
      assert QueueMode.parse(nil, default: :collect) == :collect
      assert QueueMode.parse("invalid", default: :collect) == :collect
      assert QueueMode.parse(:invalid, default: :collect) == :collect
    end

    test "falls back to followup defaults for inbox/mesh callers" do
      assert QueueMode.parse(nil, default: :followup) == :followup
      assert QueueMode.parse("invalid", default: :followup) == :followup
      assert QueueMode.parse(:invalid, default: :followup) == :followup
    end

    test "respects allowed queue modes" do
      all_modes = [:collect, :followup, :steer, :steer_backlog, :interrupt]
      chat_modes = [:collect, :followup, :steer, :interrupt]

      assert QueueMode.parse("steer_backlog", default: :followup, allowed: all_modes) ==
               :steer_backlog

      assert QueueMode.parse("steer_backlog", default: :collect, allowed: chat_modes) ==
               :collect
    end
  end

  describe "label/2" do
    test "formats the normalized queue mode label" do
      assert QueueMode.label("steer", default: :followup) == "steer"
      assert QueueMode.label(:interrupt, default: :followup) == "interrupt"
    end

    test "uses the normalized default label for invalid values" do
      assert QueueMode.label("invalid", default: :followup) == "followup"
      assert QueueMode.label(nil, default: :collect) == "collect"
    end
  end
end
