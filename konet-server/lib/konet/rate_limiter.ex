defmodule Konet.RateLimiter do
  use GenServer

  @table :konet_rl
  @default_connections_per_minute 200
  @default_messages_per_second 60
  # 50 frames/s at a 20 ms frame size, plus headroom for a client that batches.
  @default_binary_per_second 120

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def check_connection(ip) do
    key = {:conn, ip, minute()}
    count = :ets.update_counter(@table, key, {2, 1}, {key, 0})
    if count <= max_connections_per_minute(), do: :ok, else: {:error, :rate_limited}
  end

  def check_message(socket_id) do
    key = {:msg, socket_id, second()}
    count = :ets.update_counter(@table, key, {2, 1}, {key, 0})
    if count <= max_messages_per_second(), do: :ok, else: {:error, :rate_limited}
  end

  # Binary frames get their own budget because they arrive at a media rate,
  # not a message rate: 20 ms frames are 50 per second on their own, and
  # sharing the message budget would have a sender starve their own non-media
  # events. The budget is per socket: it stops one client flooding. In an
  # :exclusive topic the floor also bounds the topic to one sender; in a
  # :multiplex topic nothing does, by design.
  def check_binary(socket_id) do
    key = {:bin, socket_id, second()}
    count = :ets.update_counter(@table, key, {2, 1}, {key, 0})
    if count <= max_binary_per_second(), do: :ok, else: {:error, :rate_limited}
  end

  defp max_connections_per_minute,
    do: Application.get_env(:konet, :rate_limit_connections, @default_connections_per_minute)

  defp max_messages_per_second,
    do: Application.get_env(:konet, :rate_limit_messages, @default_messages_per_second)

  defp max_binary_per_second,
    do: Application.get_env(:konet, :rate_limit_binary, @default_binary_per_second)

  # Table owned by Konet.Tables — see the note there.
  @impl true
  def init(_) do
    schedule_cleanup()
    {:ok, %{}}
  end

  # Only windows that are over are deleted. Emptying the whole table, as this
  # used to, reset whatever window was current at that instant: a client at its
  # limit got a fresh budget mid-window, so twice the limit could pass. The keys
  # are tuples so the window can be matched on.
  @impl true
  def handle_info(:cleanup, state) do
    minute = minute()
    second = second()

    :ets.select_delete(@table, [
      {{{:conn, :_, :"$1"}, :_}, [{:<, :"$1", minute}], [true]},
      {{{:msg, :_, :"$1"}, :_}, [{:<, :"$1", second}], [true]},
      {{{:bin, :_, :"$1"}, :_}, [{:<, :"$1", second}], [true]}
    ])

    schedule_cleanup()
    {:noreply, state}
  end

  defp schedule_cleanup, do: Process.send_after(self(), :cleanup, 120_000)
  defp minute, do: div(System.monotonic_time(:second), 60)
  defp second, do: System.monotonic_time(:second)
end
