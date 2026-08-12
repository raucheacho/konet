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

    test "rejects an expired token" do
      {:ok, token} =
        Auth.sign(%{"sub" => "user-1", "exp" => System.system_time(:second) - 60})

      assert {:error, _} = Auth.verify(token)
    end

    test "accepts a token whose expiry is still ahead" do
      {:ok, token} =
        Auth.sign(%{"sub" => "user-1", "exp" => System.system_time(:second) + 3600})

      assert {:ok, claims} = Auth.verify(token)
      assert claims["sub"] == "user-1"
    end

    # The anon and service keys are signed without any expiry, and every
    # existing deployment holds one. Enforcing "exp" unconditionally would
    # invalidate them all on upgrade.
    test "still accepts a token that carries no expiry" do
      {:ok, token} = Auth.sign(%{"role" => "anon"})

      assert {:ok, claims} = Auth.verify(token)
      assert claims["role"] == "anon"
      refute Map.has_key?(claims, "exp")
    end

    test "rejects a token whose expiry is not a number" do
      {:ok, token} = Auth.sign(%{"sub" => "user-1", "exp" => "bientôt"})

      assert {:error, _} = Auth.verify(token)
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

  describe "rotate!/0 persistence" do
    setup do
      original = Application.get_env(:konet, :jwt_secret)

      on_exit(fn ->
        Application.put_env(:konet, :jwt_secret, original)
        Application.put_env(:konet, :anon_key, nil)
        Application.put_env(:konet, :service_key, nil)
        Application.put_env(:konet, :secret_file, nil)
      end)

      :ok
    end

    test "reports in-memory only when no secret file is configured" do
      Application.put_env(:konet, :secret_file, nil)

      result = Auth.rotate!()

      refute result.persisted
      assert result.path == nil
      assert result.error == nil
    end

    test "writes the new secret to the configured file, owner-only" do
      path = Path.join(System.tmp_dir!(), "konet-secret-#{System.unique_integer([:positive])}")
      Application.put_env(:konet, :secret_file, path)
      on_exit(fn -> File.rm(path) end)

      result = Auth.rotate!()

      assert result.persisted
      assert result.path == path
      assert File.read!(path) == result.jwt_secret

      # The file is the signing secret in plain text; anything wider than
      # owner-only defeats the point of persisting it.
      assert File.stat!(path).mode |> Bitwise.band(0o777) == 0o600
    end

    test "reports the failure instead of claiming success when the path is unwritable" do
      path = Path.join(System.tmp_dir!(), "konet-missing-dir-#{System.unique_integer([:positive])}/secret")
      Application.put_env(:konet, :secret_file, path)

      result = Auth.rotate!()

      # The rotation itself still happened — the keys are live in this process.
      assert {:ok, %{"role" => "anon"}} = Auth.verify(result.anon_key)

      refute result.persisted
      assert result.path == path
      assert is_binary(result.error)
    end

    test "a persisted rotation is what a restart would read back" do
      path = Path.join(System.tmp_dir!(), "konet-secret-#{System.unique_integer([:positive])}")
      Application.put_env(:konet, :secret_file, path)
      on_exit(fn -> File.rm(path) end)

      result = Auth.rotate!()

      # Simulates the next boot: runtime.exs reads the file and configures it.
      Application.put_env(:konet, :jwt_secret, File.read!(path) |> String.trim())

      assert {:ok, %{"role" => "service"}} = Auth.verify(result.service_key)
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
