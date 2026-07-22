package config

import (
	"testing"
)

func TestDefaultGeneratesSecretKeyBase(t *testing.T) {
	cfg := Default()
	if len(cfg.Auth.SecretKeyBase) != 64 {
		t.Fatalf("expected a 64-char secret_key_base, got %d chars", len(cfg.Auth.SecretKeyBase))
	}
	if cfg.Auth.SecretKeyBase == Default().Auth.SecretKeyBase {
		t.Fatal("expected each Default() call to generate a distinct secret")
	}
}

func TestSaveLoadRoundtrip(t *testing.T) {
	dir := t.TempDir()

	cfg := Default()
	cfg.Auth.JWTSecret = "roundtrip-secret"
	cfg.Studio.Password = "studio-pass"

	if err := Save(cfg, dir); err != nil {
		t.Fatalf("save: %v", err)
	}

	loaded, err := Load(dir)
	if err != nil {
		t.Fatalf("load: %v", err)
	}

	if loaded.Auth.JWTSecret != "roundtrip-secret" {
		t.Errorf("jwt_secret not preserved: %q", loaded.Auth.JWTSecret)
	}
	if loaded.Auth.SecretKeyBase != cfg.Auth.SecretKeyBase {
		t.Error("secret_key_base not preserved across save/load")
	}
	if loaded.Studio.Password != "studio-pass" {
		t.Errorf("studio password not preserved: %q", loaded.Studio.Password)
	}
}

func TestStudioURLUsesServerPort(t *testing.T) {
	cfg := Default()
	if got, want := cfg.StudioURL(), "http://localhost:4000/studio"; got != want {
		t.Errorf("StudioURL() = %q, want %q", got, want)
	}
}
