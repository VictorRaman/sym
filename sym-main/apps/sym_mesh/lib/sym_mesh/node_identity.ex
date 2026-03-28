defmodule LemonMesh.NodeIdentity do
  @moduledoc false

  @spec current_node_id() :: String.t()
  def current_node_id do
    configured =
      Application.get_env(:lemon_mesh, :node_id) ||
        System.get_env("LEMON_NODE_ID")

    cond do
      is_binary(configured) and String.trim(configured) != "" ->
        String.trim(configured)

      node() != :nonode@nohost ->
        to_string(node())

      true ->
        hostname = current_hostname()
        "nonode:" <> hostname
    end
  end

  defp current_hostname do
    case :inet.gethostname() do
      {:ok, value} -> to_string(value)
      _ -> "localhost"
    end
  end
end
