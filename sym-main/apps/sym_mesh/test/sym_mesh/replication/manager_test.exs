defmodule LemonMesh.Replication.ManagerTest do
  use ExUnit.Case, async: false

  alias LemonCore.Event
  alias LemonCore.Store, as: CoreStore
  alias LemonMesh.Replication.Manager

  defmodule ConfigLoaderStub do
    use Agent

    def start_link(_opts) do
      Agent.start_link(
        fn ->
          %{
            trusted_peers: [],
            replication_poll_interval_ms: 25,
            replication_batch_limit: 10,
            snapshot_scope: "mesh_state",
            lease_ttl_ms: 60_000
          }
        end,
        name: __MODULE__
      )
    end

    def put(config), do: Agent.update(__MODULE__, fn _ -> config end)
    def get, do: Agent.get(__MODULE__, & &1)
  end

  defmodule PeerWorkerStub do
    use Agent

    def start_link(opts) do
      peer_id = Keyword.fetch!(opts, :peer_id)

      Agent.start_link(
        fn ->
          %{opts: opts}
        end,
        name: via(peer_id)
      )
    end

    def child_spec(opts) do
      %{
        id: {__MODULE__, Keyword.fetch!(opts, :peer_id)},
        start: {__MODULE__, :start_link, [opts]},
        restart: :temporary
      }
    end

    def status(pid) when is_pid(pid) do
      Agent.get(pid, fn state ->
        %{
          peer_id: Keyword.fetch!(state.opts, :peer_id),
          status: :idle,
          bootstrapped?: false,
          last_error: nil
        }
      end)
    end

    def via(peer_id), do: {:global, {__MODULE__, peer_id}}
  end

  setup do
    Application.ensure_all_started(:lemon_core)
    start_supervised!(ConfigLoaderStub)

    {:ok, worker_sup} =
      DynamicSupervisor.start_link(
        strategy: :one_for_one,
        name: :"replication_worker_sup_#{System.unique_integer([:positive])}"
      )

    LemonCore.Bus.subscribe("system")

    original_watermarks = CoreStore.list(:mesh_replication_watermarks)

    on_exit(fn ->
      LemonCore.Bus.unsubscribe("system")

      for {key, _value} <- CoreStore.list(:mesh_replication_watermarks) do
        CoreStore.delete(:mesh_replication_watermarks, key)
      end

      Enum.each(original_watermarks, fn {key, value} ->
        CoreStore.put(:mesh_replication_watermarks, key, value)
      end)
    end)

    %{worker_sup: worker_sup}
  end

  test "starts workers for trusted peers and reconciles on config reload events", %{
    worker_sup: worker_sup
  } do
    ConfigLoaderStub.put(%{
      trusted_peers: ["peer-a@host", "peer-b@host"],
      replication_poll_interval_ms: 25,
      replication_batch_limit: 10,
      snapshot_scope: "mesh_state",
      lease_ttl_ms: 60_000
    })

    {:ok, manager} =
      start_supervised(
        {Manager,
         name: :"replication_manager_#{System.unique_integer([:positive])}",
         config_loader: &ConfigLoaderStub.get/0,
         worker_supervisor: worker_sup,
         peer_worker_module: PeerWorkerStub}
      )

    wait_for(fn ->
      status = Manager.status(manager)

      MapSet.new(status.trusted_peers) == MapSet.new(["peer-a@host", "peer-b@host"]) and
        Enum.count(status.peers) == 2
    end)

    ConfigLoaderStub.put(%{
      trusted_peers: ["peer-b@host", "peer-c@host"],
      replication_poll_interval_ms: 25,
      replication_batch_limit: 10,
      snapshot_scope: "mesh_state",
      lease_ttl_ms: 60_000
    })

    LemonCore.Bus.broadcast("system", Event.new(:config_reloaded, %{reload_id: "mesh-reload"}))

    wait_for(fn ->
      status = Manager.status(manager)

      MapSet.new(status.trusted_peers) == MapSet.new(["peer-b@host", "peer-c@host"]) and
        MapSet.new(Enum.map(status.peers, & &1.peer_id)) ==
          MapSet.new(["peer-b@host", "peer-c@host"])
    end)
  end

  defp wait_for(fun, attempts \\ 50)

  defp wait_for(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(20)
      wait_for(fun, attempts - 1)
    end
  end

  defp wait_for(_fun, 0), do: flunk("condition not met in time")
end
