defmodule Konet.Auth do
  @moduledoc """
  JWT authentication. Supports anon, service, and user-issued tokens.
  All tokens are HMAC-SHA256 signed with the configured jwt_secret.
  """
  require Logger

  def verify(token) when is_binary(token) do
    signer = Joken.Signer.create("HS256", jwt_secret())

    case Joken.verify_and_validate(token_config(), token, signer) do
      {:ok, claims} -> {:ok, claims}
      {:error, reason} -> {:error, reason}
    end
  end

  def verify(_), do: {:error, :invalid_token}

  # Expiry is enforced only when the token carries an "exp" claim.
  #
  # That conditional is not laziness: the anon and service keys minted by
  # sign/1 have no "exp" at all, and every existing deployment holds one.
  # Making the claim mandatory would invalidate all of them on upgrade. Joken
  # skips validators for claims absent from the token, which gives exactly the
  # semantics wanted here — a token that declares an expiry is held to it, one
  # that never declared any keeps working.
  #
  # No generator is attached, so signing is unchanged: sign/1 still adds only
  # "iat", and callers decide whether to include an expiry.
  defp token_config do
    Joken.Config.add_claim(
      %{},
      "exp",
      nil,
      fn exp, _claims, _context ->
        is_integer(exp) and exp > System.system_time(:second)
      end
    )
  end

  def sign(claims) when is_map(claims) do
    signer = Joken.Signer.create("HS256", jwt_secret())
    extra = Map.put_new(claims, "iat", System.system_time(:second))

    case Joken.encode_and_sign(extra, signer) do
      {:ok, token, _} -> {:ok, token}
      {:error, reason} -> {:error, reason}
    end
  end

  def anon?(claims), do: Map.get(claims, "role") == "anon"
  def service?(claims), do: Map.get(claims, "role") == "service"
  def user_id(claims), do: Map.get(claims, "sub")

  @doc "Whether a Studio password is configured. When false, the Studio is unauthenticated."
  def studio_auth_enabled? do
    case studio_password() do
      p when is_binary(p) and p != "" -> true
      _ -> false
    end
  end

  @doc "Constant-time check of a submitted Studio password against the configured one."
  def verify_studio_password(submitted) when is_binary(submitted) do
    case studio_password() do
      p when is_binary(p) and p != "" -> Plug.Crypto.secure_compare(p, submitted)
      _ -> false
    end
  end

  def verify_studio_password(_), do: false

  @doc """
  Rotates the JWT signing secret and re-signs anon_key/service_key with it.

  This immediately invalidates every previously issued token — there is no way
  to revoke a single key without the others, since they all share one secret.

  Durability depends on `KONET_SECRET_FILE`:

    * **set** — the new secret is written there (mode 0600) and read back on the
      next boot, so the rotation survives a restart. Mount it on a volume.
    * **unset** — the secret lives only in this process. A restart silently
      reverts to the old one, locking out any client that stored the new anon
      key. That was the only behaviour available before, and it is why the
      return value now says which happened.

  Returns `%{jwt_secret:, anon_key:, service_key:, persisted:, path:, error:}`.
  """
  def rotate! do
    new_secret = :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)
    Application.put_env(:konet, :jwt_secret, new_secret)

    {:ok, anon_key} = sign(%{"role" => "anon"})
    {:ok, service_key} = sign(%{"role" => "service"})

    Application.put_env(:konet, :anon_key, anon_key)
    Application.put_env(:konet, :service_key, service_key)

    {persisted, path, error} = persist_secret(new_secret)

    %{
      jwt_secret: new_secret,
      anon_key: anon_key,
      service_key: service_key,
      persisted: persisted,
      path: path,
      error: error
    }
  end

  @doc "Path the signing secret is persisted to, or nil when rotation is in-memory only."
  def secret_file, do: Application.get_env(:konet, :secret_file)

  defp persist_secret(secret) do
    case secret_file() do
      path when is_binary(path) and path != "" ->
        case write_secret(path, secret) do
          :ok ->
            Logger.info("konet: signing secret rotated and persisted to #{path}")
            {true, path, nil}

          {:error, reason} ->
            Logger.error(
              "konet: signing secret rotated but could NOT be written to #{path}: " <>
                "#{:file.format_error(reason)}. It will be lost on restart."
            )

            {false, path, :file.format_error(reason) |> to_string()}
        end

      _ ->
        {false, nil, nil}
    end
  end

  defp write_secret(path, secret) do
    with :ok <- File.write(path, secret),
         # The file is the signing secret in plain text; anything wider than
         # owner-only defeats the point of persisting it at all.
         :ok <- File.chmod(path, 0o600) do
      :ok
    end
  end

  defp jwt_secret do
    Application.get_env(:konet, :jwt_secret, "change-me-in-production-min-32-chars!!")
  end

  defp studio_password do
    Application.get_env(:konet, :studio_password)
  end
end
