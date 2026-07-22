package config

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"

	"github.com/BurntSushi/toml"
)

const ConfigFileName = "konet.config.toml"

type Config struct {
	Server ServerConfig `toml:"server"`
	Auth   AuthConfig   `toml:"auth"`
	Studio StudioConfig `toml:"studio"`
}

type ServerConfig struct {
	Host string `toml:"host"`
	Port int    `toml:"port"`
	Mode string `toml:"mode"` // "docker" | "native"
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

func Default() *Config {
	return &Config{
		Server: ServerConfig{
			Host: "localhost",
			Port: 4000,
			Mode: "docker",
		},
		Auth: AuthConfig{
			AnonKey:       "kt_anon_xxxxxxxxxxxxxxxxxxxx",
			ServiceKey:    "kt_service_xxxxxxxxxxxxxxxxxx",
			JWTSecret:     "change-me-in-production-min-32-chars!!",
			SecretKeyBase: GenerateSecret(64),
		},
		Studio: StudioConfig{},
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

// GenerateSecret returns a random hex string of length n (n/2 random bytes).
func GenerateSecret(n int) string {
	b := make([]byte, n/2)
	rand.Read(b)
	return hex.EncodeToString(b)
}
