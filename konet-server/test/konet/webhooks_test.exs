defmodule Konet.WebhooksTest do
  use ExUnit.Case, async: false

  # Failures used to be logged and dropped, so a receiver restarting lost the
  # events outright. Delivery now retries with backoff — but only for failures a
  # retry can fix, and always carrying the same id so a receiver can deduplicate.

  setup do
    listener = start_listener()

    Application.put_env(:konet, :webhook_url, "http://127.0.0.1:#{listener.port}/hook")
    Application.put_env(:konet, :webhook_retries, 3)

    on_exit(fn ->
      Application.put_env(:konet, :webhook_url, nil)
      Application.put_env(:konet, :webhook_secret, nil)
      Application.delete_env(:konet, :webhook_retries)
      stop_listener(listener)
    end)

    {:ok, listener: listener}
  end

  # ── A minimal HTTP listener ───────────────────────────────────────────────
  #
  # `fail_times` responses come back with `fail_status` before it starts
  # answering 200, which is how the retry path is driven.

  defp start_listener(fail_times \\ 0, fail_status \\ 500) do
    test = self()
    {:ok, socket} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    {:ok, counter} = Agent.start_link(fn -> %{remaining: fail_times, status: fail_status} end)

    pid = spawn_link(fn -> accept_loop(socket, test, counter) end)

    %{port: port, socket: socket, pid: pid, counter: counter}
  end

  defp stop_listener(%{socket: socket, pid: pid, counter: counter}) do
    Process.unlink(pid)
    Process.exit(pid, :kill)
    :gen_tcp.close(socket)
    if Process.alive?(counter), do: Agent.stop(counter)
  end

  defp accept_loop(socket, test, counter) do
    case :gen_tcp.accept(socket) do
      {:ok, client} ->
        {headers, body} = read_request(client)

        status =
          Agent.get_and_update(counter, fn
            %{remaining: n, status: s} = state when n > 0 ->
              {s, %{state | remaining: n - 1}}

            state ->
              {200, state}
          end)

        send(test, {:webhook, status, headers, body})

        :gen_tcp.send(
          client,
          "HTTP/1.1 #{status} X\r\ncontent-length: 0\r\nconnection: close\r\n\r\n"
        )

        :gen_tcp.close(client)
        accept_loop(socket, test, counter)

      {:error, _} ->
        :ok
    end
  end

  defp read_request(client, acc \\ "") do
    case :gen_tcp.recv(client, 0, 1000) do
      {:ok, data} ->
        acc = acc <> data

        if String.contains?(acc, "\r\n\r\n") do
          [headers, body] = String.split(acc, "\r\n\r\n", parts: 2)

          if byte_size(body) >= content_length(headers) do
            {headers, body}
          else
            read_request(client, acc)
          end
        else
          read_request(client, acc)
        end

      {:error, _} ->
        {acc, ""}
    end
  end

  defp content_length(headers) do
    case Regex.run(~r/content-length:\s*(\d+)/i, headers) do
      [_, n] -> String.to_integer(n)
      _ -> 0
    end
  end

  defp use_listener(listener) do
    Application.put_env(:konet, :webhook_url, "http://127.0.0.1:#{listener.port}/hook")
  end

  # ── Tests ─────────────────────────────────────────────────────────────────

  test "delivers an event with an id and a timestamp" do
    Konet.Webhooks.emit("member_joined", %{room: "lobby", user: "alice"})

    assert_receive {:webhook, 200, _headers, body}, 2000
    decoded = Jason.decode!(body)

    assert decoded["event"] == "member_joined"
    assert decoded["data"] == %{"room" => "lobby", "user" => "alice"}
    assert is_binary(decoded["id"])
    assert is_binary(decoded["timestamp"])
  end

  test "retries a 5xx until it succeeds, reusing the same id" do
    listener = start_listener(2, 500)
    on_exit(fn -> stop_listener(listener) end)
    use_listener(listener)

    Konet.Webhooks.emit("channel_occupied", %{room: "flaky"})

    assert_receive {:webhook, 500, _, first}, 2000
    assert_receive {:webhook, 500, _, second}, 3000
    assert_receive {:webhook, 200, _, third}, 4000

    ids = Enum.map([first, second, third], &Jason.decode!(&1)["id"])

    assert length(Enum.uniq(ids)) == 1,
           "a retry must carry the same id, or a receiver cannot deduplicate it"
  end

  test "gives up after the configured number of attempts" do
    listener = start_listener(10, 503)
    on_exit(fn -> stop_listener(listener) end)
    use_listener(listener)
    Application.put_env(:konet, :webhook_retries, 2)

    Konet.Webhooks.emit("member_left", %{room: "lobby", user: "bob"})

    assert_receive {:webhook, 503, _, _}, 2000
    assert_receive {:webhook, 503, _, _}, 3000
    refute_receive {:webhook, _, _, _}, 1500
  end

  test "does not retry a 4xx — the receiver understood and refused" do
    listener = start_listener(10, 400)
    on_exit(fn -> stop_listener(listener) end)
    use_listener(listener)

    Konet.Webhooks.emit("member_joined", %{room: "lobby", user: "carol"})

    assert_receive {:webhook, 400, _, _}, 2000
    refute_receive {:webhook, _, _, _}, 1500
  end

  test "does retry a 429, which means later rather than no" do
    listener = start_listener(1, 429)
    on_exit(fn -> stop_listener(listener) end)
    use_listener(listener)

    Konet.Webhooks.emit("channel_vacated", %{room: "busy"})

    assert_receive {:webhook, 429, _, _}, 2000
    assert_receive {:webhook, 200, _, _}, 3000
  end

  test "signs the body when a secret is configured" do
    Application.put_env(:konet, :webhook_secret, "s3cret")

    Konet.Webhooks.emit("member_left", %{room: "lobby", user: "bob"})

    assert_receive {:webhook, 200, headers, body}, 2000

    expected = :crypto.mac(:hmac, :sha256, "s3cret", body) |> Base.encode16(case: :lower)

    assert String.contains?(String.downcase(headers), "x-konet-signature: sha256=#{expected}"),
           "the signature must be over the exact bytes the receiver sees"
  end

  test "sends no signature header when no secret is configured" do
    Konet.Webhooks.emit("member_left", %{room: "lobby", user: "dave"})

    assert_receive {:webhook, 200, headers, _}, 2000
    refute String.contains?(String.downcase(headers), "x-konet-signature")
  end

  test "does nothing when no URL is configured" do
    Application.put_env(:konet, :webhook_url, nil)

    Konet.Webhooks.emit("member_joined", %{room: "lobby", user: "nobody"})

    refute_receive {:webhook, _, _, _}, 300
  end
end
