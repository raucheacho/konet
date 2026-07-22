defmodule Konet.Metrics do
  use GenServer

  defstruct connections: 0,
            messages_total: 0,
            messages_rate: 0,
            messages_current_window: 0,
            started_at: nil

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %__MODULE__{started_at: DateTime.utc_now()}, name: __MODULE__)
  end

  def connection_opened, do: GenServer.cast(__MODULE__, :connection_opened)
  def connection_closed, do: GenServer.cast(__MODULE__, :connection_closed)
  def message_sent, do: GenServer.cast(__MODULE__, :message_sent)
  def get, do: GenServer.call(__MODULE__, :get)

  @impl true
  def init(state) do
    :timer.send_interval(1_000, :compute_rate)
    {:ok, state}
  end

  @impl true
  def handle_cast(:connection_opened, state) do
    new_state = %{state | connections: state.connections + 1}
    broadcast_update(new_state)
    {:noreply, new_state}
  end

  @impl true
  def handle_cast(:connection_closed, state) do
    new_state = %{state | connections: max(0, state.connections - 1)}
    broadcast_update(new_state)
    {:noreply, new_state}
  end

  @impl true
  def handle_cast(:message_sent, state) do
    {:noreply, %{state |
      messages_total: state.messages_total + 1,
      messages_current_window: state.messages_current_window + 1
    }}
  end

  @impl true
  def handle_call(:get, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_info(:compute_rate, state) do
    new_state = %{state |
      messages_rate: state.messages_current_window,
      messages_current_window: 0
    }
    Phoenix.PubSub.broadcast(Konet.PubSub, "studio:metrics", {:metrics_update, new_state})
    {:noreply, new_state}
  end

  # Pushes the connection-count change to the Studio without touching the
  # 1-second message window — flushing it here would corrupt the msg/s rate.
  defp broadcast_update(state) do
    Phoenix.PubSub.broadcast(Konet.PubSub, "studio:metrics", {:metrics_update, state})
  end
end
