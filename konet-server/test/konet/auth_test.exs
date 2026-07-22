defmodule Konet.AuthTest do
  use ExUnit.Case, async: false

  alias Konet.Auth

  describe "sign/verify" do
    test "round-trips claims" do
      {:ok, token} = Auth.sign(%{"role" => "anon", "sub" => "user-1"})
      assert {:ok, claims} = Auth.verify(token)
      assert claims["role"] == "anon"
      assert claims["sub"] == "user-1"
      assert is_integer(claims["iat"])
    end

    test "rejects garbage" do
      assert {:error, _} = Auth.verify("not-a-jwt")
      assert {:error, :invalid_token} = Auth.verify(nil)
    end

    test "role helpers" do
      assert Auth.anon?(%{"role" => "anon"})
      assert Auth.service?(%{"role" => "service"})
      refute Auth.service?(%{"role" => "anon"})
      assert Auth.user_id(%{"sub" => "u1"}) == "u1"
    end
  end

  describe "rotate!/0" do
    test "invalidates previously issued tokens and re-signs keys" do
      original = Application.get_env(:konet, :jwt_secret)

      on_exit(fn ->
        Application.put_env(:konet, :jwt_secret, original)
        Application.put_env(:konet, :anon_key, nil)
        Application.put_env(:konet, :service_key, nil)
      end)

      {:ok, old_token} = Auth.sign(%{"role" => "service"})
      assert {:ok, _} = Auth.verify(old_token)

      %{anon_key: anon, service_key: service} = Auth.rotate!()

      assert {:error, _} = Auth.verify(old_token)
      assert {:ok, %{"role" => "anon"}} = Auth.verify(anon)
      assert {:ok, %{"role" => "service"}} = Auth.verify(service)
    end
  end

  describe "studio password" do
    test "disabled when unset" do
      refute Auth.studio_auth_enabled?()
      refute Auth.verify_studio_password("anything")
    end

    test "enabled and constant-time-checked when set" do
      Application.put_env(:konet, :studio_password, "s3cret")
      on_exit(fn -> Application.put_env(:konet, :studio_password, nil) end)

      assert Auth.studio_auth_enabled?()
      assert Auth.verify_studio_password("s3cret")
      refute Auth.verify_studio_password("wrong")
      refute Auth.verify_studio_password(nil)
    end
  end
end
