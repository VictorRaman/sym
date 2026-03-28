defmodule CodingAgent.UI.RPC do
  @moduledoc """
  Minimal in-process RPC-flavored UI adapter retained after the umbrella merge.
  """

  use GenServer

  @behaviour CodingAgent.UI

  @server __MODULE__

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, @server))
  end

  @impl true
  def init(_opts) do
    {:ok, %{editor_text: "", status: %{}, widgets: %{}}}
  end

  @impl true
  def select(_title, options, opts) do
    default =
      opts[:default] ||
        options
        |> List.first()
        |> case do
          %{value: value} -> value
          _ -> nil
        end

    {:ok, default}
  end

  @impl true
  def confirm(_title, _message, _opts), do: {:ok, true}

  @impl true
  def input(_title, placeholder, _opts), do: {:ok, placeholder}

  @impl true
  def editor(_title, prefill, _opts), do: {:ok, prefill}

  @impl true
  def notify(_message, _type), do: :ok

  @impl true
  def set_status(key, text), do: GenServer.cast(@server, {:set_status, key, text})

  @impl true
  def set_widget(key, content, opts), do: GenServer.cast(@server, {:set_widget, key, content, opts})

  @impl true
  def set_working_message(_message), do: :ok

  @impl true
  def set_title(_title), do: :ok

  @impl true
  def set_editor_text(text), do: GenServer.cast(@server, {:set_editor_text, text})

  @impl true
  def get_editor_text, do: GenServer.call(@server, :get_editor_text)

  @impl true
  def has_ui?, do: true

  @impl true
  def handle_cast({:set_status, key, text}, state) do
    {:noreply, %{state | status: Map.put(state.status, key, text)}}
  end

  def handle_cast({:set_widget, key, content, _opts}, state) do
    {:noreply, %{state | widgets: Map.put(state.widgets, key, content)}}
  end

  def handle_cast({:set_editor_text, text}, state) do
    {:noreply, %{state | editor_text: text || ""}}
  end

  @impl true
  def handle_call(:get_editor_text, _from, state) do
    {:reply, state.editor_text, state}
  end
end
