defmodule CodingAgent.UI.DebugRPC do
  @moduledoc """
  Minimal debug-oriented UI adapter preserved under the coding_agent app.
  """

  use GenServer

  @behaviour CodingAgent.UI

  @server __MODULE__

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, @server))
  end

  @impl true
  def init(_opts) do
    {:ok, %{editor_text: "", signals: []}}
  end

  @impl true
  def select(_title, options, _opts) do
    value =
      options
      |> List.first()
      |> case do
        %{value: option_value} -> option_value
        _ -> nil
      end

    {:ok, value}
  end

  @impl true
  def confirm(_title, _message, _opts), do: {:ok, true}

  @impl true
  def input(_title, placeholder, _opts), do: {:ok, placeholder}

  @impl true
  def editor(_title, prefill, _opts), do: {:ok, prefill}

  @impl true
  def notify(message, type), do: GenServer.cast(@server, {:signal, :notify, %{message: message, type: type}})

  @impl true
  def set_status(key, text), do: GenServer.cast(@server, {:signal, :status, %{key: key, text: text}})

  @impl true
  def set_widget(key, content, opts),
    do: GenServer.cast(@server, {:signal, :widget, %{key: key, content: content, opts: opts}})

  @impl true
  def set_working_message(message),
    do: GenServer.cast(@server, {:signal, :working_message, %{message: message}})

  @impl true
  def set_title(title), do: GenServer.cast(@server, {:signal, :title, %{title: title}})

  @impl true
  def set_editor_text(text), do: GenServer.cast(@server, {:set_editor_text, text})

  @impl true
  def get_editor_text, do: GenServer.call(@server, :get_editor_text)

  @impl true
  def has_ui?, do: true

  @impl true
  def handle_cast({:signal, type, payload}, state) do
    {:noreply, %{state | signals: [{type, payload} | state.signals]}}
  end

  def handle_cast({:set_editor_text, text}, state) do
    {:noreply, %{state | editor_text: text || ""}}
  end

  @impl true
  def handle_call(:get_editor_text, _from, state) do
    {:reply, state.editor_text, state}
  end
end
