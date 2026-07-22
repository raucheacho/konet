defmodule KonetWeb.Studio.Auth do
  import Phoenix.LiveView

  def on_mount(:default, _params, session, socket) do
    cond do
      not Konet.Auth.studio_auth_enabled?() -> {:cont, socket}
      session["studio_authenticated"] -> {:cont, socket}
      true -> {:halt, redirect(socket, to: "/studio/login")}
    end
  end
end
