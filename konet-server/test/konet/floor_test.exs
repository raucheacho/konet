defmodule Konet.FloorTest do
  use ExUnit.Case, async: false

  alias Konet.Floor

  # Channel-level behaviour lives in KonetWeb.RoomChannelTest. This covers the
  # arbiter itself: what it reports, and what it cleans up.

  setup do
    on_exit(fn -> Application.delete_env(:konet, :floor_max_hold_ms) end)
    :ok
  end

  defp monitor_count do
    %{refs: refs, topics: topics} = :sys.get_state(Floor)
    {map_size(refs), map_size(topics)}
  end

  test "acquire reports a wall-clock timestamp a client can read" do
    topic = "room:floor-since"
    on_exit(fn -> Floor.release(topic, "alice") end)

    before = System.system_time(:millisecond)
    assert {:ok, "alice", since} = Floor.acquire(topic, "alice")
    later = System.system_time(:millisecond)

    # Monotonic time would be a large arbitrary number, often negative, and
    # meaningless off this node — the sweep needs it, the wire does not.
    assert since >= before and since <= later
  end

  test "a duplicate press reports the original acquisition, not now" do
    topic = "room:floor-dup"
    on_exit(fn -> Floor.release(topic, "alice") end)

    assert {:ok, "alice", first} = Floor.acquire(topic, "alice")
    Process.sleep(15)
    assert {:ok, "alice", again} = Floor.acquire(topic, "alice")

    assert again == first,
           "a listener joining mid-stream needs to know when the talker started"
  end

  test "a second holder is refused and named" do
    topic = "room:floor-busy"
    on_exit(fn -> Floor.release(topic, "alice") end)

    assert {:ok, "alice", _} = Floor.acquire(topic, "alice")
    assert {:error, {:held, "alice"}} = Floor.acquire(topic, "bob")
  end

  test "only the holder may release" do
    topic = "room:floor-owner"

    assert {:ok, "alice", _} = Floor.acquire(topic, "alice")
    assert {:error, :not_holder} = Floor.release(topic, "bob")
    assert Floor.holder(topic) == "alice"
    assert :ok = Floor.release(topic, "alice")
    assert Floor.holder(topic) == nil
  end

  test "releasing drops the monitor, so repeated presses do not accumulate" do
    topic = "room:floor-monitors"
    {refs_before, topics_before} = monitor_count()

    for _ <- 1..20 do
      assert {:ok, "alice", _} = Floor.acquire(topic, "alice")
      assert :ok = Floor.release(topic, "alice")
    end

    :sys.get_state(Floor)
    assert monitor_count() == {refs_before, topics_before},
           "one monitor per press was left behind on the holder's pid"
  end

  test "re-acquiring by a different holder replaces the monitor" do
    topic = "room:floor-handover"
    on_exit(fn -> Floor.release(topic, "bob") end)

    {refs_before, topics_before} = monitor_count()

    assert {:ok, "alice", _} = Floor.acquire(topic, "alice")
    assert :ok = Floor.release(topic, "alice")
    assert {:ok, "bob", _} = Floor.acquire(topic, "bob")

    :sys.get_state(Floor)
    assert monitor_count() == {refs_before + 1, topics_before + 1}
  end

  test "the sweep frees a floor held past the maximum and its monitor" do
    topic = "room:floor-sweep"
    {refs_before, topics_before} = monitor_count()

    assert {:ok, "alice", _} = Floor.acquire(topic, "alice")

    Application.put_env(:konet, :floor_max_hold_ms, 0)
    send(Floor, :sweep)
    :sys.get_state(Floor)

    assert Floor.holder(topic) == nil
    assert monitor_count() == {refs_before, topics_before}
  end

  test "a holder that dies frees the floor" do
    topic = "room:floor-dead"

    holder = spawn(fn -> Process.sleep(:infinity) end)
    assert {:ok, "alice", _} = Floor.acquire(topic, "alice", holder)

    ref = Process.monitor(holder)
    Process.exit(holder, :kill)
    assert_receive {:DOWN, ^ref, :process, ^holder, _}, 1000

    # Two drains, not one: the first flushes the :monitor cast, and only once
    # Floor has processed that does its own :DOWN land in the mailbox.
    :sys.get_state(Floor)
    :sys.get_state(Floor)

    assert Floor.holder(topic) == nil
  end
end
