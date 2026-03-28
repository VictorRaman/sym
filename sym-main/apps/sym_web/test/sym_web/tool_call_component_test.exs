defmodule LemonWeb.ToolCallComponentTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias LemonWeb.Live.Components.ToolCallComponent

  test "redacts sensitive fields in tool payloads before rendering" do
    rendered =
      render_component(&ToolCallComponent.tool_call/1,
        event: %{
          action: %{
            title: "Bash",
            detail: %{
              args: %{
                token: "topsecret",
                safe: "ok"
              }
            }
          },
          phase: :started
        }
      )

    assert rendered =~ "[REDACTED]"
    assert rendered =~ "ok"
    refute rendered =~ "topsecret"
  end

  test "redacts high-confidence secret patterns in plain strings before rendering" do
    rendered =
      render_component(&ToolCallComponent.tool_call/1,
        event: %{
          action: %{
            title: "HTTP",
            detail: "Authorization: Bearer topsecret-token\nx-api-key: sk-ant-super-secret-key"
          },
          phase: :completed
        }
      )

    assert rendered =~ "Bearer [REDACTED]"
    assert rendered =~ "x-api-key: [REDACTED]"
    refute rendered =~ "topsecret-token"
    refute rendered =~ "sk-ant-super-secret-key"
  end
end
