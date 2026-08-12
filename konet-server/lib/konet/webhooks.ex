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
  never blocks channel operations. A failed delivery is **retried** with
  exponential backoff up to `KONET_WEBHOOK_RETRIES` attempts — a receiver
  restarting used to lose the events outright.

  Two things a receiver must still handle, because they are inherent rather
  than fixable here:

    * **Order is not guaranteed.** Each event is its own task, and a retry pushes
      one further back, so `member_joined` and `member_left` for the same user
      can arrive out of order. Do not treat arrival order as authoritative.
    * **Delivery is at-least-once.** A receiver that processed the request but
      answered slowly will see the retry. Each request carries an `id`, so
      handlers can be made idempotent on it.
  """
  require Logger

  @default_retries 3
  @base_backoff_ms 500
  @request_timeout_ms 5_000

  def emit(event, data) do
    case Application.get_env(:konet, :webhook_url) do
      url when is_binary(url) and url != "" ->
        payload = encode(event, data)
        Task.Supervisor.start_child(Konet.TaskSupervisor, fn -> deliver(url, event, payload) end)
        :ok

      _ ->
        :ok
    end
  end

  defp encode(event, data) do
    Jason.encode!(%{
      # Stable across retries, so a receiver can deduplicate on it.
      id: Base.encode16(:crypto.strong_rand_bytes(8), case: :lower),
      event: event,
      data: data,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    })
  end

  defp max_retries, do: Application.get_env(:konet, :webhook_retries, @default_retries)

  defp deliver(url, event, body, attempt \\ 1) do
    request = {String.to_charlist(url), signature_headers(body), ~c"application/json", body}

    case :httpc.request(:post, request, [timeout: @request_timeout_ms], []) do
      {:ok, {{_, status, _}, _, _}} when status in 200..299 ->
        :ok

      {:ok, {{_, status, _}, _, _}} when status in 400..499 and status != 408 and status != 429 ->
        # The receiver understood and refused. Retrying a 4xx just repeats the
        # same rejection; 408 and 429 are the two that mean "later", not "no".
        Logger.warning("webhook #{event} -> #{url} returned #{status}, not retrying")

      {:ok, {{_, status, _}, _, _}} ->
        retry_or_give_up(url, event, body, attempt, "HTTP #{status}")

      {:error, reason} ->
        retry_or_give_up(url, event, body, attempt, inspect(reason))
    end
  end

  defp retry_or_give_up(url, event, body, attempt, why) do
    if attempt >= max_retries() do
      Logger.warning("webhook #{event} -> #{url} failed after #{attempt} attempts: #{why}")
    else
      backoff = @base_backoff_ms * :math.pow(2, attempt - 1)
      backoff = trunc(backoff)

      Logger.info(
        "webhook #{event} -> #{url} failed (#{why}), retrying in #{backoff}ms " <>
          "(attempt #{attempt + 1}/#{max_retries()})"
      )

      Process.sleep(backoff)
      deliver(url, event, body, attempt + 1)
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
