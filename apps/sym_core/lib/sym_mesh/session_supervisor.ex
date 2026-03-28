defmodule LemonMesh.SessionSupervisor do
  @moduledoc """
  DynamicSupervisor for mesh session processes.
  """

  use DynamicSupervisor

  alias LemonMesh.{Manifest, Session, Store}

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    DynamicSupervisor.start_link(__MODULE__, :ok, name: name)
  end

  @impl true
  def init(:ok) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @spec start_session(keyword() | map()) :: DynamicSupervisor.on_start_child()
  def start_session(attrs) do
    manifest = normalize_manifest(attrs)

    child_spec = %{
      id: {LemonMesh.Session, make_ref()},
      start: {LemonMesh.Session, :start_link, [manifest]},
      restart: :transient,
      shutdown: 5_000,
      type: :worker
    }

    DynamicSupervisor.start_child(__MODULE__, child_spec)
  end

  @spec restore_session(map()) :: DynamicSupervisor.on_start_child()
  def restore_session(snapshot) when is_map(snapshot) do
    start_session(Map.put(snapshot, :session_id, snapshot[:session_id] || snapshot["session_id"]))
  end

  @spec stop_session(pid()) :: :ok | {:error, term()}
  def stop_session(pid) when is_pid(pid) do
    persist_stopped_snapshot(pid)
    GenServer.stop(pid, :normal, 5_000)
  end

  @spec list_sessions() :: [pid()]
  def list_sessions do
    if Process.whereis(__MODULE__) do
      DynamicSupervisor.which_children(__MODULE__)
      |> Enum.flat_map(fn
        {_id, pid, :worker, _modules} when is_pid(pid) -> [pid]
        _ -> []
      end)
    else
      []
    end
  end

  defp normalize_manifest(%Manifest{} = manifest), do: manifest
  defp normalize_manifest(attrs), do: Manifest.new(attrs)

  defp persist_stopped_snapshot(pid) do
    manifest = Session.manifest(pid)
    blackboard = Session.list_blackboard(pid)

    Store.upsert_session(manifest,
      status: :stopped,
      blackboard_size: length(blackboard),
      updated_at_ms: System.system_time(:millisecond)
    )
    :ok
  rescue
    _ -> :ok
  end
end
