defmodule LemonMesh.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: LemonMesh.SessionRegistry},
      LemonMesh.ReplicationSupervisor,
      LemonMesh.HandoffReconciler,
      LemonMesh.SessionSupervisor,
      LemonMesh.Replication.Manager
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: LemonMesh.Supervisor)
  end
end
