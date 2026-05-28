package cmd

import (
	"context"
	"fmt"

	"github.com/konet-io/konet-cli/internal/docker"
	"github.com/spf13/cobra"
)

var stopCmd = &cobra.Command{
	Use:   "stop",
	Short: "Stop the Konet server",
	RunE: func(cmd *cobra.Command, args []string) error {
		ctx := context.Background()

		cli, err := docker.New()
		if err != nil {
			return fmt.Errorf("docker not available: %w", err)
		}
		defer cli.Close()

		running, _, err := cli.IsRunning(ctx)
		if err != nil {
			return err
		}
		if !running {
			fmt.Println("Konet is not running.")
			return nil
		}

		fmt.Print("Stopping konet-server...")
		if err := cli.Stop(ctx); err != nil {
			return fmt.Errorf("stop failed: %w", err)
		}
		fmt.Println(" ✓")
		return nil
	},
}
