defmodule LemonMesh.WorktreeLease do
  @moduledoc """
  Typed lease for an agent-specific worktree allocation.
  """

  @type t :: %__MODULE__{
          agent_id: String.t() | nil,
          base_rev: String.t() | nil,
          worktree_path: String.t() | nil,
          sandbox_ref: String.t() | nil,
          lease_epoch: non_neg_integer(),
          origin_node_id: String.t() | nil,
          expires_at_ms: non_neg_integer() | nil,
          released_at_ms: non_neg_integer() | nil
        }

  defstruct [
    :agent_id,
    :base_rev,
    :worktree_path,
    :sandbox_ref,
    :origin_node_id,
    :expires_at_ms,
    :released_at_ms,
    lease_epoch: 0
  ]

  @spec new(keyword() | map()) :: t()
  def new(attrs \\ %{}) do
    attrs = normalize(attrs)

    %__MODULE__{
      agent_id: fetch(attrs, :agent_id),
      base_rev: fetch(attrs, :base_rev),
      worktree_path: fetch(attrs, :worktree_path),
      sandbox_ref: fetch(attrs, :sandbox_ref),
      lease_epoch: fetch(attrs, :lease_epoch, 0),
      origin_node_id: fetch(attrs, :origin_node_id),
      expires_at_ms: fetch(attrs, :expires_at_ms),
      released_at_ms: fetch(attrs, :released_at_ms)
    }
  end

  @spec active?(t(), non_neg_integer()) :: boolean()
  def active?(%__MODULE__{} = lease, now_ms \\ System.system_time(:millisecond)) do
    is_nil(lease.released_at_ms) and
      is_integer(lease.expires_at_ms) and
      lease.expires_at_ms > now_ms
  end

  defp normalize(attrs) when is_list(attrs), do: Enum.into(attrs, %{})
  defp normalize(attrs) when is_map(attrs), do: attrs

  defp fetch(attrs, key, default \\ nil) do
    Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key)) || default
  end
end
