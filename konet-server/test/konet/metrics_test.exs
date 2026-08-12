defmodule Konet.MetricsTest do
  use ExUnit.Case, async: false

  import Phoenix.ChannelTest

  alias Konet.Metrics

  @endpoint KonetWeb.Endpoint

  # The connection gauge used to pair a per-socket increment with a per-channel
  # decrement, so a client joining three rooms decremented three times and the
  # count drifted to zero. It is now owned by a monitor on the socket process,
  # which cannot drift.

  defp settle, do: (_ = Metrics.get())

  defp spawn_socket do
    pid = spawn(fn -> Process.sleep(:infinity) end)
    Metrics.connection_opened(pid)
    settle()
    pid
  end

  defp kill_and_settle(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1000
    # Drain the :DOWN that Metrics itself received, then the cast it triggered.
    settle()
    settle()
  end

  test "a connection is counted once and released when its socket dies" do
    before = Metrics.get().connections

    pid = spawn_socket()
    assert Metrics.get().connections == before + 1

    kill_and_settle(pid)
    assert Metrics.get().connections == before
  end

  test "registering the same socket twice still counts once" do
    before = Metrics.get().connections

    pid = spawn_socket()
    Metrics.connection_opened(pid)
    settle()

    assert Metrics.get().connections == before + 1

    kill_and_settle(pid)
    assert Metrics.get().connections == before
  end

  test "several sockets are counted independently" do
    before = Metrics.get().connections

    a = spawn_socket()
    b = spawn_socket()
    assert Metrics.get().connections == before + 2

    kill_and_settle(a)
    assert Metrics.get().connections == before + 1

    kill_and_settle(b)
    assert Metrics.get().connections == before
  end

  test "leaving channels does not decrement the connection count" do
    # The regression: RoomChannel.terminate/2 must not touch the gauge, or a
    # socket with several channels reports fewer connections than exist.
    {:ok, token} = Konet.Auth.sign(%{"sub" => "multi"})

    before = Metrics.get().connections

    # In ChannelTest the "socket process" is this test process, so the connect
    # below adds exactly one to the gauge and keeps it for the test's lifetime.
    {:ok, socket} = connect(KonetWeb.UserSocket, %{"token" => token})
    settle()
    assert Metrics.get().connections == before + 1

    {:ok, _, first} = subscribe_and_join(socket, "room:metrics-a")
    {:ok, _, second} = subscribe_and_join(socket, "room:metrics-b")
    settle()
    assert Metrics.get().connections == before + 1, "joining rooms must not change the gauge"

    # Unlinked first, or the channels' exits take this test process with them.
    for channel <- [first, second] do
      pid = channel.channel_pid
      Process.unlink(pid)
      ref = Process.monitor(pid)
      leave(channel)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1000
    end

    settle()
    settle()

    assert Metrics.get().connections == before + 1,
           "two channels leaving must not decrement a single connection twice"
  end

  test "messages accumulate" do
    before = Metrics.get().messages_total

    Metrics.message_sent()
    Metrics.message_sent()

    assert Metrics.get().messages_total == before + 2
  end
end
