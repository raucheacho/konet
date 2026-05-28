package config

import (
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
	AnonKey    string `toml:"anon_key"`
	ServiceKey string `toml:"service_key"`
	JWTSecret  string `toml:"jwt_secret"`
}

type StudioConfig struct {
	Enabled bool `toml:"enabled"`
	Port    int  `toml:"port"`
}

func Default() *Config {
	return &Config{
		Server: ServerConfig{
			Host: "localhost",
			Port: 4000,
			Mode: "docker",
		},
		Auth: AuthConfig{
			AnonKey:    "kt_anon_xxxxxxxxxxxxxxxxxxxx",
			ServiceKey: "kt_service_xxxxxxxxxxxxxxxxxx",
			JWTSecret:  "change-me-in-production-min-32-chars!!",
		},
		Studio: StudioConfig{
			Enabled: true,
			Port:    4001,
		},
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
	if c.Studio.Port != 0 && c.Studio.Port != c.Server.Port {
		return fmt.Sprintf("http://%s:%d/studio", c.Server.Host, c.Studio.Port)
	}
	return fmt.Sprintf("http://%s:%d/studio", c.Server.Host, c.Server.Port)
}
