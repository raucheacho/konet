defmodule Konet.RateLimiter do
  use GenServer

  @table :konet_rl
  @max_connections_per_minute 200
  @max_messages_per_second 60

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def check_connection(ip) do
    key = "conn:#{ip}:#{minute()}"
    count = :ets.update_counter(@table, key, {2, 1}, {key, 0})
    if count <= @max_connections_per_minute, do: :ok, else: {:error, :rate_limited}
  end

  def check_message(socket_id) do
    key = "msg:#{socket_id}:#{second()}"
    count = :ets.update_counter(@table, key, {2, 1}, {key, 0})
    if count <= @max_messages_per_second, do: :ok, else: {:error, :rate_limited}
  end

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
