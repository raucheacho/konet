package cmd

import (
	"fmt"
	"os"

	"github.com/spf13/cobra"
)

var rootCmd = &cobra.Command{
	Use:   "konet",
	Short: "Konet — realtime infrastructure engine",
	Long: `Konet is a self-hosted realtime infrastructure engine.
It manages a Phoenix-based WebSocket server with channels,
presence tracking, and JWT authentication.

Documentation: https://konet.io`,
	Version: "0.1.0",
}

func Execute() {
	if err := rootCmd.Execute(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func init() {
	rootCmd.AddCommand(
		initCmd,
		startCmd,
		stopCmd,
		statusCmd,
		logsCmd,
		channelsCmd,
		publishCmd,
		keysCmd,
		studioCmd,
		upgradeCmd,
	)
}
