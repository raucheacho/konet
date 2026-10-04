defmodule KonetWeb.Studio.KeysLiveTest do
  use ExUnit.Case, async: false

  alias KonetWeb.Studio.KeysLive

  # The Keys page used to show the service key and, one click away, the JWT
  # secret — which signs any token — to anyone, whenever no Studio password was
  # set. And rotate on a click, locking every client out.

  setup do
    Application.put_env(:konet, :service_key, "service-key-0123456789")

    on_exit(fn ->
      Application.put_env(:konet, :service_key, nil)
      Application.put_env(:konet, :studio_password, nil)
    end)
  end

  defp mount do
    {:ok, socket} = KeysLive.mount(%{}, %{}, %Phoenix.LiveView.Socket{})
    socket
  end

  defp html(socket) do
    socket.assigns
    |> Map.put(:flash, %{})
    |> KeysLive.render()
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  describe "without a Studio password" do
    test "the service key and the JWT secret are not shown" do
      socket = mount()
      {:noreply, socket} = KeysLive.handle_event("toggle_secret", %{}, socket)
      page = html(socket)

      refute page =~ "service-key-0123456789"
      refute page =~ Application.fetch_env!(:konet, :jwt_secret)
      assert page =~ "KONET_STUDIO_PASSWORD"
    end

    test "rotation is refused" do
      secret = Application.fetch_env!(:konet, :jwt_secret)
      {:noreply, socket} = KeysLive.handle_event("rotate", %{}, mount())

      assert Application.fetch_env!(:konet, :jwt_secret) == secret
      refute socket.assigns.rotated
    end
  end

  test "with a Studio password, the keys are shown to whoever signed in" do
    Application.put_env(:konet, :studio_password, "pw")
    socket = mount()
    {:noreply, socket} = KeysLive.handle_event("toggle_secret", %{}, socket)
    page = html(socket)

    assert page =~ "service-key-0123456789"
    assert page =~ Application.fetch_env!(:konet, :jwt_secret)
  end
end
