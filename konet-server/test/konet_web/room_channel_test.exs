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

    test "names binary frames explicitly rather than crashing" do
      socket = connect_with(%{"sub" => "sender"})
      {:ok, _, socket} = subscribe_and_join(socket, "room:binary")

      # What Phoenix's v2 serializer hands the channel for a binary frame.
      ref = push(socket, "audio", {:binary, <<1, 2, 3>>})
      assert_reply ref, :error, %{reason: "binary_unsupported", event: "audio"}
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
