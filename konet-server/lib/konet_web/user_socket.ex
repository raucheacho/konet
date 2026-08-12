defmodule KonetWeb.UserSocket do
  use Phoenix.Socket

  channel "room:*", KonetWeb.RoomChannel

  @impl true
  def connect(%{"token" => token}, socket, connect_info) do
    ip = extract_ip(connect_info)

    with :ok <- Konet.RateLimiter.check_connection(ip),
         {:ok, claims} <- Konet.Auth.verify(token) do
      socket_id = generate_id()

      # self() is the socket transport process: Konet.Metrics monitors it and
      # decrements when it dies, so the gauge cannot drift.
      Konet.Metrics.connection_opened(self())

      {:ok,
       socket
       |> assign(:user_id, Map.get(claims, "sub", "anon_" <> socket_id))
       |> assign(:role, Map.get(claims, "role", "anon"))
       |> assign(:socket_id, socket_id)
       |> assign(:channels, Map.get(claims, "channels"))}
    else
      {:error, :rate_limited} -> {:error, %{reason: "rate_limited"}}
      _ -> {:error, %{reason: "unauthorized"}}
    end
  end

  def connect(_params, _socket, _connect_info), do: {:error, %{reason: "token_required"}}

  @impl true
  def id(socket), do: "user_socket:#{socket.assigns.socket_id}"

  # Behind a reverse proxy every connection carries the proxy's IP, which turns
  # the per-IP connection limit into a single global budget — the deployment
  # rate-limits itself. The forwarded header is the only way to see the real
  # client, but trusting it unconditionally is worse than not reading it at all:
  # anyone could then spoof an IP and get their own private budget. So it is
  # honoured only when the operator asserts there is a proxy in front
  # (KONET_TRUST_PROXY_HEADERS=true), which is exactly the case where the
  # header cannot be set by the client.
  defp extract_ip(connect_info) do
    if trust_proxy_headers?() do
      forwarded_ip(connect_info) || peer_ip(connect_info)
    else
      peer_ip(connect_info)
    end
  end

  defp forwarded_ip(%{x_headers: headers}) when is_list(headers) do
    headers
    |> Enum.find_value(fn
      {"x-forwarded-for", value} -> value
      _ -> nil
    end)
    |> case do
      nil ->
        nil

      value ->
        # Leftmost entry is the original client; the rest are intermediate
        # proxies appending to the chain.
        value |> String.split(",") |> List.first() |> String.trim() |> presence()
    end
  end

  defp forwarded_ip(_), do: nil

  defp peer_ip(%{peer_data: %{address: addr}}), do: :inet.ntoa(addr) |> to_string()
  defp peer_ip(_), do: "unknown"

  defp presence(""), do: nil
  defp presence(value), do: value

  defp trust_proxy_headers?,
    do: Application.get_env(:konet, :trust_proxy_headers, false) == true

  defp generate_id,
    do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
end
