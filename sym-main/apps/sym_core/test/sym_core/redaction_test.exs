defmodule LemonCore.RedactionTest do
  use ExUnit.Case, async: true

  alias LemonCore.Redaction

  test "redacts high-confidence bearer and x-api-key strings" do
    payload = %{
      "result" => "Authorization: Bearer topsecret-token",
      "headers" => "x-api-key: sk-ant-super-secret-key",
      "safe" => "plain text"
    }

    redacted = Redaction.redact_term(payload)

    assert redacted["result"] =~ "Bearer [REDACTED]"
    assert redacted["headers"] =~ "x-api-key: [REDACTED]"
    assert redacted["safe"] == "plain text"
    refute redacted["result"] =~ "topsecret-token"
    refute redacted["headers"] =~ "sk-ant-super-secret-key"
  end
end
