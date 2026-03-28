defmodule LemonCore.TomlCompat do
  @moduledoc false

  @type decode_result :: {:ok, map()} | {:error, Exception.t()}

  @spec decode(binary()) :: decode_result
  def decode(content) when is_binary(content) do
    TomlElixir.decode(content)
  end

  @spec decode_file(Path.t()) :: decode_result
  def decode_file(path) when is_binary(path) do
    path
    |> File.read()
    |> case do
      {:ok, content} -> decode(content)
      {:error, reason} -> {:error, File.Error.exception(reason: reason, action: "read file", path: path)}
    end
  end
end
