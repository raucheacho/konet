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

  # Le floor est la seule chose que Konet arbitre lui-même : ses événements
  # doivent donc partir d'ici, et pas être reconstruits par un client — qui est
  # une partie prenante, pas l'arbitre.

  test "une prise et une libération émettent une paire" do
    {:ok, "alice", since} = Konet.Floor.acquire("t:pair", "alice")

    assert_receive {:webhook, _, _, taken}, 2000
    assert taken =~ ~s("event":"floor_acquired")
    assert taken =~ ~s("user_id":"alice")
    assert taken =~ ~s("topic":"t:pair")

    :ok = Konet.Floor.release("t:pair", "alice")

    assert_receive {:webhook, _, _, freed}, 2000
    assert freed =~ ~s("event":"floor_released")
    assert freed =~ ~s("reason":"released")
    assert freed =~ ~s("since":#{since})
    assert freed =~ ~s("held_ms":)
  end

  # Un second appui rend le `since` d'origine : c'est la même prise de parole,
  # et la compter deux fois ferait apparaître une transmission qui n'a pas eu
  # lieu.
  test "un appui répété n'émet pas une seconde prise" do
    {:ok, "bob", since} = Konet.Floor.acquire("t:repeat", "bob")
    assert_receive {:webhook, _, _, _first}, 2000

    assert {:ok, "bob", ^since} = Konet.Floor.acquire("t:repeat", "bob")
    refute_receive {:webhook, _, _, _}, 300

    :ok = Konet.Floor.release("t:repeat", "bob")
    assert_receive {:webhook, _, _, freed}, 2000
    assert freed =~ ~s("event":"floor_released")
  end

  # Un détenteur qui se tait est balayé. Sans événement, le journal garderait
  # une prise ouverte indéfiniment — le cas le plus trompeur de tous.
  test "un balayage émet une libération expirée" do
    Application.put_env(:konet, :floor_max_hold_ms, 0)
    on_exit(fn -> Application.delete_env(:konet, :floor_max_hold_ms) end)

    {:ok, "carol", _} = Konet.Floor.acquire("t:swept", "carol")
    assert_receive {:webhook, _, _, _taken}, 2000

    send(Konet.Floor, :sweep)

    assert_receive {:webhook, _, _, freed}, 2000
    assert freed =~ ~s("event":"floor_released")
    assert freed =~ ~s("reason":"expired")
    assert freed =~ ~s("user_id":"carol")
  end

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

  # Replaces the delivery pool with one of `max` slots for this test.
  defp with_pool(max) do
    swap_pool(max)
    on_exit(fn -> swap_pool(50) end)
  end

  defp swap_pool(max) do
    :ok = Supervisor.terminate_child(Konet.Supervisor, Konet.WebhookSupervisor)
    :ok = Supervisor.delete_child(Konet.Supervisor, Konet.WebhookSupervisor)

    {:ok, _} =
      Supervisor.start_child(
        Konet.Supervisor,
        {Task.Supervisor, name: Konet.WebhookSupervisor, max_children: max}
      )
  end

  test "drops and logs an event beyond the concurrency ceiling, rather than queueing it" do
    with_pool(0)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        Konet.Webhooks.emit("member_joined", %{room: "lobby", user: "flood"})
        refute_receive {:webhook, _, _, _}, 300
      end)

    assert log =~ "dropped"
  end

  test "a pending retry holds no slot: the next event still goes out" do
    # One slot. The first event fails once, so its retry is pending for 500 ms;
    # sleeping inside the task used to hold the only slot for all of it.
    with_pool(1)
    listener = start_listener(1, 500)
    on_exit(fn -> stop_listener(listener) end)
    use_listener(listener)

    Konet.Webhooks.emit("member_joined", %{room: "lobby", user: "first"})
    assert_receive {:webhook, 500, _, _}, 2000
    Process.sleep(50)

    Konet.Webhooks.emit("member_joined", %{room: "lobby", user: "second"})
    assert_receive {:webhook, 200, _, body}, 400
    assert Jason.decode!(body)["data"]["user"] == "second"

    # And the retry of the first still arrives afterwards.
    assert_receive {:webhook, 200, _, retried}, 2000
    assert Jason.decode!(retried)["data"]["user"] == "first"
  end

  test "an https receiver is verified against the system trust store" do
    opts = Konet.Webhooks.http_options_for("https://hooks.example.com/konet")
    ssl = Keyword.fetch!(opts, :ssl)

    assert ssl[:verify] == :verify_peer
    assert is_list(ssl[:cacerts]) and ssl[:cacerts] != []
    assert ssl[:server_name_indication] == ~c"hooks.example.com"
    assert ssl[:customize_hostname_check]

    # Plain http gets no TLS options at all.
    refute Keyword.has_key?(Konet.Webhooks.http_options_for("http://127.0.0.1/h"), :ssl)
  end
end
