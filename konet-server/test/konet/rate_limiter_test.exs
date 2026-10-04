defmodule Konet.RateLimiterTest do
  use ExUnit.Case, async: false

  test "message limit is enforced and configurable" do
    Application.put_env(:konet, :rate_limit_messages, 2)
    on_exit(fn -> Application.delete_env(:konet, :rate_limit_messages) end)

    socket_id = "test-socket-#{System.unique_integer([:positive])}"

    assert :ok = Konet.RateLimiter.check_message(socket_id)
    assert :ok = Konet.RateLimiter.check_message(socket_id)
    assert {:error, :rate_limited} = Konet.RateLimiter.check_message(socket_id)
  end

  test "connection limit is enforced and configurable" do
    Application.put_env(:konet, :rate_limit_connections, 1)
    on_exit(fn -> Application.delete_env(:konet, :rate_limit_connections) end)

    ip = "10.0.0.#{System.unique_integer([:positive])}"

    assert :ok = Konet.RateLimiter.check_connection(ip)
    assert {:error, :rate_limited} = Konet.RateLimiter.check_connection(ip)
  end

  test "cleanup keeps the current window, so a client at its limit stays limited" do
    # It used to empty the whole table, handing a client at its limit a fresh
    # budget in the middle of the window.
    Application.put_env(:konet, :rate_limit_connections, 1)
    on_exit(fn -> Application.delete_env(:konet, :rate_limit_connections) end)

    ip = "10.1.0.#{System.unique_integer([:positive])}"
    assert :ok = Konet.RateLimiter.check_connection(ip)

    send(Konet.RateLimiter, :cleanup)
    :sys.get_state(Konet.RateLimiter)

    assert {:error, :rate_limited} = Konet.RateLimiter.check_connection(ip)
  end

  test "cleanup deletes the windows that are over" do
    stale_minute = div(System.monotonic_time(:second), 60) - 5
    stale_second = System.monotonic_time(:second) - 5

    :ets.insert(:konet_rl, [
      {{:conn, "stale-ip", stale_minute}, 9},
      {{:msg, "stale-socket", stale_second}, 9},
      {{:bin, "stale-socket", stale_second}, 9}
    ])

    send(Konet.RateLimiter, :cleanup)
    :sys.get_state(Konet.RateLimiter)

    assert :ets.lookup(:konet_rl, {:conn, "stale-ip", stale_minute}) == []
    assert :ets.lookup(:konet_rl, {:msg, "stale-socket", stale_second}) == []
    assert :ets.lookup(:konet_rl, {:bin, "stale-socket", stale_second}) == []
  end
end
