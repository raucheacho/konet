defmodule Konet.BinaryModeTest do
  use ExUnit.Case, async: false

  alias Konet.BinaryMode

  # Channel-level behaviour lives in KonetWeb.RoomChannelTest. This covers the
  # registry itself: who wins, and what it forgets.

  defp member do
    pid = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  defp kill(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1000
  end

  test "parse defaults to exclusive and rejects anything else" do
    assert {:ok, :exclusive} = BinaryMode.parse(nil)
    assert {:ok, :exclusive} = BinaryMode.parse("exclusive")
    assert {:ok, :multiplex} = BinaryMode.parse("multiplex")
    assert {:error, :invalid} = BinaryMode.parse("full-duplex")
    assert {:error, :invalid} = BinaryMode.parse(1)
  end

  test "first joiners asking for different modes resolve to one mode" do
    topic = "room:bm-race"

    results =
      1..40
      |> Enum.map(fn n ->
        mode = if rem(n, 2) == 0, do: :exclusive, else: :multiplex
        pid = member()
        Task.async(fn -> BinaryMode.claim(topic, mode, pid) end)
      end)
      |> Enum.map(&Task.await/1)

    winners = for {:ok, mode} <- results, uniq: true, do: mode
    losers = for {:error, {:mismatch, mode}} <- results, uniq: true, do: mode

    assert [winner] = winners
    # Every refusal names the mode that won, not some third answer.
    assert losers == [winner]
    assert BinaryMode.current(topic) == winner
  end

  test "a topic forgets its mode when its last member dies" do
    topic = "room:bm-forget"
    alice = member()

    assert {:ok, :multiplex} = BinaryMode.claim(topic, :multiplex, alice)
    kill(alice)
    :sys.get_state(BinaryMode)

    assert BinaryMode.current(topic) == nil
    assert {:ok, :exclusive} = BinaryMode.claim(topic, :exclusive, member())
  end

  test "a dead member whose :DOWN is still queued does not hold the topic" do
    topic = "room:bm-stale"
    alice = member()
    kill(alice)

    # The row a member leaves behind between dying and its :DOWN being handled.
    # Written directly because that window cannot be opened reliably: nothing
    # orders the :DOWN against another process's claim.
    :ets.insert(:konet_binary_mode, {topic, alice, :multiplex})

    assert {:ok, :exclusive} = BinaryMode.claim(topic, :exclusive, member())
    assert BinaryMode.current(topic) == :exclusive
  end

  test "members survive a crash of the registry, and are still watched" do
    topic = "room:bm-crash"
    alice = member()
    assert {:ok, :multiplex} = BinaryMode.claim(topic, :multiplex, alice)

    old = Process.whereis(BinaryMode)
    kill(old)
    wait_for_restart(old)

    assert BinaryMode.current(topic) == :multiplex
    assert {:error, {:mismatch, :multiplex}} = BinaryMode.claim(topic, :exclusive, member())

    kill(alice)
    :sys.get_state(BinaryMode)
    assert BinaryMode.current(topic) == nil
  end

  defp wait_for_restart(old, attempts \\ 200) do
    case Process.whereis(BinaryMode) do
      pid when is_pid(pid) and pid != old ->
        :ok

      _ when attempts > 0 ->
        Process.sleep(5)
        wait_for_restart(old, attempts - 1)

      _ ->
        flunk("Konet.BinaryMode never came back")
    end
  end

  describe "multiplex member ceiling" do
    setup do
      Application.put_env(:konet, :multiplex_max_members, 2)
      on_exit(fn -> Application.delete_env(:konet, :multiplex_max_members) end)
    end

    test "a multiplex topic refuses a member beyond the ceiling" do
      topic = "room:bm-full"
      assert {:ok, :multiplex} = BinaryMode.claim(topic, :multiplex, member())
      assert {:ok, :multiplex} = BinaryMode.claim(topic, :multiplex, member())
      assert {:error, {:full, 2}} = BinaryMode.claim(topic, :multiplex, member())
    end

    test "a member leaving frees its place" do
      topic = "room:bm-full-leave"
      alice = member()
      assert {:ok, :multiplex} = BinaryMode.claim(topic, :multiplex, alice)
      assert {:ok, :multiplex} = BinaryMode.claim(topic, :multiplex, member())

      kill(alice)
      :sys.get_state(BinaryMode)

      assert {:ok, :multiplex} = BinaryMode.claim(topic, :multiplex, member())
    end

    test "an exclusive topic has no ceiling: the floor already bounds it" do
      topic = "room:bm-full-exclusive"

      for _ <- 1..5 do
        assert {:ok, :exclusive} = BinaryMode.claim(topic, :exclusive, member())
      end
    end

    test "0 removes the ceiling" do
      Application.put_env(:konet, :multiplex_max_members, 0)
      topic = "room:bm-unbounded"

      for _ <- 1..5 do
        assert {:ok, :multiplex} = BinaryMode.claim(topic, :multiplex, member())
      end
    end
  end
end
