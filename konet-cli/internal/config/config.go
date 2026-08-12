package config

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"strconv"

	"github.com/BurntSushi/toml"
)

const ConfigFileName = "konet.config.toml"

// DefaultImage is the published server image. Overridable per project so a
// contributor can point the CLI at a locally built one — without that, the CLI
// could only ever exercise server code that had already shipped.
const DefaultImage = "ghcr.io/raucheacho/konet:latest"

type Config struct {
	Server   ServerConfig   `toml:"server"`
	Auth     AuthConfig     `toml:"auth"`
	Studio   StudioConfig   `toml:"studio"`
	Limits   LimitsConfig   `toml:"limits"`
	History  HistoryConfig  `toml:"history"`
	Webhooks WebhooksConfig `toml:"webhooks"`
}

type ServerConfig struct {
	Host string `toml:"host"`
	Port int    `toml:"port"`
	// Mode is "docker". The field is kept because existing config files carry
	// it, but it has one valid value: the CLI's whole job is running the
	// published container. It used to advertise "native" too, which was never
	// implemented — to run the server without Docker, run it from source with
	// `mix phx.server`.
	Mode string `toml:"mode"`
	// Image the container is started from. Empty means DefaultImage.
	Image string `toml:"image"`
	// AllowedOrigins is the WebSocket origin check: "*" (or empty) accepts any
	// origin, otherwise a comma-separated list.
	AllowedOrigins string `toml:"allowed_origins"`
}

type AuthConfig struct {
	AnonKey       string `toml:"anon_key"`
	ServiceKey    string `toml:"service_key"`
	JWTSecret     string `toml:"jwt_secret"`
	SecretKeyBase string `toml:"secret_key_base"`
}

// The Studio is served by the Konet server itself on the server port — it has
// no separate listener, so there is deliberately no port field here.
type StudioConfig struct {
	Password string `toml:"password"` // optional; empty disables the Studio login (fine for local dev)
}

// LimitsConfig mirrors the server's rate limits. Zero means "leave the server's
// own default alone" rather than "no limit".
type LimitsConfig struct {
	MessagesPerSecond    int `toml:"messages_per_second"`
	ConnectionsPerMinute int `toml:"connections_per_minute"`
	BinaryPerSecond      int `toml:"binary_per_second"`
}

// HistoryConfig controls the replay buffer. Limit 0 disables it, which is also
// the server's default.
type HistoryConfig struct {
	Limit      int `toml:"limit"`
	TTLSeconds int `toml:"ttl_seconds"`
}

type WebhooksConfig struct {
	URL    string `toml:"url"`
	Secret string `toml:"secret"`
}

func Default() *Config {
	return &Config{
		Server: ServerConfig{
			Host:           "localhost",
			Port:           4000,
			Mode:           "docker",
			Image:          DefaultImage,
			AllowedOrigins: "*",
		},
		Auth: AuthConfig{
			// Left empty rather than filled with a kt_anon_xxx placeholder: that
			// placeholder is not a JWT, so a server started before
			// `konet keys generate` got a token it could only reject, and the
			// failure surfaced as an unexplained "unauthorized" at connect time.
			AnonKey:       "",
			ServiceKey:    "",
			JWTSecret:     GenerateSecret(64),
			SecretKeyBase: GenerateSecret(64),
		},
		Studio:   StudioConfig{},
		Limits:   LimitsConfig{},
		History:  HistoryConfig{},
		Webhooks: WebhooksConfig{},
	}
}

func Load(dir string) (*Config, error) {
	path := filepath.Join(dir, ConfigFileName)
	var cfg Config
	if _, err := toml.DecodeFile(path, &cfg); err != nil {
		return nil, fmt.Errorf("cannot read %s: %w", path, err)
	}
	return &cfg, nil
}

func LoadFromCWD() (*Config, error) {
	cwd, err := os.Getwd()
	if err != nil {
		return nil, err
	}
	return Load(cwd)
}

func Save(cfg *Config, dir string) error {
	path := filepath.Join(dir, ConfigFileName)
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	defer f.Close()

	enc := toml.NewEncoder(f)
	return enc.Encode(cfg)
}

func (c *Config) ServerBaseURL() string {
	return fmt.Sprintf("http://%s:%d", c.Server.Host, c.Server.Port)
}

func (c *Config) StudioURL() string {
	return fmt.Sprintf("http://%s:%d/studio", c.Server.Host, c.Server.Port)
}

// Image returns the image to run, falling back to the published one.
func (c *Config) Image() string {
	if c.Server.Image == "" {
		return DefaultImage
	}
	return c.Server.Image
}

// ServerEnv builds the container environment.
//
// Everything the server reads at runtime is representable here. It used to be a
// hardcoded list of eight variables, which left history replay, origin
// checking, the rate limits and webhooks unreachable from the CLI — so a
// configuration could not be reproduced locally at all.
func (c *Config) ServerEnv() []string {
	env := []string{
		"MIX_ENV=prod",
		"PHX_SERVER=true",
		fmt.Sprintf("KONET_HOST=%s", c.Server.Host),
		fmt.Sprintf("KONET_PORT=%d", c.Server.Port),
		fmt.Sprintf("KONET_JWT_SECRET=%s", c.Auth.JWTSecret),
		fmt.Sprintf("SECRET_KEY_BASE=%s", c.Auth.SecretKeyBase),
		fmt.Sprintf("KONET_ANON_KEY=%s", c.Auth.AnonKey),
		fmt.Sprintf("KONET_SERVICE_KEY=%s", c.Auth.ServiceKey),
		fmt.Sprintf("KONET_STUDIO_PASSWORD=%s", c.Studio.Password),
	}

	if c.Server.AllowedOrigins != "" {
		env = append(env, "KONET_ALLOWED_ORIGINS="+c.Server.AllowedOrigins)
	}

	// Zero values are left out so the server keeps its own defaults, rather than
	// the CLI silently pinning every knob to 0.
	env = appendIfSet(env, "KONET_RATE_LIMIT", c.Limits.MessagesPerSecond)
	env = appendIfSet(env, "KONET_CONN_RATE_LIMIT", c.Limits.ConnectionsPerMinute)
	env = appendIfSet(env, "KONET_RATE_LIMIT_BINARY", c.Limits.BinaryPerSecond)
	env = appendIfSet(env, "KONET_HISTORY_TTL", c.History.TTLSeconds)

	// History is the exception: 0 is a meaningful value (disabled) and also the
	// server default, so passing it explicitly costs nothing and makes the
	// running container match the file.
	env = append(env, fmt.Sprintf("KONET_HISTORY_LIMIT=%d", c.History.Limit))

	if c.Webhooks.URL != "" {
		env = append(env, "KONET_WEBHOOK_URL="+c.Webhooks.URL)
	}
	if c.Webhooks.Secret != "" {
		env = append(env, "KONET_WEBHOOK_SECRET="+c.Webhooks.Secret)
	}

	return env
}

func appendIfSet(env []string, key string, value int) []string {
	if value <= 0 {
		return env
	}
	return append(env, key+"="+strconv.Itoa(value))
}

// GenerateSecret returns a random hex string of length n (n/2 random bytes).
func GenerateSecret(n int) string {
	b := make([]byte, n/2)
	if _, err := rand.Read(b); err != nil {
		// crypto/rand failing is not something a config file can recover from:
		// every secret this package produces would be predictable.
		panic("konet: cannot read from the system CSPRNG: " + err.Error())
	}
	return hex.EncodeToString(b)
}
