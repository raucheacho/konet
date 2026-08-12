defmodule KonetWeb.CorsTest do
  use ExUnit.Case, async: false

  alias KonetWeb.Cors

  # check_origin (WebSocket) and Corsica (REST) used to disagree: the first
  # honoured KONET_ALLOWED_ORIGINS while the second was pinned to "*", so
  # locking the variable down restricted upgrades and left the REST API open to
  # every origin. They now read the same list.

  setup do
    on_exit(fn -> Application.put_env(:konet, :allowed_origins, nil) end)
    :ok
  end

  test "unset means open, matching check_origin: false" do
    Application.put_env(:konet, :allowed_origins, nil)

    assert Cors.allowed?("https://anything.example")
    assert Cors.allowed?("http://localhost:5173")
  end

  test "a configured list is an allow-list" do
    Application.put_env(:konet, :allowed_origins, [
      "https://app.example.com",
      "https://admin.example.com"
    ])

    assert Cors.allowed?("https://app.example.com")
    assert Cors.allowed?("https://admin.example.com")
    refute Cors.allowed?("https://evil.example.com")
    refute Cors.allowed?("http://app.example.com"), "scheme is part of the origin"
  end

  test "an empty list is treated as open rather than as deny-all" do
    # parse_origins/1 turns "*" and "" into false, never into []. Should one
    # ever reach here, failing open matches the socket's behaviour instead of
    # silently blocking every browser client.
    Application.put_env(:konet, :allowed_origins, [])

    assert Cors.allowed?("https://anything.example")
  end
end
