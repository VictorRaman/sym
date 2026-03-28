defmodule LemonMesh.SessionRegistry do
  @moduledoc """
  Registry wrapper for active Lemon Mesh sessions.
  """

  @registry_name __MODULE__

  @spec via(String.t()) :: {:via, Registry, {atom(), String.t()}}
  def via(session_id) when is_binary(session_id) do
    {:via, Registry, {@registry_name, session_id}}
  end

  @spec lookup(String.t()) :: {:ok, pid()} | :error
  def lookup(session_id) when is_binary(session_id) do
    case Registry.lookup(@registry_name, session_id) do
      [{pid, _metadata}] -> {:ok, pid}
      [] -> :error
    end
  end

  @spec list_ids() :: [String.t()]
  def list_ids do
    Registry.select(@registry_name, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end
end

