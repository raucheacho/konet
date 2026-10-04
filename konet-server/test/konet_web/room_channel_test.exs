defmodule KonetWeb.RoomChannelTest do
  use ExUnit.Case, async: false

  import Phoenix.ChannelTest

  @endpoint KonetWeb.Endpoint

  defp connect_with(claims) do
    {:ok, token} = Konet.Auth.sign(claims)
    {:ok, socket} = connect(KonetWeb.UserSocket, %{"token" => token})
    socket
  end

  describe "connect" do
    test "rejects a missing token" do
      assert {:error, %{reason: "token_required"}} = connect(KonetWeb.UserSocket, %{})
    end

    test "rejects an invalid token" do
      assert {:error, %{reason: "unauthorized"}} =
               connect(KonetWeb.UserSocket, %{"token" => "garbage"})
    end

    test "assigns user_id and role from claims" do
      socket = connect_with(%{"role" => "anon", "sub" => "alice"})
      assert socket.assigns.user_id == "alice"
      assert socket.assigns.role == "anon"
    end
  end

  describe "join authorization" do
    test "token without channels claim can join any room" do
      socket = connect_with(%{"role" => "anon", "sub" => "open-user"})
      assert {:ok, _, _socket} = subscribe_and_join(socket, "room:anything")
    end

    test "scoped token can join a listed room" do
      socket = connect_with(%{"sub" => "scoped", "channels" => ["room:allowed"]})
      assert {:ok, _, _socket} = subscribe_and_join(socket, "room:allowed")
    end

    test "scoped token is denied on an unlisted room" do
      socket = connect_with(%{"sub" => "scoped", "channels" => ["room:allowed"]})
      assert {:error, %{reason: "unauthorized"}} = subscribe_and_join(socket, "room:other")
    end

    test "a refused join is not reported as a leave" do
      # Phoenix runs terminate/2 for a refused join as well; it used to log a
      # `leave` (and emit a `member_left` webhook) with `room: nil`.
      Phoenix.PubSub.subscribe(Konet.PubSub, "studio:logs")
      socket = connect_with(%{"sub" => "refused", "channels" => ["room:allowed"]})

      assert {:error, %{reason: "unauthorized"}} = subscribe_and_join(socket, "room:refused")

      assert_receive %{type: "join_denied", data: %{user: "refused"}}
      refute_receive %{type: "leave", data: %{user: "refused"}}, 300
    end

    test "trailing wildcard grants a namespace" do
      socket = connect_with(%{"sub" => "ns", "channels" => ["room:user-42:*"]})
      assert {:ok, _, _socket} = subscribe_and_join(socket, "room:user-42:inbox")

      socket2 = connect_with(%{"sub" => "ns", "channels" => ["room:user-42:*"]})

      assert {:error, %{reason: "unauthorized"}} =
               subscribe_and_join(socket2, "room:user-43:inbox")
    end
  end

  describe "broadcast" do
    test "relays events to subscribers" do
      socket = connect_with(%{"sub" => "sender"})
      {:ok, _, socket} = subscribe_and_join(socket, "room:bc-test")

      push(socket, "broadcast", %{"event" => "ping", "payload" => %{"n" => 1}})
      assert_broadcast "ping", %{"n" => 1}
    end
  end

  describe "unsupported input" do
    test "replies with an error instead of crashing on an unknown event" do
      socket = connect_with(%{"sub" => "sender"})
      {:ok, _, socket} = subscribe_and_join(socket, "room:unknown-event")

      ref = push(socket, "not_a_konet_event", %{"n" => 1})
      assert_reply ref, :error, %{reason: "unsupported_event", event: "not_a_konet_event"}

      # The channel must still be usable afterwards.
      push(socket, "broadcast", %{"event" => "ping", "payload" => %{"n" => 1}})
      assert_broadcast "ping", %{"n" => 1}
    end

    test "replies with an error instead of crashing on a malformed broadcast" do
      socket = connect_with(%{"sub" => "sender"})
      {:ok, _, socket} = subscribe_and_join(socket, "room:malformed")

      ref = push(socket, "broadcast", %{"missing" => "event and payload"})
      assert_reply ref, :error, %{reason: "unsupported_event"}
    end
  end

  describe "floor control" do
    test "a first acquire is granted and announced" do
      socket = connect_with(%{"sub" => "alice"})
      {:ok, _, socket} = subscribe_and_join(socket, "room:floor-grant")

      ref = push(socket, "konet:floor_acquire", %{})
      assert_reply ref, :ok, %{holder: "alice"}
      assert_broadcast "konet:floor", %{holder: "alice"}
    end

    test "a second holder is refused and told who has it" do
      alice = connect_with(%{"sub" => "alice"})
      {:ok, _, alice} = subscribe_and_join(alice, "room:floor-busy")
      ref = push(alice, "konet:floor_acquire", %{})
      assert_reply ref, :ok, %{holder: "alice"}

      bob = connect_with(%{"sub" => "bob"})
      {:ok, _, bob} = subscribe_and_join(bob, "room:floor-busy")
      ref = push(bob, "konet:floor_acquire", %{})
      assert_reply ref, :error, %{reason: "floor_held", holder: "alice"}
    end

    test "a repeated press by the holder is harmless" do
      socket = connect_with(%{"sub" => "alice"})
      {:ok, _, socket} = subscribe_and_join(socket, "room:floor-repeat")

      ref = push(socket, "konet:floor_acquire", %{})
      assert_reply ref, :ok, %{holder: "alice"}
      ref = push(socket, "konet:floor_acquire", %{})
      assert_reply ref, :ok, %{holder: "alice"}
    end

    test "only the holder may release" do
      alice = connect_with(%{"sub" => "alice"})
      {:ok, _, alice} = subscribe_and_join(alice, "room:floor-release")
      ref = push(alice, "konet:floor_acquire", %{})
      assert_reply ref, :ok, %{holder: "alice"}

      bob = connect_with(%{"sub" => "bob"})
      {:ok, _, bob} = subscribe_and_join(bob, "room:floor-release")
      ref = push(bob, "konet:floor_release", %{})
      assert_reply ref, :error, %{reason: "not_holder"}

      # Alice still holds it, so Bob taking over must still be refused.
      assert Konet.Floor.holder("room:floor-release") == "alice"

      ref = push(alice, "konet:floor_release", %{})
      assert_reply ref, :ok, _
      assert Konet.Floor.holder("room:floor-release") == nil
    end

    test "the floor frees when the holder's channel goes away" do
      alice = connect_with(%{"sub" => "alice"})
      {:ok, _, alice} = subscribe_and_join(alice, "room:floor-drop")
      ref = push(alice, "konet:floor_acquire", %{})
      assert_reply ref, :ok, %{holder: "alice"}

      # A rider entering a tunnel: the channel dies without releasing.
      # Unlinked first, or the channel's exit takes the test process with it.
      channel = alice.channel_pid
      Process.unlink(channel)
      mref = Process.monitor(channel)
      leave(alice)
      assert_receive {:DOWN, ^mref, :process, ^channel, _}, 1000

      # Drains Floor's mailbox, so the monitor path is covered too and not
      # only the release that terminate/2 already did.
      :sys.get_state(Konet.Floor)
      assert Konet.Floor.holder("room:floor-drop") == nil
    end
  end

  describe "binary frames" do
    test "the floor holder's frames reach the other subscribers" do
      alice = connect_with(%{"sub" => "alice"})
      {:ok, _, alice} = subscribe_and_join(alice, "room:audio")
      ref = push(alice, "konet:floor_acquire", %{})
      assert_reply ref, :ok, %{holder: "alice"}

      push(alice, "a", {:binary, <<1, 2, 3>>})
      assert_broadcast "a", {:binary, <<1, 2, 3>>}
    end

    test "a frame without the floor is refused" do
      socket = connect_with(%{"sub" => "mute"})
      {:ok, _, socket} = subscribe_and_join(socket, "room:audio-nofloor")

      ref = push(socket, "a", {:binary, <<1, 2, 3>>})
      assert_reply ref, :error, %{reason: "floor_required"}

      # And the channel is still usable.
      push(socket, "broadcast", %{"event" => "ping", "payload" => %{"n" => 1}})
      assert_broadcast "ping", %{"n" => 1}
    end

    test "audio is not fed back to the talker" do
      alice = connect_with(%{"sub" => "alice"})
      {:ok, _, alice} = subscribe_and_join(alice, "room:audio-echo")
      ref = push(alice, "konet:floor_acquire", %{})
      assert_reply ref, :ok, %{holder: "alice"}

      push(alice, "a", {:binary, <<9>>})
      # broadcast_from! reaches subscribers but must not push back to alice.
      refute_push "a", {:binary, <<9>>}
    end
  end

  # Each member runs in its own process, acting as that client's transport: in
  # Phoenix.ChannelTest a push lands on the process that connected, so members
  # sharing the test process could not be told apart — and "bob hears alice but
  # not himself" is exactly what these tests are about. `join/3`, not
  # `subscribe_and_join/3`, so a member sees only what its socket would.
  defp start_member(user, topic, params \\ %{}) do
    test = self()
    # Connecting is only allowed from the test process; the member then makes
    # itself the transport, which is where the channel will push.
    socket = connect_with(%{"sub" => user})

    pid =
      spawn_link(fn ->
        socket = %{socket | transport_pid: self()}

        case join(socket, topic, params) do
          {:ok, reply, socket} ->
            send(test, {:joined, self(), reply})
            member_loop(test, user, socket)

          {:error, reply} ->
            send(test, {:refused, self(), reply})
        end
      end)

    receive do
      {:joined, ^pid, reply} -> {:ok, pid, reply}
      {:refused, ^pid, reply} -> {:error, reply}
    after
      1000 -> flunk("#{user} never joined #{topic}")
    end
  end

  defp member_loop(test, user, socket) do
    receive do
      {:push, event, payload} ->
        push(socket, event, payload)
        member_loop(test, user, socket)

      {:leave, from} ->
        Process.unlink(socket.channel_pid)
        mref = Process.monitor(socket.channel_pid)
        leave(socket)
        receive do: ({:DOWN, ^mref, _, _, _} -> :ok)
        send(from, {:left, self()})

      %Phoenix.Socket.Message{event: event, payload: payload} ->
        send(test, {:pushed, user, event, payload})
        member_loop(test, user, socket)

      %Phoenix.Socket.Reply{status: status, payload: payload} ->
        send(test, {:replied, user, status, payload})
        member_loop(test, user, socket)

      _other ->
        member_loop(test, user, socket)
    end
  end

  defp member_push(pid, event, payload), do: send(pid, {:push, event, payload})

  defp member_leave(pid) do
    send(pid, {:leave, self()})
    assert_receive {:left, ^pid}, 1000
  end

  # The frames `user` received from `sender`, told apart only by the sender
  # prefix the server stamps in :multiplex mode — the payload is a bare counter.
  defp frames_from(user, sender, event) do
    receive do
      {:pushed, ^user, ^event, {:binary, <<size, name::binary-size(size), n>>}}
      when name == sender ->
        [n | frames_from(user, sender, event)]
    after
      200 -> []
    end
  end

  describe "binary mode" do
    test "a join without a mode is exclusive, and says so" do
      socket = connect_with(%{"sub" => "alice"})

      assert {:ok, %{binary_mode: "exclusive"}, _} =
               subscribe_and_join(socket, "room:mode-default")
    end

    test "a join may ask for multiplex" do
      socket = connect_with(%{"sub" => "alice"})

      assert {:ok, %{binary_mode: "multiplex"}, _} =
               subscribe_and_join(socket, "room:mode-multiplex", %{"binary_mode" => "multiplex"})
    end

    test "an unknown mode is refused" do
      socket = connect_with(%{"sub" => "alice"})

      assert {:error, %{reason: "invalid_binary_mode"}} =
               subscribe_and_join(socket, "room:mode-bogus", %{"binary_mode" => "duplex"})
    end

    test "a joiner asking for the other mode is refused and told the one in force" do
      assert {:ok, alice, _} =
               start_member("alice", "room:mode-clash", %{"binary_mode" => "multiplex"})

      # A push-to-talk client says nothing, so it asks for exclusive.
      assert {:error, %{reason: "binary_mode_mismatch", binary_mode: "multiplex"}} =
               start_member("goule", "room:mode-clash")

      # Agreeing with the topic is fine, whoever you are.
      assert {:ok, _bob, %{binary_mode: "multiplex"}} =
               start_member("bob", "room:mode-clash", %{"binary_mode" => "multiplex"})

      member_leave(alice)
    end

    test "the mode is forgotten once the topic is empty" do
      assert {:ok, alice, _} =
               start_member("alice", "room:mode-reset", %{"binary_mode" => "multiplex"})

      member_leave(alice)

      assert {:ok, _, %{binary_mode: "exclusive"}} = start_member("goule", "room:mode-reset")
    end
  end

  describe "multiplex" do
    test "the floor does not exist: acquiring and releasing are refused" do
      assert {:ok, alice, _} =
               start_member("alice", "room:mux-nofloor", %{"binary_mode" => "multiplex"})

      member_push(alice, "konet:floor_acquire", %{})

      assert_receive {:replied, "alice", :error,
                      %{reason: "floor_disabled", binary_mode: "multiplex"}}

      member_push(alice, "konet:floor_release", %{})
      assert_receive {:replied, "alice", :error, %{reason: "floor_disabled"}}

      # Not granted-and-ignored: never written at all, so no holder is
      # announced, swept, or reported to the webhook.
      assert Konet.Floor.holder("room:mux-nofloor") == nil
      refute_receive {:pushed, _, "konet:floor", _}
    end

    test "a member sends without taking anything first" do
      assert {:ok, alice, _} =
               start_member("alice", "room:mux-send", %{"binary_mode" => "multiplex"})

      assert {:ok, _bob, _} =
               start_member("bob", "room:mux-send", %{"binary_mode" => "multiplex"})

      member_push(alice, "a", {:binary, <<1, 2, 3>>})

      # Relayed with the sender in front: one length byte, then the id.
      assert_receive {:pushed, "bob", "a", {:binary, <<5, "alice", 1, 2, 3>>}}
      refute_receive {:replied, "alice", :error, _}
      # Still no echo: a call hears itself just as badly as a walkie-talkie.
      refute_receive {:pushed, "alice", "a", _}
    end

    test "two members sending at once are both relayed, in full and in order" do
      topic = "room:mux-duplex"
      mux = %{"binary_mode" => "multiplex"}

      assert {:ok, alice, _} = start_member("alice", topic, mux)
      assert {:ok, bob, _} = start_member("bob", topic, mux)
      # A third member hears both streams, which is where one overwriting the
      # other would show.
      assert {:ok, _carol, _} = start_member("carol", topic, mux)

      frames = 1..30

      # Interleaved from two processes, so neither stream waits for the other.
      # Identical payloads on purpose: only the sender prefix can tell them
      # apart, which is what carol needs to decode two streams at once.
      for n <- frames do
        member_push(alice, "a", {:binary, <<n>>})
        member_push(bob, "a", {:binary, <<n>>})
      end

      expected = Enum.to_list(frames)

      assert frames_from("bob", "alice", "a") == expected
      assert frames_from("alice", "bob", "a") == expected
      assert frames_from("carol", "alice", "a") == expected
      assert frames_from("carol", "bob", "a") == expected

      # Neither sender was refused, and neither heard itself.
      refute_received {:replied, _, :error, _}
      refute_received {:pushed, "alice", "a", _}
      refute_received {:pushed, "bob", "a", _}
    end

    test "a sender id that cannot fit the one-byte prefix is refused at join" do
      long = String.duplicate("x", 256)

      assert {:error, %{reason: "invalid_sender_id"}} =
               start_member(long, "room:mux-long-id", %{"binary_mode" => "multiplex"})

      # Exclusive frames carry no prefix, so the same id is fine there.
      assert {:ok, _, %{binary_mode: "exclusive"}} = start_member(long, "room:mux-long-id-ptt")
    end

    test "exclusive frames are relayed untouched, without a prefix" do
      # Goule's wire format does not change: the floor holder is the sender.
      assert {:ok, alice, _} = start_member("alice", "room:ptt-noprefix")
      assert {:ok, _bob, _} = start_member("bob", "room:ptt-noprefix")

      member_push(alice, "konet:floor_acquire", %{})
      assert_receive {:replied, "alice", :ok, _}
      member_push(alice, "a", {:binary, <<1, 2, 3>>})

      assert_receive {:pushed, "bob", "a", {:binary, <<1, 2, 3>>}}
    end

    test "leaving touches no floor" do
      assert {:ok, alice, _} =
               start_member("alice", "room:mux-leave", %{"binary_mode" => "multiplex"})

      assert {:ok, _bob, _} =
               start_member("bob", "room:mux-leave", %{"binary_mode" => "multiplex"})

      member_leave(alice)

      # An exclusive leave announces `holder: nil`; there is nothing to announce.
      refute_receive {:pushed, "bob", "konet:floor", _}
    end
  end

  describe "history replay" do
    test "late joiner receives buffered messages" do
      Application.put_env(:konet, :history_limit, 5)
      on_exit(fn -> Application.put_env(:konet, :history_limit, 0) end)

      Konet.History.record("replay-test", "update", %{"v" => 1})
      Konet.History.record("replay-test", "update", %{"v" => 2})

      socket = connect_with(%{"sub" => "late"})
      {:ok, _, _socket} = subscribe_and_join(socket, "room:replay-test")

      assert_push "konet:history", %{messages: [first, second]}
      assert first.payload == %{"v" => 1}
      assert second.payload == %{"v" => 2}
    end
  end
end
