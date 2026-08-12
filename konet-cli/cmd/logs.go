package cmd

import (
	"context"
	"fmt"
	"os"

	"github.com/raucheacho/konet/konet-cli/internal/docker"
	"github.com/spf13/cobra"
)

var logsFollow bool

var logsCmd = &cobra.Command{
	Use:   "logs",
	Short: "Stream server logs",
	RunE: func(cmd *cobra.Command, args []string) error {
		// Bound to the command's context so Ctrl+C ends a --follow stream
		// cleanly instead of relying on the process dying.
		ctx := cmd.Context()
		if ctx == nil {
			ctx = context.Background()
		}

		cli, err := docker.New()
		if err != nil {
			return fmt.Errorf("docker not available: %w", err)
		}
		defer cli.Close()

		running, _, _ := cli.IsRunning(ctx)
		if !running {
			return fmt.Errorf("konet-server is not running — use `konet start`")
		}

		return cli.Logs(ctx, logsFollow, os.Stdout, os.Stderr)
	},
}

func init() {
	logsCmd.Flags().BoolVarP(&logsFollow, "follow", "f", false, "Follow log output")
}
