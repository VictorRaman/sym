defmodule LemonMesh.BlackboardEntry do
  @moduledoc """
  Typed blackboard entry for shared mesh memory.
  """

  alias LemonCore.Id

  @type t :: %__MODULE__{
          entry_id: String.t(),
          session_id: String.t(),
          kind: String.t(),
          author: String.t() | nil,
          scope: String.t() | nil,
          body: term(),
          clock: map(),
          supersedes: [String.t()],
          artifact_refs: [String.t()],
          inserted_at_ms: non_neg_integer()
        }

  defstruct [
    :entry_id,
    :session_id,
    :kind,
    :author,
    :scope,
    body: %{},
    clock: %{},
    supersedes: [],
    artifact_refs: [],
    inserted_at_ms: 0
  ]

  @spec new(String.t(), keyword() | map()) :: t()
  def new(session_id, attrs) when is_binary(session_id) do
    attrs = normalize(attrs)

    %__MODULE__{
      entry_id: fetch(attrs, :entry_id, "bb_#{Id.uuid()}"),
      session_id: session_id,
      kind: fetch(attrs, :kind, "note"),
      author: fetch(attrs, :author),
      scope: fetch(attrs, :scope),
      body: fetch(attrs, :body, %{}),
      clock: fetch(attrs, :clock, %{}),
      supersedes: normalize_string_list(fetch(attrs, :supersedes, [])),
      artifact_refs: normalize_string_list(fetch(attrs, :artifact_refs, [])),
      inserted_at_ms: fetch(attrs, :inserted_at_ms, System.system_time(:millisecond))
    }
  end

  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    new(fetch(map, :session_id), map)
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = entry) do
    %{
      entry_id: entry.entry_id,
      session_id: entry.session_id,
      kind: entry.kind,
      author: entry.author,
      scope: entry.scope,
      body: entry.body,
      clock: entry.clock,
      supersedes: entry.supersedes,
      artifact_refs: entry.artifact_refs,
      inserted_at_ms: entry.inserted_at_ms
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

  defp normalize_string_list(values) when is_list(values), do: Enum.map(values, &to_string/1)
  defp normalize_string_list(nil), do: []
  defp normalize_string_list(value), do: [to_string(value)]
end
