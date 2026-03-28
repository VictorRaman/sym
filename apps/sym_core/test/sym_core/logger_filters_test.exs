defmodule LemonCore.LoggerFiltersTest do
  use ExUnit.Case, async: true

  test "default logger handler includes the TLS alert decode error filter" do
    handler_config = Application.get_env(:logger, :default_handler, [])
    filters = Keyword.get(handler_config, :filters, [])

    assert {:tls_alert_decode_error, {_fun, :stop}} =
             Enum.find(filters, fn
               {:tls_alert_decode_error, _} -> true
               _ -> false
             end)
  end
end
