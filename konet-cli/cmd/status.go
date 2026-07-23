package cmd

import (
	"context"
	"fmt"

	"github.com/raucheacho/konet/konet-cli/internal/api"
	"github.com/raucheacho/konet/konet-cli/internal/config"
	"github.com/raucheacho/konet/konet-cli/internal/docker"
	"github.com/spf13/cobra"
)

var statusCmd = &cobra.Command{
	Use:   "status",
	Short: "Show server status and active connections",
	RunE: func(cmd *cobra.Command, args []string) error {
		ctx := context.Background()

		dockerCli, err := docker.New()
		if err == nil {
			defer dockerCli.Close()
			running, id, _ := dockerCli.IsRunning(ctx)
			if running {
				fmt.Printf("Container: running (%s)\n", id)
			} else {
				fmt.Println("Container: stopped")
			}
		}

		cfg, err := config.LoadFromCWD()
		if err != nil {
			fmt.Println("No konet.config.toml found — run `konet init` first")
			return nil
		}

		client := api.New(cfg.ServerBaseURL(), cfg.Auth.ServiceKey)
		health, err := client.Health()
		if err != nil {
			fmt.Printf("Server at %s: unreachable (%v)\n", cfg.ServerBaseURL(), err)
			return nil
		}

		fmt.Printf("\nServer: %s\n", cfg.ServerBaseURL())
		fmt.Printf("Status: %v\n", health["status"])
		fmt.Printf("Version: %v\n", health["version"])
		fmt.Printf("Connections: %v\n", health["connections"])
		fmt.Printf("Uptime: %vs\n", health["uptime_seconds"])

		metrics, err := client.Metrics()
		if err == nil {
			fmt.Printf("Messages/sec: %v\n", metrics["messages_per_second"])
			fmt.Printf("Total messages: %v\n", metrics["messages_total"])
			fmt.Printf("Active channels: %v\n", metrics["channels"])
		}

		return nil
	},
}
