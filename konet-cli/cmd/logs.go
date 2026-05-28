package cmd

import (
	"context"
	"fmt"
	"io"
	"os"

	"github.com/konet-io/konet-cli/internal/docker"
	"github.com/spf13/cobra"
)

var logsFollow bool

var logsCmd = &cobra.Command{
	Use:   "logs",
	Short: "Stream server logs",
	RunE: func(cmd *cobra.Command, args []string) error {
		ctx := context.Background()
		if logsFollow {
			ctx = context.Background() // runs until Ctrl+C
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

		reader, err := cli.Logs(ctx, logsFollow)
		if err != nil {
			return fmt.Errorf("cannot get logs: %w", err)
		}
		defer reader.Close()

		_, err = io.Copy(os.Stdout, reader)
		return err
	},
}

func init() {
	logsCmd.Flags().BoolVarP(&logsFollow, "follow", "f", false, "Follow log output")
}
