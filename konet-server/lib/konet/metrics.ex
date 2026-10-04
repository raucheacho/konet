defmodule Konet.Metrics do
  @moduledoc """
  Connection and message counters, plus the per-second message rate.

  Connections are counted by **monitoring the socket process**, not by pairing
  an increment with a decrement somewhere else. The pairing is what used to be
  wrong: the increment fired once per socket in `KonetWeb.UserSocket.connect/3`
  while the decrement fired once per *channel* in `RoomChannel.terminate/2`, so
  a client joining three rooms decremented three times and the gauge drifted to
  zero on any multi-channel workload.

  A monitor cannot drift: the socket process going away is the event, whether it
  left cleanly, crashed, or was killed.

  Messages are counted **without this process**. `message_sent/0` runs on every
  binary frame — fifty times a second per sender — and used to be a cast to
  this one GenServer, the same single serialization point `KONET_LOG_BROADCASTS`
  exists to avoid for `Konet.LogBuffer`. It is now an `:ets.update_counter/4`
  on a table owned by `Konet.Tables`, with decentralized counters, so callers
  never wait on each other or on a mailbox; the per-second rate is the
  difference between two reads of that total.
  """
  use GenServer

  @table :konet_metrics

  defstruct connections: 0,
            messages_total: 0,
            messages_rate: 0,
            started_at: nil

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %__MODULE__{started_at: DateTime.utc_now()}, name: __MODULE__)
  end

  @doc """
  Registers an open connection, owned by `pid` (the socket transport process).

  The count drops when that process dies, so there is no matching
  `connection_closed` to forget to call.
  """
  def connection_opened(pid \\ self()), do: GenServer.cast(__MODULE__, {:connection_opened, pid})

  def message_sent do
    :ets.update_counter(@table, :messages_total, {2, 1}, {:messages_total, 0})
    :ok
  end

  def get, do: GenServer.call(__MODULE__, :get)

  defp messages_total do
    case :ets.lookup(@table, :messages_total) do
      [{_, n}] -> n
      [] -> 0
    end
  end

  @impl true
  def init(state) do
    :timer.send_interval(1_000, :compute_rate)
    {:ok, %{metrics: %{state | messages_total: messages_total()}, monitors: %{}}}
  end

  @impl true
  def handle_cast({:connection_opened, pid}, %{metrics: metrics, monitors: monitors} = state) do
    # A socket that somehow registers twice must still count once, or the gauge
    # is back to being a pairing problem.
    if Map.has_key?(monitors, pid) do
      {:noreply, state}
    else
      ref = Process.monitor(pid)
      new_metrics = %{metrics | connections: metrics.connections + 1}
      broadcast_update(new_metrics)
      {:noreply, %{state | metrics: new_metrics, monitors: Map.put(monitors, pid, ref)}}
    end
  end

  @impl true
  def handle_call(:get, _from, %{metrics: metrics} = state) do
    {:reply, %{metrics | messages_total: messages_total()}, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{metrics: metrics, monitors: monitors} = state) do
    case Map.pop(monitors, pid) do
      {nil, _} ->
        {:noreply, state}

      {_ref, remaining} ->
        new_metrics = %{metrics | connections: max(0, metrics.connections - 1)}
        broadcast_update(new_metrics)
        {:noreply, %{state | metrics: new_metrics, monitors: remaining}}
    end
  end

  def handle_info(:compute_rate, %{metrics: metrics} = state) do
    total = messages_total()

    new_metrics = %{
      metrics
      | messages_rate: max(0, total - metrics.messages_total),
        messages_total: total
    }

    Phoenix.PubSub.broadcast(Konet.PubSub, "studio:metrics", {:metrics_update, new_metrics})
    {:noreply, %{state | metrics: new_metrics}}
  end

  # Pushes the connection-count change to the Studio without touching the
  # message total: the rate is the difference between two :compute_rate reads,
  # and advancing it here would corrupt the msg/s rate.
  defp broadcast_update(metrics) do
    Phoenix.PubSub.broadcast(Konet.PubSub, "studio:metrics", {:metrics_update, metrics})
  end
end
