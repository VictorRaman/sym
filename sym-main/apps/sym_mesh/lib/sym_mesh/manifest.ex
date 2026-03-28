defmodule LemonMesh.Manifest do
  @moduledoc """
  Typed manifest for a Lemon Mesh session.
  """

  alias LemonCore.Id
  alias LemonMesh.SharedFileDescriptor

  @type t :: %__MODULE__{
          session_id: String.t(),
          goal: String.t() | nil,
          roles: [String.t()],
          peer_graph: map(),
          shared_files: [SharedFileDescriptor.t() | map()],
          memory_scopes: [String.t()],
          delivery_semantics: String.t(),
          metadata: map(),
          inserted_at_ms: non_neg_integer()
        }

  defstruct [
    :session_id,
    :goal,
    roles: [],
    peer_graph: %{},
    shared_files: [],
    memory_scopes: [],
    delivery_semantics: "at_least_once",
    metadata: %{},
    inserted_at_ms: 0
  ]

  @spec new(keyword() | map()) :: t()
  def new(attrs \\ %{}) do
    attrs = normalize(attrs)

    shared_files =
      attrs
      |> fetch(:shared_files, [])
      |> Enum.map(&SharedFileDescriptor.new/1)

    %__MODULE__{
      session_id: fetch(attrs, :session_id, "mesh_#{Id.uuid()}"),
      goal: fetch(attrs, :goal),
      roles: normalize_string_list(fetch(attrs, :roles, [])),
      peer_graph: fetch(attrs, :peer_graph, %{}),
      shared_files: shared_files,
      memory_scopes: normalize_string_list(fetch(attrs, :memory_scopes, [])),
      delivery_semantics: fetch(attrs, :delivery_semantics, "at_least_once"),
      metadata: fetch(attrs, :metadata, %{}),
      inserted_at_ms: fetch(attrs, :inserted_at_ms, System.system_time(:millisecond))
    }
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = manifest) do
    %{
      session_id: manifest.session_id,
      goal: manifest.goal,
      roles: manifest.roles,
      peer_graph: manifest.peer_graph,
      shared_files: Enum.map(manifest.shared_files, &Map.from_struct/1),
      memory_scopes: manifest.memory_scopes,
      delivery_semantics: manifest.delivery_semantics,
      metadata: manifest.metadata,
      inserted_at_ms: manifest.inserted_at_ms
    }
  end

  defp normalize(attrs) when is_list(attrs), do: Enum.into(attrs, %{})
  defp normalize(attrs) when is_map(attrs), do: attrs

  defp fetch(attrs, key, default \\ nil) do
    cond do
      Map.has_key?(attrs, key) -> Map.get(attrs, key)
      Map.has_key?(attrs, Atom.to_string(key)) -> Map.get(attrs, Atom.to_string(key))
      true -> default
    end
  end

  defp normalize_string_list(values) when is_list(values), do: Enum.map(values, &normalize_string_item/1)
  defp normalize_string_list(nil), do: []
  defp normalize_string_list(value), do: [normalize_string_item(value)]

  defp normalize_string_item(%{} = value) do
    Map.get(value, :id) || Map.get(value, "id") || inspect(value)
  end

  defp normalize_string_item(value), do: to_string(value)
end
