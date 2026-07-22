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
end
