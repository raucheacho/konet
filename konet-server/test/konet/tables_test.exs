defmodule Konet.TablesTest do
  use ExUnit.Case, async: false

  # ETS tables die with their owning process. Creating them inside each worker's
  # init/1 meant a worker crash destroyed its table and the :one_for_one restart
  # recreated it empty — silently freeing every held floor, and emptying the
  # Studio's channel list permanently, since counts are only incremented on join.
  #
  # Konet.Tables owns them all instead. These tests kill the workers and assert
  # the data is still there.

  defp restart(name) do
    assert Process.whereis(Konet.Supervisor), "the supervisor is already down"
    pid = Process.whereis(name)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1000

    # Wait for the supervisor to bring it back.
    wait_until(fn ->
      case Process.whereis(name) do
        nil -> false
        new -> new != pid
      end
    end)

    Process.whereis(name)
  end

  defp wait_until(fun, attempts \\ 200) do
    Enum.reduce_while(1..attempts, false, fn _, _ ->
      if fun.() do
        {:halt, true}
      else
        Process.sleep(5)
        {:cont, false}
      end
    end)
    |> case do
      true -> :ok
      false -> flunk("condition never became true")
    end
  end

  test "Konet.Tables owns every named table" do
    for name <- Konet.Tables.names() do
      assert :ets.whereis(name) != :undefined, "#{name} does not exist"
      assert :ets.info(name, :owner) == Process.whereis(Konet.Tables)
    end
  end

  test "held floors survive a Konet.Floor crash" do
    topic = "room:tables-floor"
    holder = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(holder, :kill) end)

    assert {:ok, "alice", _} = Konet.Floor.acquire(topic, "alice", holder)
    assert Konet.Floor.holder(topic) == "alice"

    restart(Konet.Floor)

    assert Konet.Floor.holder(topic) == "alice",
           "a crash used to free every floor on the server"

    # And the rebuilt process still monitors the holder, so the floor is freed
    # when that holder dies rather than waiting for the 30s sweep.
    ref = Process.monitor(holder)
    Process.exit(holder, :kill)
    assert_receive {:DOWN, ^ref, :process, ^holder, _}, 1000

    :sys.get_state(Konet.Floor)
    :sys.get_state(Konet.Floor)
    assert Konet.Floor.holder(topic) == nil
  end

  test "a floor whose holder died during the outage is cleaned up on restart" do
    topic = "room:tables-floor-stale"
    holder = spawn(fn -> Process.sleep(:infinity) end)

    assert {:ok, "bob", _} = Konet.Floor.acquire(topic, "bob", holder)

    # Kill the holder and the arbiter together: nothing is left to notice.
    Process.exit(holder, :kill)
    restart(Konet.Floor)

    assert Konet.Floor.holder(topic) == nil,
           "init/1 should drop entries whose holder is already gone"
  end

  test "channel counts survive a ChannelRegistry crash" do
    Konet.ChannelRegistry.channel_joined("tables-registry")
    :sys.get_state(Konet.ChannelRegistry)

    assert Enum.any?(Konet.ChannelRegistry.list(), &(&1.id == "tables-registry"))

    restart(Konet.ChannelRegistry)

    assert Enum.any?(Konet.ChannelRegistry.list(), &(&1.id == "tables-registry")),
           "the Studio's channel list used to empty and never recover"

    Konet.ChannelRegistry.channel_left("tables-registry")
    :sys.get_state(Konet.ChannelRegistry)
  end

  test "history survives a Konet.History crash" do
    Application.put_env(:konet, :history_limit, 5)
    on_exit(fn -> Application.put_env(:konet, :history_limit, 0) end)

    Konet.History.forget("tables-history")
    Konet.History.record("tables-history", "kept", %{"n" => 1})
    :sys.get_state(Konet.History)

    assert [%{event: "kept"}] = Konet.History.list("tables-history")

    restart(Konet.History)

    assert [%{event: "kept"}] = Konet.History.list("tables-history")
  end

  test "rate limit counters survive a RateLimiter crash" do
    Application.put_env(:konet, :rate_limit_messages, 2)
    on_exit(fn -> Application.delete_env(:konet, :rate_limit_messages) end)

    socket_id = "tables-rl-#{System.unique_integer([:positive])}"

    assert :ok = Konet.RateLimiter.check_message(socket_id)
    assert :ok = Konet.RateLimiter.check_message(socket_id)

    restart(Konet.RateLimiter)

    # Losing these would be harmless, but keeping them means a client cannot
    # reset its own budget by crashing the limiter.
    assert {:error, :rate_limited} = Konet.RateLimiter.check_message(socket_id)
  end
end
