defmodule LemonChannels do
  @moduledoc """
  Compatibility facade for the absorbed channel-delivery subsystem inside
  `:lemon_gateway`.

  `LemonChannels.*` remains the public module namespace for channel plugins and
  delivery helpers, but it is no longer a standalone umbrella app. The
  implementation lives under `apps/lemon_gateway/lib/lemon_channels/`.

  This subsystem is responsible for:

  - Channel plugin registration and discovery
  - Outbound message delivery with retry and rate limiting
  - Deduplication to prevent duplicate messages
  - Chunking for long messages
  - Telegram adapter (and future channel adapters)

  ## Architecture

  ```
  [Router] -> [Outbox] -> [Plugin] -> [External Channel]
                 |
                 v
            [Dedupe/RateLimit/Chunker]
  ```

  ## Plugin System

  Channels are implemented as plugins that implement the `LemonChannels.Plugin`
  behaviour. Each plugin provides:

  - `normalize_inbound/1` - Convert raw channel data to InboundMessage
  - `deliver/1` - Send outbound payloads to the channel
  - `gateway_methods/0` - Control plane methods for the channel
  """

  alias LemonChannels.{Outbox, Registry}

  @doc """
  Get a registered channel plugin by ID.
  """
  defdelegate get_plugin(id), to: Registry

  @doc """
  List all registered channel plugins.
  """
  defdelegate list_plugins(), to: Registry

  @doc """
  Enqueue an outbound payload for delivery.
  """
  defdelegate enqueue(payload), to: Outbox
end
