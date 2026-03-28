defmodule LemonMesh.SharedFileDescriptor do
  @moduledoc """
  Typed descriptor for files that may be shared by a mesh session.
  """

  @type t :: %__MODULE__{
          path: String.t() | nil,
          file_kind: String.t(),
          merge_mode: String.t(),
          validator: String.t() | nil,
          owners: [String.t()],
          shared: boolean()
        }

  defstruct [
    :path,
    file_kind: "text",
    merge_mode: "manual",
    validator: nil,
    owners: [],
    shared: true
  ]

  @spec new(keyword() | map()) :: t()
  def new(attrs \\ %{}) do
    attrs = normalize(attrs)

    %__MODULE__{
      path: fetch(attrs, :path),
      file_kind: fetch(attrs, :file_kind, "text", "fileKind"),
      merge_mode: fetch(attrs, :merge_mode, "manual", "mergeMode"),
      validator: fetch(attrs, :validator),
      owners: normalize_string_list(fetch(attrs, :owners, [])),
      shared: fetch(attrs, :shared, true)
    }
  end

  defp normalize(attrs) when is_list(attrs), do: Enum.into(attrs, %{})
  defp normalize(attrs) when is_map(attrs), do: attrs

  defp fetch(attrs, key, default \\ nil, alt_key \\ nil) do
    cond do
      Map.has_key?(attrs, key) -> Map.get(attrs, key)
      Map.has_key?(attrs, Atom.to_string(key)) -> Map.get(attrs, Atom.to_string(key))
      is_binary(alt_key) and Map.has_key?(attrs, alt_key) -> Map.get(attrs, alt_key)
      true -> default
    end
  end

  defp normalize_string_list(values) when is_list(values), do: Enum.map(values, &to_string/1)
  defp normalize_string_list(nil), do: []
  defp normalize_string_list(value), do: [to_string(value)]
end
