defmodule LemonMesh.Session do
  @moduledoc """
  GenServer owning one mesh session manifest and its BEAM-local blackboard.
  """

  use GenServer, restart: :transient

  alias LemonMesh.{BlackboardEntry, Manifest, SessionRegistry, Store}

  defstruct [
    :manifest,
    blackboard: [],
    status: :active,
    updated_at_ms: 0
  ]

  @type t :: %__MODULE__{
          manifest: Manifest.t(),
          blackboard: [BlackboardEntry.t()],
          status: atom(),
          updated_at_ms: non_neg_integer()
        }

  @spec start_link(Manifest.t() | keyword() | map()) :: GenServer.on_start()
  def start_link(attrs \\ %{})

  def start_link(%Manifest{} = manifest) do
    GenServer.start_link(__MODULE__, manifest, name: SessionRegistry.via(manifest.session_id))
  end

  def start_link(attrs) do
    attrs = normalize(attrs)
    register? = Map.get(attrs, :register, true)
    manifest = Manifest.new(Map.delete(attrs, :register))

    opts =
      if register? do
        [name: SessionRegistry.via(manifest.session_id)]
      else
        []
      end

    GenServer.start_link(__MODULE__, manifest, opts)
  end

  @spec session_id(pid()) :: String.t()
  def session_id(pid) when is_pid(pid) do
    GenServer.call(pid, :session_id)
  end

  @spec snapshot(pid()) :: map()
  def snapshot(pid) when is_pid(pid) do
    GenServer.call(pid, :snapshot)
  end

  @spec manifest(pid()) :: Manifest.t()
  def manifest(pid) when is_pid(pid) do
    GenServer.call(pid, :manifest)
  end

  @spec append_blackboard_entry(pid(), keyword() | map()) ::
          {:ok, BlackboardEntry.t()}
  def append_blackboard_entry(pid, attrs) when is_pid(pid) do
    GenServer.call(pid, {:append_blackboard_entry, attrs})
  end

  @spec list_blackboard(pid()) :: [BlackboardEntry.t()]
  def list_blackboard(pid) when is_pid(pid) do
    GenServer.call(pid, :list_blackboard)
  end

  @impl true
  def init(%Manifest{} = manifest) do
    blackboard = Store.list_blackboard_entries(manifest.session_id)
    restored_snapshot = Store.get_session(manifest.session_id)

    state =
      %__MODULE__{
        manifest: manifest,
        blackboard: blackboard,
        status: :active,
        updated_at_ms: restored_snapshot && restored_snapshot.updated_at_ms || manifest.inserted_at_ms
      }
      |> persist_state()

    {:ok, state}
  end

  @impl true
  def handle_call(:session_id, _from, state) do
    {:reply, state.manifest.session_id, state}
  end

  def handle_call(:snapshot, _from, state) do
    {:reply, snapshot_from_state(state), state}
  end

  def handle_call(:manifest, _from, state) do
    {:reply, state.manifest, state}
  end

  def handle_call(:list_blackboard, _from, state) do
    {:reply, Store.list_blackboard_entries(state.manifest.session_id), state}
  end

  def handle_call({:append_blackboard_entry, attrs}, _from, state) do
    case Store.append_blackboard_entry(state.manifest.session_id, attrs) do
      {:ok, entry} ->
        blackboard = Store.list_blackboard_entries(state.manifest.session_id)
        next_state = %{state | blackboard: blackboard, updated_at_ms: entry.inserted_at_ms}
        {:reply, {:ok, entry}, next_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def terminate(reason, state) do
    persist_terminal_state(state, normalize_terminal_status(reason))
    :ok
  end

  defp persist_state(state, updated_at_ms \\ System.system_time(:millisecond)) do
    state = %{state | updated_at_ms: updated_at_ms}
    blackboard_size = current_blackboard_size(state)

    Store.upsert_session(state.manifest,
      status: state.status,
      blackboard_size: blackboard_size,
      updated_at_ms: state.updated_at_ms
    )

    state
  end

  defp persist_terminal_state(state, status) do
    updated_at_ms = System.system_time(:millisecond)
    blackboard_size = current_blackboard_size(state)

    Store.upsert_session(state.manifest,
      status: status,
      blackboard_size: blackboard_size,
      updated_at_ms: updated_at_ms
    )
  end

  defp snapshot_from_state(state) do
    blackboard_size = current_blackboard_size(state)

    %{
      session_id: state.manifest.session_id,
      goal: state.manifest.goal,
      roles: state.manifest.roles,
      peer_graph: state.manifest.peer_graph,
      shared_files: Enum.map(state.manifest.shared_files, &Map.from_struct/1),
      memory_scopes: state.manifest.memory_scopes,
      delivery_semantics: state.manifest.delivery_semantics,
      metadata: state.manifest.metadata,
      status: state.status,
      blackboard_size: blackboard_size,
      inserted_at_ms: state.manifest.inserted_at_ms,
      updated_at_ms: state.updated_at_ms
    }
  end

  defp current_blackboard_size(state) do
    state.manifest.session_id
    |> Store.list_blackboard_entries()
    |> length()
  end

  defp normalize_terminal_status(reason) do
    case reason do
      :normal -> :stopped
      :shutdown -> :stopped
      {:shutdown, _} -> :stopped
      _ -> :crashed
    end
  end

  defp normalize(attrs) when is_list(attrs), do: Enum.into(attrs, %{})
  defp normalize(attrs) when is_map(attrs), do: attrs
end
