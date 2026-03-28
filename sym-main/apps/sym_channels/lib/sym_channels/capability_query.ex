defmodule LemonChannels.CapabilityQuery do
  @moduledoc """
  Query API for channel capabilities.

  Provides a clean interface for tools to query channel capabilities
  and determine how to render content for different channels.

  ## Usage

      # Check if a channel supports a capability
      CapabilityQuery.supports?("telegram", :attachments)
      # => true

      # Check for specific features
      CapabilityQuery.supports_feature?("discord", :rich_blocks, :markdown)
      # => true

      # Validate before sending
      CapabilityQuery.validate("telegram", :attachments, %{size: 5_000_000})
      # => :ok

      # Get fallback strategy
      CapabilityQuery.fallback_for("xmtp", :rich_blocks)
      # => {:ok, {:text, "[Rich content not supported]"}}

      # Compare capabilities across channels
      CapabilityQuery.compare(["telegram", "discord", "xmtp"], :attachments)
      # => %{"telegram" => true, "discord" => true, "xmtp" => false}
  """

  alias LemonChannels.{Capabilities, Registry}

  @doc """
  Checks if a channel supports a specific capability.

  ## Examples

      CapabilityQuery.supports?("telegram", :attachments)
      # => true

      CapabilityQuery.supports?("xmtp", :attachments)
      # => false
  """
  @spec supports?(String.t() | atom(), atom()) :: boolean()
  def supports?(channel_id, capability_type) do
    channel_id
    |> to_string()
    |> Registry.supports?(capability_type)
  end

  @doc """
  Checks if a channel supports a specific feature within a capability.

  ## Examples

      CapabilityQuery.supports_feature?("telegram", :rich_blocks, :markdown)
      # => true

      CapabilityQuery.supports_feature?("discord", :rich_blocks, :buttons)
      # => false
  """
  @spec supports_feature?(String.t() | atom(), atom(), atom()) :: boolean()
  def supports_feature?(channel_id, capability_type, feature) do
    channel_id
    |> to_string()
    |> Registry.supports_feature?(capability_type, feature)
  end

  @doc """
  Validates a capability request against a channel's capabilities.

  ## Examples

      CapabilityQuery.validate("telegram", :attachments, %{size: 5_000_000})
      # => :ok

      CapabilityQuery.validate("telegram", :attachments, %{size: 50_000_000})
      # => {:error, :file_too_large}
  """
  @spec validate(String.t() | atom(), atom(), map()) :: :ok | {:error, term()}
  def validate(channel_id, capability_type, params) do
    channel_id
    |> to_string()
    |> Registry.validate(capability_type, params)
  end

  @doc """
  Gets a capability's full configuration for a channel.

  ## Examples

      CapabilityQuery.get("telegram", :attachments)
      # => %Capability{type: :attachments, enabled: true, config: %{max_size: 20000000}}
  """
  @spec get(String.t() | atom(), atom()) :: Capabilities.Capability.t() | nil
  def get(channel_id, capability_type) do
    channel_id
    |> to_string()
    |> Registry.get_capabilities_new()
    |> case do
      nil -> nil
      caps -> Capabilities.get(caps, capability_type)
    end
  end

  @doc """
  Returns suggested fallback options for unsupported capabilities.

  ## Examples

      CapabilityQuery.fallback_for("xmtp", :rich_blocks)
      # => {:ok, {:text, "[Rich content not supported]"}}
  """
  @spec fallback_for(String.t() | atom(), atom()) :: {:ok, term()} | {:error, :no_fallback}
  def fallback_for(channel_id, capability_type) do
    caps =
      channel_id
      |> to_string()
      |> Registry.get_capabilities_new()

    case caps do
      nil -> {:error, :channel_not_found}
      caps -> Capabilities.fallback_for(caps, capability_type)
    end
  end

  @doc """
  Compares a capability across multiple channels.

  ## Examples

      CapabilityQuery.compare(["telegram", "discord", "xmtp"], :attachments)
      # => %{"telegram" => true, "discord" => true, "xmtp" => false}
  """
  @spec compare([String.t() | atom()], atom()) :: %{String.t() => boolean()}
  def compare(channel_ids, capability_type) do
    channel_ids
    |> Enum.map(fn id ->
      {to_string(id), supports?(id, capability_type)}
    end)
    |> Map.new()
  end

  @doc """
  Lists all supported capabilities for a channel.

  ## Examples

      CapabilityQuery.list("telegram")
      # => [:attachments, :rich_blocks, :threads, :reactions, :edit, :delete, :voice]
  """
  @spec list(String.t() | atom()) :: [atom()]
  def list(channel_id) do
    channel_id
    |> to_string()
    |> Registry.get_capabilities_new()
    |> case do
      nil -> []
      caps -> Capabilities.list(caps)
    end
  end

  @doc """
  Gets the intersection of capabilities across multiple channels.

  Returns the set of capabilities that ALL channels support.

  ## Examples

      CapabilityQuery.common(["telegram", "discord"])
      # => [:threads, :edit, :delete, :attachments]
  """
  @spec common([String.t() | atom()]) :: [atom()]
  def common(channel_ids) do
    channel_ids
    |> Enum.map(&list/1)
    |> intersection()
  end

  @doc """
  Selects the best representation for content based on channel capabilities.

  ## Examples

      CapabilityQuery.select_representation("telegram", [
        {:rich_blocks, [%{type: :section, text: "Hello"}]},
        {:text, "Hello"}
      ])
      # => {:rich_blocks, [%{type: :section, text: "Hello"}]}

      CapabilityQuery.select_representation("xmtp", [
        {:rich_blocks, [%{type: :section, text: "Hello"}]},
        {:text, "Hello"}
      ])
      # => {:text, "Hello"}
  """
  @spec select_representation(String.t() | atom(), [{atom(), term()}]) ::
          {atom(), term()} | nil
  def select_representation(channel_id, representations) do
    Enum.find(representations, fn {type, _content} ->
      case type do
        :rich_blocks -> supports?(channel_id, :rich_blocks)
        :attachments -> supports?(channel_id, :attachments)
        :streaming -> supports?(channel_id, :streaming)
        :text -> true
        _ -> false
      end
    end)
  end

  @doc """
  Returns capability information for all registered channels.

  ## Examples

      CapabilityQuery.all()
      # => [
      #   %{channel_id: "telegram", supports: [:threads, :reactions, ...]},
      #   %{channel_id: "discord", supports: [:threads, :edit, ...]}
      # ]
  """
  @spec all() :: [%{channel_id: String.t(), supports: [atom()], capabilities: map()}]
  def all do
    Registry.list()
    |> Enum.map(fn {channel_id, info} ->
      # Get capabilities from registry and convert from legacy format if needed
      caps =
        case info[:capabilities_v2] do
          nil ->
            # Fall back to legacy capabilities and convert
            legacy = info[:capabilities] || %{}
            Capabilities.from_legacy(legacy)

          caps_v2 ->
            caps_v2
        end

      %{
        channel_id: channel_id,
        supports: Capabilities.list(caps),
        capabilities: caps
      }
    end)
  end

  # Private functions

  defp intersection([]), do: []
  defp intersection([head | tail]), do: Enum.reduce(tail, head, &Enum.filter(&2, fn x -> x in &1 end))
end
