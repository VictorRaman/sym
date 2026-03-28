defmodule LemonChannels.CapabilityQueryTest do
  use ExUnit.Case, async: false

  alias LemonChannels.CapabilityQuery

  # Mock plugin modules for testing
  defmodule MockTelegram do
    @behaviour LemonChannels.Plugin

    def id, do: "mock_telegram"

    def meta do
      %{
        label: "Mock Telegram",
        capabilities: %{
          edit_support: true,
          delete_support: true,
          chunk_limit: 4096,
          rate_limit: 30,
          voice_support: true,
          image_support: true,
          file_support: true,
          reaction_support: true,
          thread_support: true,
          rich_blocks: true
        }
      }
    end

    def child_spec(_opts) do
      %{id: __MODULE__, start: {Task, :start_link, [fn -> :ok end]}}
    end

    def normalize_inbound(_raw), do: {:ok, nil}
    def deliver(_payload), do: {:ok, :sent}
    def gateway_methods, do: []
  end

  defmodule MockXMTP do
    @behaviour LemonChannels.Plugin

    def id, do: "mock_xmtp"

    def meta do
      %{
        label: "Mock XMTP",
        capabilities: %{
          edit_support: false,
          delete_support: false,
          chunk_limit: 2000,
          voice_support: false,
          image_support: false,
          file_support: false,
          reaction_support: false,
          thread_support: true
        }
      }
    end

    def child_spec(_opts) do
      %{id: __MODULE__, start: {Task, :start_link, [fn -> :ok end]}}
    end

    def normalize_inbound(_raw), do: {:ok, nil}
    def deliver(_payload), do: {:ok, :sent}
    def gateway_methods, do: []
  end

  setup do
    # Register mock plugins for testing
    :ok = LemonChannels.Registry.register(MockTelegram)
    :ok = LemonChannels.Registry.register(MockXMTP)

    on_exit(fn ->
      LemonChannels.Registry.unregister("mock_telegram")
      LemonChannels.Registry.unregister("mock_xmtp")
    end)

    :ok
  end

  describe "supports?/2" do
    test "returns true for supported capabilities" do
      assert CapabilityQuery.supports?("mock_telegram", :threads)
      assert CapabilityQuery.supports?("mock_telegram", :attachments)
      assert CapabilityQuery.supports?("mock_telegram", :edit)
    end

    test "returns false for unsupported capabilities" do
      refute CapabilityQuery.supports?("mock_xmtp", :attachments)
      refute CapabilityQuery.supports?("mock_xmtp", :rich_blocks)
    end

    test "handles atom channel ids" do
      assert CapabilityQuery.supports?(:mock_telegram, :threads)
    end

    test "returns false for unknown channel" do
      refute CapabilityQuery.supports?("unknown_channel", :threads)
    end
  end

  describe "supports_feature?/3" do
    test "returns true for supported features" do
      # Telegram (via mock) has attachments with images feature
      assert CapabilityQuery.supports_feature?("mock_telegram", :attachments, :images)
    end

    test "returns false for unsupported features" do
      refute CapabilityQuery.supports_feature?("mock_xmtp", :attachments, :images)
    end

    test "returns false for unknown channel" do
      refute CapabilityQuery.supports_feature?("unknown", :attachments, :images)
    end
  end

  describe "validate/3" do
    test "returns ok for valid attachment" do
      assert :ok = CapabilityQuery.validate("mock_telegram", :attachments, %{size: 5_000_000})
    end

    test "returns error for oversized attachment" do
      # Telegram supports up to 20MB in the registry default
      assert {:error, _} = CapabilityQuery.validate("mock_telegram", :attachments, %{size: 50_000_000})
    end

    test "returns error for unsupported capability" do
      assert {:error, :capability_not_supported} =
               CapabilityQuery.validate("mock_xmtp", :attachments, %{size: 1000})
    end

    test "returns error for unknown channel" do
      assert {:error, :plugin_not_found} =
               CapabilityQuery.validate("unknown", :attachments, %{size: 1000})
    end
  end

  describe "get/2" do
    test "returns capability struct for supported capability" do
      cap = CapabilityQuery.get("mock_telegram", :threads)

      assert cap.type == :threads
      assert cap.enabled == true
    end

    test "returns nil for unsupported capability" do
      assert CapabilityQuery.get("mock_xmtp", :attachments) == nil
    end

    test "returns nil for unknown channel" do
      assert CapabilityQuery.get("unknown", :threads) == nil
    end
  end

  describe "fallback_for/2" do
    test "returns fallback for unsupported capability" do
      assert {:ok, {:text, _}} = CapabilityQuery.fallback_for("mock_xmtp", :rich_blocks)
    end

    test "returns error for unknown channel" do
      assert {:error, :channel_not_found} = CapabilityQuery.fallback_for("unknown", :rich_blocks)
    end
  end

  describe "compare/2" do
    test "compares capability across channels" do
      result = CapabilityQuery.compare(["mock_telegram", "mock_xmtp"], :attachments)

      assert result["mock_telegram"] == true
      assert result["mock_xmtp"] == false
    end

    test "handles atom channel ids" do
      result = CapabilityQuery.compare([:mock_telegram, :mock_xmtp], :threads)

      assert result["mock_telegram"] == true
      assert result["mock_xmtp"] == true
    end
  end

  describe "list/1" do
    test "lists all supported capabilities for a channel" do
      caps = CapabilityQuery.list("mock_telegram")

      assert :threads in caps
      assert :attachments in caps
      assert :edit in caps
    end

    test "returns empty list for unknown channel" do
      assert CapabilityQuery.list("unknown") == []
    end
  end

  describe "common/1" do
    test "returns intersection of capabilities" do
      common = CapabilityQuery.common(["mock_telegram", "mock_xmtp"])

      assert :threads in common
      # XMTP doesn't support attachments, so it shouldn't be in common
      refute :attachments in common
    end
  end

  describe "select_representation/2" do
    test "selects rich_blocks when supported" do
      representations = [
        {:rich_blocks, [%{type: :section}]},
        {:text, "Hello"}
      ]

      assert {:rich_blocks, _} =
               CapabilityQuery.select_representation("mock_telegram", representations)
    end

    test "falls back to text when rich_blocks not supported" do
      representations = [
        {:rich_blocks, [%{type: :section}]},
        {:text, "Hello"}
      ]

      assert {:text, "Hello"} =
               CapabilityQuery.select_representation("mock_xmtp", representations)
    end

    test "returns nil when no representation matches" do
      representations = [
        {:streaming, "data"}
      ]

      assert CapabilityQuery.select_representation("mock_telegram", representations) == nil
    end
  end

  describe "all/0" do
    test "returns capabilities for all registered channels" do
      all = CapabilityQuery.all()

      telegram = Enum.find(all, fn info -> info.channel_id == "mock_telegram" end)
      xmtp = Enum.find(all, fn info -> info.channel_id == "mock_xmtp" end)

      assert telegram != nil
      assert :threads in telegram.supports
      assert :attachments in telegram.supports

      assert xmtp != nil
      assert :threads in xmtp.supports
      refute :attachments in xmtp.supports
    end
  end
end
