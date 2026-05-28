defmodule Konet.Auth do
  @moduledoc """
  JWT authentication. Supports anon, service, and user-issued tokens.
  All tokens are HMAC-SHA256 signed with the configured jwt_secret.
  """

  def verify(token) when is_binary(token) do
    signer = Joken.Signer.create("HS256", jwt_secret())

    case Joken.verify_and_validate(%{}, token, signer) do
      {:ok, claims} -> {:ok, claims}
      {:error, reason} -> {:error, reason}
    end
  end

  def verify(_), do: {:error, :invalid_token}

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

  defp jwt_secret do
    Application.get_env(:konet, :jwt_secret, "change-me-in-production-min-32-chars!!")
  end
end
