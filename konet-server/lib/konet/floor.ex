defmodule Konet.Floor do
  @moduledoc """
  Exclusive floor control: at most one member of a topic holds it at a time.

  This is the primitive behind half-duplex media — push-to-talk, a radio net,
  a turn-based game — where the point is that a second sender must be *told
  no* rather than mixed in. Konet stays generic: it arbitrates who may send,
  it does not know what is being sent.

  Two properties matter and both are handled here rather than by callers:

    * **Acquisition is atomic.** Two clients pressing at the same millisecond
      resolve to one winner, because `:ets.insert_new/2` is a compare-and-swap
      and the ETS table is the only authority.

    * **The floor is always released.** A holder whose channel process dies —
      a rider entering a tunnel mid-sentence — would otherwise mute the topic
      forever, so holders are monitored. A holder that simply stops talking
      without releasing is swept once it exceeds `max_hold_ms`.

  Each row carries two timestamps because they answer different questions: the
  monotonic one is what the sweep measures elapsed hold time against, and the
  wall-clock one is what goes on the wire, since a client has no way to
  interpret this node's monotonic clock.
  """
  use GenServer

  @table :konet_floor
  @default_max_hold_ms 30_000
  @sweep_every_ms 5_000
  # Bounds the retry when a holder releases between our insert and our read.
  # Unbounded recursion here could in principle spin forever under contention.
  @max_acquire_attempts 5

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Claims the floor for `user_id` on `topic`.

  Returns `{:ok, holder, since}` — including when the caller already holds it,
  so a duplicate press is harmless and reports the *original* acquisition time
  rather than now — or `{:error, {:held, holder}}`.

  `since` is a wall-clock millisecond timestamp, suitable for broadcasting.
  """
  def acquire(topic, user_id, pid \\ self()) do
    do_acquire(topic, user_id, pid, @max_acquire_attempts)
  end

  defp do_acquire(topic, user_id, _pid, 0) do
    # Every attempt lost a race. Report the current holder rather than spin;
    # if it is somehow free again the caller's next press will take it.
    case holder(topic) do
      nil -> {:error, {:held, user_id}}
      other -> {:error, {:held, other}}
    end
  end

  defp do_acquire(topic, user_id, pid, attempts_left) do
    now_wall = now_wall_ms()
    entry = {topic, user_id, pid, now_ms(), now_wall}

    if :ets.insert_new(@table, entry) do
      GenServer.cast(__MODULE__, {:monitor, topic, pid})
      {:ok, user_id, now_wall}
    else
      case :ets.lookup(@table, topic) do
        [{^topic, ^user_id, _pid, _since, since_wall}] -> {:ok, user_id, since_wall}
        [{^topic, other, _pid, _since, _since_wall}] -> {:error, {:held, other}}
        [] -> do_acquire(topic, user_id, pid, attempts_left - 1)
      end
    end
  end

  @doc """
  Releases the floor, but only if `user_id` is the holder — a late release
  from a previous holder must not cut off whoever is talking now.
  """
  def release(topic, user_id) do
    case :ets.lookup(@table, topic) do
      [{^topic, ^user_id, _pid, _since, _since_wall}] ->
        :ets.delete(@table, topic)
        # Drop the monitor too: a channel that acquires and releases repeatedly
        # would otherwise accumulate one monitor per press on its own pid.
        GenServer.cast(__MODULE__, {:demonitor, topic})
        :ok

      _ ->
        {:error, :not_holder}
    end
  end

  @doc "The user id currently holding `topic`, or nil."
  def holder(topic) do
    case :ets.lookup(@table, topic) do
      [{^topic, user_id, _pid, _since, _since_wall}] -> user_id
      [] -> nil
    end
  end

  @doc "True when `user_id` may send on `topic` right now."
  def holds?(topic, user_id), do: holder(topic) == user_id

  defp max_hold_ms, do: Application.get_env(:konet, :floor_max_hold_ms, @default_max_hold_ms)

  # The table is owned by Konet.Tables, so held floors survive a crash of this
  # process. The monitors do not — they live in this GenServer's state — so they
  # are rebuilt from the table on start. Without that, a holder that died while
  # this process was down would keep its topic muted until the sweep, which can
  # be thirty seconds of silence.
  @impl true
  def init(_) do
    schedule_sweep()

    state =
      @table
      |> :ets.tab2list()
      |> Enum.reduce(%{refs: %{}, topics: %{}}, fn {topic, _user, pid, _mono, _wall}, acc ->
        if Process.alive?(pid) do
          ref = Process.monitor(pid)
          %{acc | refs: Map.put(acc.refs, ref, topic), topics: Map.put(acc.topics, topic, ref)}
        else
          # Holder already gone while we were down.
          :ets.delete(@table, topic)
          acc
        end
      end)

    {:ok, state}
  end

  @impl true
  def handle_cast({:monitor, topic, pid}, state) do
    # One monitor per topic. A previous holder's monitor is dropped first,
    # otherwise the map grows by one entry per acquire.
    state = drop_monitor(state, topic)

    ref = Process.monitor(pid)

    {:noreply,
     %{state | refs: Map.put(state.refs, ref, topic), topics: Map.put(state.topics, topic, ref)}}
  end

  @impl true
  def handle_cast({:demonitor, topic}, state) do
    {:noreply, drop_monitor(state, topic)}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    {topic, refs} = Map.pop(state.refs, ref)

    state =
      if topic do
        # Match on the pid too: by now the topic may have been legitimately
        # re-acquired by someone else, and that holder must not be evicted.
        :ets.match_delete(@table, {topic, :_, pid, :_, :_})
        %{state | refs: refs, topics: Map.delete(state.topics, topic)}
      else
        %{state | refs: refs}
      end

    {:noreply, state}
  end

  def handle_info(:sweep, state) do
    cutoff = now_ms() - max_hold_ms()

    # =< rather than <: a hold is expired once it has *reached* max_hold_ms, and
    # with a max of 0 (tests, or an operator disabling holds) a strict < never
    # fires for a floor taken in the current millisecond.
    expired =
      :ets.select(@table, [{{:"$1", :_, :_, :"$2", :_}, [{:"=<", :"$2", cutoff}], [:"$1"]}])

    state =
      Enum.reduce(expired, state, fn topic, acc ->
        :ets.delete(@table, topic)
        drop_monitor(acc, topic)
      end)

    schedule_sweep()
    {:noreply, state}
  end

  defp drop_monitor(state, topic) do
    case Map.pop(state.topics, topic) do
      {nil, _} ->
        state

      {ref, topics} ->
        Process.demonitor(ref, [:flush])
        %{state | refs: Map.delete(state.refs, ref), topics: topics}
    end
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_every_ms)
  defp now_ms, do: System.monotonic_time(:millisecond)
  defp now_wall_ms, do: System.system_time(:millisecond)
end
