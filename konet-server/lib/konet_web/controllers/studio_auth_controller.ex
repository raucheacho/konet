defmodule KonetWeb.StudioAuthController do
  use KonetWeb, :controller

  def new(conn, _params) do
    if Konet.Auth.studio_auth_enabled?() do
      render_login(conn, nil)
    else
      redirect(conn, to: "/studio")
    end
  end

  def create(conn, params) do
    password = Map.get(params, "password", "")

    if Konet.Auth.verify_studio_password(password) do
      conn
      |> put_session(:studio_authenticated, true)
      |> redirect(to: "/studio")
    else
      render_login(conn, "Invalid password")
    end
  end

  def delete(conn, _params) do
    conn
    |> delete_session(:studio_authenticated)
    |> redirect(to: "/studio/login")
  end

  defp render_login(conn, error) do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, login_page(error))
  end

  defp login_page(error) do
    error_html =
      if error, do: ~s(<div class="result-banner result-err">#{error}</div>), else: ""

    csrf_token = Plug.CSRFProtection.get_csrf_token()

    """
    <!doctype html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>Konet Studio — Sign in</title>
        <link href="https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;500;700&family=Syne:wght@400;600;700;800&display=swap" rel="stylesheet" />
        <link rel="stylesheet" href="/assets/app.css" />
      </head>
      <body>
        <div class="page" style="max-width: 380px; margin: 14vh auto; float: none;">
          <h2 class="page-title">Konet Studio</h2>
          <p class="subtitle muted">Enter the Studio password to continue.</p>
          #{error_html}
          <form method="post" action="/studio/login">
            <input type="hidden" name="_csrf_token" value="#{csrf_token}" />
            <div class="form-field">
              <label class="form-label">Password</label>
              <input type="password" name="password" class="form-input mono" autocomplete="current-password" autofocus />
            </div>
            <button type="submit" class="btn btn-primary" style="margin-top: 1rem;">Sign in</button>
          </form>
        </div>
      </body>
    </html>
    """
  end
end
