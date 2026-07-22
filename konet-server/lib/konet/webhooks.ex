defmodule Konet.Webhooks do
  @moduledoc """
  Fires HTTP POST notifications to a configured URL on channel lifecycle events,
  so backends can react to realtime activity without holding a WebSocket open.

  Disabled unless `KONET_WEBHOOK_URL` is set. Events:

    * `channel_occupied` — first member joined a room
    * `channel_vacated`  — last member left a room
    * `member_joined` / `member_left`

  If `KONET_WEBHOOK_SECRET` is set, each request carries an
  `x-konet-signature: sha256=<hex>` header (HMAC-SHA256 of the raw body) the
  receiver can use to verify authenticity.

  Delivery is fire-and-forget from a supervised task: a slow or down receiver
  never blocks channel operations. Failures are logged, not retried.
  """
  require Logger

  def emit(event, data) do
    case Application.get_env(:konet, :webhook_url) do
      url when is_binary(url) and url != "" ->
        Task.Supervisor.start_child(Konet.TaskSupervisor, fn -> deliver(url, event, data) end)
        :ok

      _ ->
        :ok
    end
  end

  defp deliver(url, event, data) do
    body =
      Jason.encode!(%{
        event: event,
        data: data,
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
      })

    request = {String.to_charlist(url), signature_headers(body), ~c"application/json", body}

    case :httpc.request(:post, request, [timeout: 5_000], []) do
      {:ok, {{_, status, _}, _, _}} when status in 200..299 ->
        :ok

      {:ok, {{_, status, _}, _, _}} ->
        Logger.warning("webhook #{event} -> #{url} returned #{status}")

      {:error, reason} ->
        Logger.warning("webhook #{event} -> #{url} failed: #{inspect(reason)}")
    end
  end

  defp signature_headers(body) do
    case Application.get_env(:konet, :webhook_secret) do
      secret when is_binary(secret) and secret != "" ->
        signature = :crypto.mac(:hmac, :sha256, secret, body) |> Base.encode16(case: :lower)
        [{~c"x-konet-signature", String.to_charlist("sha256=" <> signature)}]

      _ ->
        []
    end
  end
end
