defmodule Konet.LogBuffer do
  @moduledoc """
  Keeps the last @max_entries studio log events in memory so the Logs page
  has something to show on mount instead of only events from that moment on.
  """
  use GenServer

  @max_entries 100

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def record(type, data) do
    entry = %{
      type: type,
      data: data,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    GenServer.cast(__MODULE__, {:record, entry})
    Phoenix.PubSub.broadcast(Konet.PubSub, "studio:logs", entry)
  end

  @doc "Recent entries, oldest first."
  def list do
    GenServer.call(__MODULE__, :list)
  end

  @impl true
  def init(_), do: {:ok, []}

  @impl true
  def handle_cast({:record, entry}, state) do
    {:noreply, Enum.take([entry | state], @max_entries)}
  end

  @impl true
  def handle_call(:list, _from, state) do
    {:reply, Enum.reverse(state), state}
  end
end
