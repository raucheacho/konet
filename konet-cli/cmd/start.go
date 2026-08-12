package cmd

import (
	"context"
	"fmt"
	"os"
	"time"

	"github.com/raucheacho/konet/konet-cli/internal/api"
	"github.com/raucheacho/konet/konet-cli/internal/config"
	"github.com/raucheacho/konet/konet-cli/internal/docker"
	"github.com/spf13/cobra"
)

var startImage string

var startCmd = &cobra.Command{
	Use:   "start",
	Short: "Start the Konet server",
	RunE: func(cmd *cobra.Command, args []string) error {
		cfg, err := config.LoadFromCWD()
		if err != nil {
			return fmt.Errorf("no konet.config.toml found — run `konet init` first")
		}

		switch cfg.Server.Mode {
		case "docker", "":
			return startDocker(cfg)
		case "native":
			return fmt.Errorf(
				"mode = \"native\" is not implemented — the CLI only runs the server in Docker.\n" +
					"Set mode = \"docker\" in konet.config.toml, or run the server from source with `mix phx.server`")
		default:
			return fmt.Errorf("unknown mode %q — use \"docker\"", cfg.Server.Mode)
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
		printEndpoints(cfg)
		return nil
	}

	image := cfg.Image()
	if startImage != "" {
		image = startImage
	}

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

	if cfg.Auth.SecretKeyBase == "" {
		// Config predates persisted secret_key_base — generate once and save it
		// so it survives future container restarts.
		cfg.Auth.SecretKeyBase = config.GenerateSecret(64)
		cwd, _ := os.Getwd()
		if err := config.Save(cfg, cwd); err != nil {
			return fmt.Errorf("failed to persist secret_key_base: %w", err)
		}
	}

	if cfg.Auth.AnonKey == "" || cfg.Auth.ServiceKey == "" {
		fmt.Println("⚠ No API keys in konet.config.toml — run `konet keys generate` before connecting a client")
	}

	fmt.Printf("Starting konet-server on port %d...\n", cfg.Server.Port)
	if err := cli.Start(ctx, docker.StartOptions{
		Image: image,
		Port:  cfg.Server.Port,
		Env:   cfg.ServerEnv(),
	}); err != nil {
		return fmt.Errorf("container start failed: %w", err)
	}

	if err := waitUntilHealthy(cfg); err != nil {
		return err
	}

	fmt.Println("\n✓ Konet is running!")
	printEndpoints(cfg)
	fmt.Println("\n  Run `konet logs --follow` to stream logs")
	return nil
}

// waitUntilHealthy polls /api/health instead of sleeping a flat 20 seconds,
// which used to waste most of that time on a fast machine and could still
// report success before the server was up on a slow one.
func waitUntilHealthy(cfg *config.Config) error {
	const timeout = 60 * time.Second
	const interval = 250 * time.Millisecond

	client := api.New(cfg.ServerBaseURL(), cfg.Auth.ServiceKey)
	deadline := time.Now().Add(timeout)

	fmt.Print("Waiting for server to be ready")
	for time.Now().Before(deadline) {
		if _, err := client.Health(); err == nil {
			fmt.Println(" ✓")
			return nil
		}
		fmt.Print(".")
		time.Sleep(interval)
	}

	fmt.Println()
	return fmt.Errorf(
		"server did not answer %s/api/health within %s — check `konet logs`",
		cfg.ServerBaseURL(), timeout)
}

func printEndpoints(cfg *config.Config) {
	fmt.Printf("  WebSocket  ws://%s:%d/socket\n", cfg.Server.Host, cfg.Server.Port)
	fmt.Printf("  REST API   %s/api\n", cfg.ServerBaseURL())
	fmt.Printf("  Studio     %s\n", cfg.StudioURL())
}

func init() {
	startCmd.Flags().StringVar(&startImage, "image", "",
		"Server image to run (overrides [server].image; useful for a locally built one)")
}
