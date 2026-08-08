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

    test "trailing wildcard grants a namespace" do
      socket = connect_with(%{"sub" => "ns", "channels" => ["room:user-42:*"]})
      assert {:ok, _, _socket} = subscribe_and_join(socket, "room:user-42:inbox")

      socket2 = connect_with(%{"sub" => "ns", "channels" => ["room:user-42:*"]})
      assert {:error, %{reason: "unauthorized"}} = subscribe_and_join(socket2, "room:user-43:inbox")
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
