defmodule Konet.BinaryMode do
  @moduledoc """
  Which binary transport a topic runs: `:exclusive` or `:multiplex`.

    * `:exclusive` — at most one member sends at a time, arbitrated by
      `Konet.Floor`. Half-duplex media: push-to-talk, a radio net. The default,
      so a client that says nothing gets what it always got.

    * `:multiplex` — every member may send at any time, with no arbitration at
      all. Full-duplex media: a call. `Konet.Floor` is never consulted for such
      a topic.

  The mode belongs to the topic, not to a member, because the two cannot share
  one: a push-to-talk client relies on a second sender being told no, and a call
  client relies on never being told no. So the first member fixes the mode, a
  joiner asking for the other one is refused, and the mode is forgotten once the
  last member leaves — the next one to join fixes it again.

  Each member is a row `{topic, pid, mode}` in a bag. Claims go through this
  process so that checking the current mode and recording a new member are one
  step: two first joiners asking for different modes resolve to one winner.
  Members are monitored and dropped when their channel process dies, which is
  the only way a channel ever leaves — no explicit release, nothing to forget.

  A channel caches its own mode at join. That cache cannot go stale: the mode
  only changes once the topic is empty, and a cached member is by definition
  still in it. The binary hot path therefore reads no table at all.
  """
  use GenServer

  @table :konet_binary_mode
  @modes %{"exclusive" => :exclusive, "multiplex" => :multiplex}

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Reads the mode a client asked for at join. Absent means `:exclusive`, which
  is what every client got before the mode existed.
  """
  def parse(nil), do: {:ok, :exclusive}
  def parse(raw) when is_map_key(@modes, raw), do: {:ok, Map.fetch!(@modes, raw)}
  def parse(_), do: {:error, :invalid}

  @doc """
  Records `pid` as a member of `topic` in `mode`.

  Returns `{:ok, mode}`, or `{:error, {:mismatch, current}}` when the members
  already there run the other mode.
  """
  def claim(topic, mode, pid \\ self()) when mode in [:exclusive, :multiplex] do
    GenServer.call(__MODULE__, {:claim, topic, mode, pid})
  end

  @doc "The mode `topic` currently runs, or nil when nobody is in it."
  def current(topic) do
    case :ets.lookup(@table, topic) do
      [{^topic, _pid, mode} | _] -> mode
      [] -> nil
    end
  end

  # Table owned by Konet.Tables, so members survive a crash of this process.
  # The monitors do not, and are rebuilt from the table — the same arrangement
  # as Konet.Floor.
  @impl true
  def init(_) do
    refs =
      @table
      |> :ets.tab2list()
      |> Enum.reduce(%{}, fn {topic, pid, _mode} = row, acc ->
        if Process.alive?(pid) do
          Map.put(acc, Process.monitor(pid), topic)
        else
          :ets.delete_object(@table, row)
          acc
        end
      end)

    {:ok, %{refs: refs}}
  end

  @impl true
  def handle_call({:claim, topic, mode, pid}, _from, state) do
    # A member that died a moment ago may still be in the table, its :DOWN
    # queued behind this call. Left there it would hold the topic in a mode
    # nobody uses any more.
    members = Enum.filter(:ets.lookup(@table, topic), &alive_member?/1)

    case members do
      [{_, _, current} | _] when current != mode ->
        {:reply, {:error, {:mismatch, current}}, state}

      _ ->
        :ets.insert(@table, {topic, pid, mode})
        ref = Process.monitor(pid)
        {:reply, {:ok, mode}, %{state | refs: Map.put(state.refs, ref, topic)}}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    case Map.pop(state.refs, ref) do
      {nil, _} ->
        {:noreply, state}

      {topic, refs} ->
        :ets.match_delete(@table, {topic, pid, :_})
        {:noreply, %{state | refs: refs}}
    end
  end

  defp alive_member?({_topic, pid, _mode} = row) do
    if Process.alive?(pid) do
      true
    else
      :ets.delete_object(@table, row)
      false
    end
  end
end
