defmodule KonetWeb.Router do
  use KonetWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {KonetWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  scope "/api", KonetWeb do
    pipe_through :api

    get "/health", AdminController, :health
    get "/channels", AdminController, :channels
    get "/presence/:channel", AdminController, :presence
    post "/broadcast", AdminController, :broadcast
    get "/metrics", AdminController, :metrics
  end

  scope "/studio", KonetWeb do
    pipe_through :browser

    get "/login", StudioAuthController, :new
    post "/login", StudioAuthController, :create
    post "/logout", StudioAuthController, :delete
  end

  pipeline :require_studio_auth do
    plug :check_studio_auth
  end

  scope "/studio", KonetWeb do
    pipe_through [:browser, :require_studio_auth]

    live_session :studio,
      layout: {KonetWeb.Layouts, :studio},
      on_mount: KonetWeb.Studio.Auth do
      live "/", Studio.OverviewLive
      live "/overview", Studio.OverviewLive
      live "/channels", Studio.ChannelsLive
      live "/presence", Studio.PresenceLive
      live "/logs", Studio.LogsLive
      live "/broadcast", Studio.BroadcastLive
      live "/keys", Studio.KeysLive
    end
  end

  defp check_studio_auth(conn, _opts) do
    cond do
      not Konet.Auth.studio_auth_enabled?() -> conn
      get_session(conn, :studio_authenticated) -> conn
      true -> conn |> redirect(to: "/studio/login") |> halt()
    end
  end

  scope "/", KonetWeb do
    pipe_through :api

    get "/", AdminController, :root
    get "/metrics", AdminController, :prometheus
  end
end
