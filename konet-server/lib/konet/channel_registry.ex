defmodule Konet.ChannelRegistry do
  use GenServer

  @table :konet_channels

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def channel_joined(room_id) do
    GenServer.cast(__MODULE__, {:joined, room_id})
  end

  def channel_left(room_id) do
    GenServer.cast(__MODULE__, {:left, room_id})
  end

  def list do
    :ets.tab2list(@table)
    |> Enum.map(fn {id, count} -> %{id: id, subscribers: count} end)
    |> Enum.sort_by(& &1.id)
  end

  # The table is created and owned by Konet.Tables, not here: an ETS table dies
  # with its owner, so creating it in this init/1 meant a crash of this
  # GenServer emptied the channel list while sockets were still connected — and
  # it never recovered, since counts are only incremented on join.
  @impl true
  def init(_), do: {:ok, %{}}

  @impl true
  def handle_cast({:joined, room_id}, state) do
    count = :ets.update_counter(@table, room_id, {2, 1}, {room_id, 0})
    if count == 1, do: Konet.Webhooks.emit("channel_occupied", %{room: room_id})
    Phoenix.PubSub.broadcast(Konet.PubSub, "studio:channels", :channels_updated)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:left, room_id}, state) do
    case :ets.lookup(@table, room_id) do
      [{_, count}] when count <= 1 ->
        :ets.delete(@table, room_id)
        Konet.Webhooks.emit("channel_vacated", %{room: room_id})

      [{_, count}] ->
        :ets.insert(@table, {room_id, count - 1})

      [] ->
        :ok
    end

    Phoenix.PubSub.broadcast(Konet.PubSub, "studio:channels", :channels_updated)
    {:noreply, state}
  end
end
