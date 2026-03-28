defmodule CodingAgent.MeshBridge do
  @moduledoc false

  require Logger

  @spec append_task_event(String.t() | nil, String.t(), map(), keyword()) :: :ok
  def append_task_event(mesh_session_id, kind, body, opts \\ [])

  def append_task_event(nil, _kind, _body, _opts), do: :ok
  def append_task_event("", _kind, _body, _opts), do: :ok

  def append_task_event(mesh_session_id, kind, body, opts)
      when is_binary(mesh_session_id) and is_binary(kind) and is_map(body) do
    attrs = %{
      kind: kind,
      author: Keyword.get(opts, :author, "coding_agent"),
      scope: Keyword.get(opts, :scope, "mesh"),
      body: body,
      artifact_refs: List.wrap(Keyword.get(opts, :artifact_refs, [])),
      supersedes: List.wrap(Keyword.get(opts, :supersedes, []))
    }

    case LemonMesh.append_blackboard_entry(mesh_session_id, attrs) do
      {:ok, _entry} ->
        :ok

      {:error, :not_found} ->
        Logger.warning(
          "MeshBridge dropped task event for unknown mesh session #{mesh_session_id}"
        )

        :ok

      {:error, reason} ->
        Logger.warning(
          "MeshBridge failed to append task event kind=#{kind} mesh_session_id=#{mesh_session_id}: #{inspect(reason)}"
        )

        :ok
    end
  rescue
    error ->
      Logger.warning(
        "MeshBridge raised while appending task event kind=#{kind} mesh_session_id=#{mesh_session_id}: #{inspect(error)}"
      )

      :ok
  end
end
