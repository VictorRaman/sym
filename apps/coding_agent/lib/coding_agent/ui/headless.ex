defmodule CodingAgent.UI.Headless do
  @moduledoc """
  Minimal no-op UI implementation for headless platform runs.
  """

  @behaviour CodingAgent.UI

  require Logger

  @impl true
  def select(_title, _options, _opts), do: {:ok, nil}

  @impl true
  def confirm(_title, _message, _opts), do: {:ok, true}

  @impl true
  def input(_title, _placeholder, _opts), do: {:ok, nil}

  @impl true
  def editor(_title, prefill, _opts), do: {:ok, prefill}

  @impl true
  def notify(message, type) do
    Logger.debug("[headless-ui][#{type}] #{message}")
    :ok
  end

  @impl true
  def set_status(_key, _text), do: :ok

  @impl true
  def set_widget(_key, _content, _opts), do: :ok

  @impl true
  def set_working_message(nil), do: :ok

  @impl true
  def set_working_message(message) do
    Logger.debug("[headless-ui][working] #{message}")
    :ok
  end

  @impl true
  def set_title(_title), do: :ok

  @impl true
  def set_editor_text(_text), do: :ok

  @impl true
  def get_editor_text, do: ""

  @impl true
  def has_ui?, do: false
end
