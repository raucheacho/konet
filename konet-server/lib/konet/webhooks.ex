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

  **Concurrency is bounded.** At most `KONET_WEBHOOK_CONCURRENCY` deliveries
  (default 50) are in flight at once; an event arriving beyond that is dropped
  and logged rather than queued without limit. A wave of joins used to start
  one task and one HTTP request per event, with no ceiling at all.

  **A retry waits outside the pool.** Each attempt is its own short task, and
  the wait between attempts is a `Process.send_after/3` to this process, not a
  sleep inside the task — so a receiver that is down holds no slots while its
  retries are pending. The cost is that pending retries live in this process's
  timers and are lost if it crashes, which is no worse than the restart of the
  whole node they would also be lost to.

  **HTTPS is verified.** The request passes `verify: :verify_peer`, the OS trust
  store and a hostname check explicitly, rather than relying on `:httpc`
  defaults that have changed across OTP releases.

  Two things a receiver must still handle, because they are inherent rather
  than fixable here:

    * **Order is not guaranteed.** Each event is its own task, and a retry pushes
      one further back, so `member_joined` and `member_left` for the same user
      can arrive out of order. Do not treat arrival order as authoritative.
    * **Delivery is at-least-once.** A receiver that processed the request but
      answered slowly will see the retry. Each request carries an `id`, so
      handlers can be made idempotent on it.
  """
  use GenServer
  require Logger

  @default_retries 3
  @default_concurrency 50
  @base_backoff_ms 500
  @request_timeout_ms 5_000

  @doc "The delivery pool, started next to this process with a fixed ceiling."
  def pool_spec do
    {Task.Supervisor, name: Konet.WebhookSupervisor, max_children: concurrency()}
  end

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  def emit(event, data) do
    case Application.get_env(:konet, :webhook_url) do
      url when is_binary(url) and url != "" ->
        dispatch(url, event, encode(event, data), 1)

      _ ->
        :ok
    end
  end

  defp dispatch(url, event, body, attempt) do
    case Task.Supervisor.start_child(Konet.WebhookSupervisor, fn ->
           deliver(url, event, body, attempt)
         end) do
      {:ok, _pid} ->
        :ok

      {:error, :max_children} ->
        Logger.warning(
          "webhook #{event} dropped: #{concurrency()} deliveries already in flight " <>
            "(raise KONET_WEBHOOK_CONCURRENCY if the receiver can take more)"
        )

        :ok
    end
  end

  @impl true
  def init(_), do: {:ok, %{}}

  @impl true
  def handle_info({:retry, url, event, body, attempt}, state) do
    dispatch(url, event, body, attempt)
    {:noreply, state}
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

  defp concurrency, do: Application.get_env(:konet, :webhook_concurrency, @default_concurrency)

  defp deliver(url, event, body, attempt) do
    request = {String.to_charlist(url), signature_headers(body), ~c"application/json", body}

    case :httpc.request(:post, request, http_options(url), []) do
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

      # Scheduled, not slept: this task ends now and frees its slot.
      Process.send_after(__MODULE__, {:retry, url, event, body, attempt + 1}, backoff)
    end
  end

  defp http_options(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host} when is_binary(host) ->
        [timeout: @request_timeout_ms, ssl: ssl_options(host)]

      _ ->
        [timeout: @request_timeout_ms]
    end
  end

  defp ssl_options(host) do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      server_name_indication: String.to_charlist(host),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]
  end

  @doc false
  # Exposed for tests: the options a request to `url` is made with.
  def http_options_for(url), do: http_options(url)

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
