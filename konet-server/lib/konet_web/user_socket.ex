defmodule KonetWeb.UserSocket do
  use Phoenix.Socket

  channel "room:*", KonetWeb.RoomChannel

  @impl true
  def connect(%{"token" => token}, socket, connect_info) do
    ip = extract_ip(connect_info)

    with :ok <- Konet.RateLimiter.check_connection(ip),
         {:ok, claims} <- Konet.Auth.verify(token) do
      socket_id = generate_id()

      Konet.Metrics.connection_opened()

      {:ok,
       socket
       |> assign(:user_id, Map.get(claims, "sub", "anon_" <> socket_id))
       |> assign(:role, Map.get(claims, "role", "anon"))
       |> assign(:socket_id, socket_id)}
    else
      {:error, :rate_limited} -> {:error, %{reason: "rate_limited"}}
      _ -> {:error, %{reason: "unauthorized"}}
    end
  end

  def connect(_params, _socket, _connect_info), do: {:error, %{reason: "token_required"}}

  @impl true
  def id(socket), do: "user_socket:#{socket.assigns.socket_id}"

  defp extract_ip(%{peer_data: %{address: addr}}),
    do: :inet.ntoa(addr) |> to_string()

  defp extract_ip(_), do: "unknown"

  defp generate_id,
    do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
end
