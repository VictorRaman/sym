defmodule LemonControlPlane.QueueMode do
  @moduledoc false

  @type t :: :collect | :followup | :steer | :steer_backlog | :interrupt

  @all_modes [:collect, :followup, :steer, :steer_backlog, :interrupt]

  @spec parse(term(), keyword()) :: t()
  def parse(value, opts \\ []) do
    default = Keyword.get(opts, :default, :collect)
    allowed = Keyword.get(opts, :allowed, @all_modes)

    case normalize(value) do
      mode when is_atom(mode) ->
        if mode in allowed, do: mode, else: default

      _ -> default
    end
  end

  @spec label(term(), keyword()) :: String.t()
  def label(value, opts \\ []) do
    value
    |> parse(opts)
    |> Atom.to_string()
  end

  defp normalize(:collect), do: :collect
  defp normalize(:followup), do: :followup
  defp normalize(:steer), do: :steer
  defp normalize(:steer_backlog), do: :steer_backlog
  defp normalize(:interrupt), do: :interrupt

  defp normalize(value) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      "collect" -> :collect
      "followup" -> :followup
      "steer" -> :steer
      "steer_backlog" -> :steer_backlog
      "interrupt" -> :interrupt
      _ -> :invalid
    end
  end

  defp normalize(_value), do: :invalid
end
