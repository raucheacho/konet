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
  """
  use GenServer

  @table :konet_floor
  @default_max_hold_ms 30_000
  @sweep_every_ms 5_000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Claims the floor for `user_id` on `topic`.

  Returns `{:ok, holder}` — including when the caller already holds it, so a
  duplicate press is harmless — or `{:error, {:held, holder}}`.
  """
  def acquire(topic, user_id, pid \\ self()) do
    entry = {topic, user_id, pid, now_ms()}

    if :ets.insert_new(@table, entry) do
      GenServer.cast(__MODULE__, {:monitor, topic, pid})
      {:ok, user_id}
    else
      case holder(topic) do
        ^user_id -> {:ok, user_id}
        nil -> acquire(topic, user_id, pid)
        other -> {:error, {:held, other}}
      end
    end
  end

  @doc """
  Releases the floor, but only if `user_id` is the holder — a late release
  from a previous holder must not cut off whoever is talking now.
  """
  def release(topic, user_id) do
    case :ets.lookup(@table, topic) do
      [{^topic, ^user_id, _pid, _since}] ->
        :ets.delete(@table, topic)
        :ok

      _ ->
        {:error, :not_holder}
    end
  end

  @doc "The user id currently holding `topic`, or nil."
  def holder(topic) do
    case :ets.lookup(@table, topic) do
      [{^topic, user_id, _pid, _since}] -> user_id
      [] -> nil
    end
  end

  @doc "True when `user_id` may send on `topic` right now."
  def holds?(topic, user_id), do: holder(topic) == user_id

  defp max_hold_ms, do: Application.get_env(:konet, :floor_max_hold_ms, @default_max_hold_ms)

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :public, :set, {:read_concurrency, true}])
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:monitor, topic, pid}, state) do
    # One monitor per holder. The reference is kept so the DOWN message can
    # name the topic to clear without scanning the table.
    ref = Process.monitor(pid)
    {:noreply, Map.put(state, ref, topic)}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    {topic, state} = Map.pop(state, ref)

    # Match on the pid too: by now the topic may have been legitimately
    # re-acquired by someone else, and that holder must not be evicted.
    if topic, do: :ets.match_delete(@table, {topic, :_, pid, :_})

    {:noreply, state}
  end

  def handle_info(:sweep, state) do
    cutoff = now_ms() - max_hold_ms()
    :ets.select_delete(@table, [{{:_, :_, :_, :"$1"}, [{:<, :"$1", cutoff}], [true]}])
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_every_ms)
  defp now_ms, do: System.monotonic_time(:millisecond)
end
