defmodule LemonCore.Redaction do
  @moduledoc """
  Shared helpers for redacting secret-like fields from diagnostic payloads.
  """

  @redacted "[REDACTED]"
  @string_patterns [
    {~r/\b(Bearer)\s+[A-Za-z0-9._~+\/=-]+/i, "\\1 #{@redacted}"},
    {~r/\b(x-api-key\s*:\s*)([^\s,;]+)/i, "\\1#{@redacted}"},
    {~r/\b(sk-[A-Za-z0-9_-]{10,})\b/, @redacted}
  ]
  @sensitive_key_fragments [
    "access_token",
    "api_key",
    "apikey",
    "auth",
    "authorization",
    "bot_token",
    "challenge",
    "cookie",
    "password",
    "private_key",
    "secret",
    "session_token",
    "token"
  ]

  @spec redact_term(term()) :: term()
  def redact_term(term), do: do_redact(term)

  defp do_redact(%{__struct__: _} = struct) do
    struct
    |> Map.from_struct()
    |> do_redact()
  end

  defp do_redact(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, raw}, acc ->
      redacted =
        if sensitive_key?(key) do
          @redacted
        else
          do_redact(raw)
        end

      Map.put(acc, key, redacted)
    end)
  end

  defp do_redact(value) when is_list(value), do: Enum.map(value, &do_redact/1)
  defp do_redact(value) when is_tuple(value), do: value |> Tuple.to_list() |> Enum.map(&do_redact/1)

  defp do_redact(value) when is_binary(value) do
    Enum.reduce(@string_patterns, value, fn {pattern, replacement}, acc ->
      Regex.replace(pattern, acc, replacement)
    end)
  end

  defp do_redact(value), do: value

  defp sensitive_key?(key) do
    key
    |> normalize_key()
    |> then(fn key_name ->
      Enum.any?(@sensitive_key_fragments, &String.contains?(key_name, &1))
    end)
  end

  defp normalize_key(key) when is_atom(key), do: key |> Atom.to_string() |> String.downcase()
  defp normalize_key(key) when is_binary(key), do: String.downcase(key)
  defp normalize_key(_), do: ""
end
