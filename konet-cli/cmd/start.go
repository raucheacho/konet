package cmd

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"time"

	"github.com/konet-io/konet-cli/internal/config"
	"github.com/konet-io/konet-cli/internal/docker"
	"github.com/spf13/cobra"
)

var startCmd = &cobra.Command{
	Use:   "start",
	Short: "Start the Konet server",
	RunE: func(cmd *cobra.Command, args []string) error {
		cfg, err := config.LoadFromCWD()
		if err != nil {
			return fmt.Errorf("no konet.config.toml found — run `konet init` first")
		}

		switch cfg.Server.Mode {
		case "docker":
			return startDocker(cfg)
		case "native":
			return fmt.Errorf("native mode not yet supported — use mode = \"docker\" in your config")
		default:
			return fmt.Errorf("unknown mode %q — use \"docker\" or \"native\"", cfg.Server.Mode)
		}
	},
}

func startDocker(cfg *config.Config) error {
	ctx := context.Background()

	cli, err := docker.New()
	if err != nil {
		return fmt.Errorf("docker not available: %w\nMake sure Docker is running.", err)
	}
	defer cli.Close()

	running, id, err := cli.IsRunning(ctx)
	if err != nil {
		return err
	}
	if running {
		fmt.Printf("✓ Konet is already running (container %s)\n", id)
		fmt.Printf("  WebSocket  ws://%s:%d/socket\n", cfg.Server.Host, cfg.Server.Port)
		fmt.Printf("  Studio     %s\n", cfg.StudioURL())
		return nil
	}

	image := docker.ImageName
	exists, err := cli.ImageExists(ctx, image)
	if err != nil {
		return fmt.Errorf("cannot check local images: %w", err)
	}
	if exists {
		fmt.Printf("✓ Image %s already cached\n", image)
	} else {
		fmt.Printf("Pulling image %s...\n", image)
		if err := cli.Pull(ctx, image); err != nil {
			return fmt.Errorf("image pull failed: %w", err)
		}
	}

	secretKey := generateSecret(64)

	fmt.Printf("Starting konet-server on port %d...\n", cfg.Server.Port)
	if err := cli.Start(ctx, docker.StartOptions{
		Image:      image,
		Port:       cfg.Server.Port,
		JWTSecret:  cfg.Auth.JWTSecret,
		AnonKey:    cfg.Auth.AnonKey,
		ServiceKey: cfg.Auth.ServiceKey,
		SecretKey:  secretKey,
	}); err != nil {
		return fmt.Errorf("container start failed: %w", err)
	}

	// Give the server a moment to initialize
	fmt.Print("Waiting for server to be ready.")
	time.Sleep(docker.WaitDuration())
	fmt.Println(" ✓")

	fmt.Println("\n✓ Konet is running!")
	fmt.Printf("  WebSocket  ws://%s:%d/socket\n", cfg.Server.Host, cfg.Server.Port)
	fmt.Printf("  REST API   %s/api\n", cfg.ServerBaseURL())
	fmt.Printf("  Studio     %s\n", cfg.StudioURL())
	fmt.Println("\n  Run `konet logs --follow` to stream logs")
	return nil
}

func generateSecret(n int) string {
	b := make([]byte, n/2)
	rand.Read(b)
	return hex.EncodeToString(b)
}
