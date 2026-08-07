defmodule Konet.RateLimiter do
  use GenServer

  @table :konet_rl
  @default_connections_per_minute 200
  @default_messages_per_second 60
  # 50 frames/s for 20 ms Opus, plus headroom for a client that batches.
  @default_binary_per_second 120

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def check_connection(ip) do
    key = "conn:#{ip}:#{minute()}"
    count = :ets.update_counter(@table, key, {2, 1}, {key, 0})
    if count <= max_connections_per_minute(), do: :ok, else: {:error, :rate_limited}
  end

  def check_message(socket_id) do
    key = "msg:#{socket_id}:#{second()}"
    count = :ets.update_counter(@table, key, {2, 1}, {key, 0})
    if count <= max_messages_per_second(), do: :ok, else: {:error, :rate_limited}
  end

  # Binary frames get their own budget because they arrive at a media rate,
  # not a message rate: 20 ms Opus frames are 50 per second on their own, and
  # sharing the message budget would have a talker starve their own position
  # updates. The floor already allows one sender per topic, so this is a
  # backstop against a single flooding client, not the primary control.
  def check_binary(socket_id) do
    key = "bin:#{socket_id}:#{second()}"
    count = :ets.update_counter(@table, key, {2, 1}, {key, 0})
    if count <= max_binary_per_second(), do: :ok, else: {:error, :rate_limited}
  end

  defp max_connections_per_minute,
    do: Application.get_env(:konet, :rate_limit_connections, @default_connections_per_minute)

  defp max_messages_per_second,
    do: Application.get_env(:konet, :rate_limit_messages, @default_messages_per_second)

  defp max_binary_per_second,
    do: Application.get_env(:konet, :rate_limit_binary, @default_binary_per_second)

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :public, :set, {:write_concurrency, true}])
    schedule_cleanup()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    :ets.delete_all_objects(@table)
    schedule_cleanup()
    {:noreply, state}
  end

  defp schedule_cleanup, do: Process.send_after(self(), :cleanup, 120_000)
  defp minute, do: div(System.monotonic_time(:second), 60)
  defp second, do: System.monotonic_time(:second)
end
