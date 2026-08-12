defmodule KonetWeb.UserSocketTest do
  use ExUnit.Case, async: false

  import Phoenix.ChannelTest

  @endpoint KonetWeb.Endpoint

  # Behind a reverse proxy every connection carries the proxy's IP, which turns
  # the per-IP connection limit into one global budget — the deployment
  # rate-limits itself. Reading X-Forwarded-For fixes that, but only when the
  # operator asserts a proxy is in front: trusting it unconditionally would let
  # any direct client forge an IP and mint itself a private budget.

  defp connect_info(peer, forwarded) do
    %{
      peer_data: %{address: peer, port: 1234, ssl_cert: nil},
      x_headers: forwarded
    }
  end

  defp token do
    {:ok, token} = Konet.Auth.sign(%{"sub" => "u"})
    token
  end

  setup do
    Application.put_env(:konet, :rate_limit_connections, 1)

    on_exit(fn ->
      Application.delete_env(:konet, :rate_limit_connections)
      Application.put_env(:konet, :trust_proxy_headers, false)
    end)

    :ok
  end

  test "without trust, two clients behind one proxy share a budget" do
    Application.put_env(:konet, :trust_proxy_headers, false)

    proxy = {10, 0, 0, 9}

    assert {:ok, _} =
             connect(KonetWeb.UserSocket, %{"token" => token()},
               connect_info: connect_info(proxy, [{"x-forwarded-for", "203.0.113.1"}])
             )

    # Same peer, different real client — and with the header ignored, the
    # second one is refused. This is the self-inflicted rate limiting.
    assert {:error, %{reason: "rate_limited"}} =
             connect(KonetWeb.UserSocket, %{"token" => token()},
               connect_info: connect_info(proxy, [{"x-forwarded-for", "203.0.113.2"}])
             )
  end

  test "with trust, clients behind one proxy get their own budgets" do
    Application.put_env(:konet, :trust_proxy_headers, true)

    proxy = {10, 0, 0, 10}

    assert {:ok, _} =
             connect(KonetWeb.UserSocket, %{"token" => token()},
               connect_info: connect_info(proxy, [{"x-forwarded-for", "198.51.100.1"}])
             )

    assert {:ok, _} =
             connect(KonetWeb.UserSocket, %{"token" => token()},
               connect_info: connect_info(proxy, [{"x-forwarded-for", "198.51.100.2"}])
             )

    # The same real client is still held to the limit.
    assert {:error, %{reason: "rate_limited"}} =
             connect(KonetWeb.UserSocket, %{"token" => token()},
               connect_info: connect_info(proxy, [{"x-forwarded-for", "198.51.100.1"}])
             )
  end

  test "with trust, the leftmost forwarded entry is the client" do
    Application.put_env(:konet, :trust_proxy_headers, true)

    proxy = {10, 0, 0, 11}
    chain = "192.0.2.7, 10.0.0.11, 10.0.0.12"

    assert {:ok, _} =
             connect(KonetWeb.UserSocket, %{"token" => token()},
               connect_info: connect_info(proxy, [{"x-forwarded-for", chain}])
             )

    # A second connection whose chain starts with the same client is refused,
    # proving the bucket keyed on 192.0.2.7 and not on an intermediate hop.
    assert {:error, %{reason: "rate_limited"}} =
             connect(KonetWeb.UserSocket, %{"token" => token()},
               connect_info: connect_info(proxy, [{"x-forwarded-for", "192.0.2.7, 10.0.0.99"}])
             )
  end

  test "with trust but no forwarded header, the peer address is used" do
    Application.put_env(:konet, :trust_proxy_headers, true)

    peer = {10, 0, 0, 12}

    assert {:ok, _} =
             connect(KonetWeb.UserSocket, %{"token" => token()},
               connect_info: connect_info(peer, [])
             )

    assert {:error, %{reason: "rate_limited"}} =
             connect(KonetWeb.UserSocket, %{"token" => token()},
               connect_info: connect_info(peer, [])
             )
  end

  test "the connection limit is checked before the signature" do
    Application.put_env(:konet, :trust_proxy_headers, false)
    peer = {10, 0, 0, 13}

    assert {:ok, _} =
             connect(KonetWeb.UserSocket, %{"token" => token()},
               connect_info: connect_info(peer, [])
             )

    # A flood of garbage tokens should be cheap to refuse: the quota answers
    # first, so the HMAC is never computed.
    assert {:error, %{reason: "rate_limited"}} =
             connect(KonetWeb.UserSocket, %{"token" => "garbage"},
               connect_info: connect_info(peer, [])
             )
  end
end
