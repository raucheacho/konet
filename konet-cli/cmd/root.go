package cmd

import (
	"fmt"
	"os"

	"github.com/spf13/cobra"
)

// devVersion is what an unstamped build reports. Releases override it through
// SetVersion, which main passes from the -X ldflag GoReleaser sets.
const devVersion = "dev"

var version = devVersion

var rootCmd = &cobra.Command{
	Use:   "konet",
	Short: "Konet — realtime infrastructure engine",
	Long: `Konet is a self-hosted realtime infrastructure engine.
It manages a Phoenix-based WebSocket server with channels,
presence tracking, and JWT authentication.

Documentation: https://github.com/raucheacho/konet`,
	Version: devVersion,
}

// SetVersion stamps the build's version onto the CLI.
//
// It exists because the ldflag GoReleaser passes (-X main.version) can only
// reach a variable in package main, while the version is reported from here.
// Without this the flag silently did nothing — the linker ignores -X for a
// symbol it cannot find — and every released binary reported the hardcoded
// "0.1.0", which also made `konet upgrade` believe an update was always
// available.
func SetVersion(v string) {
	if v == "" {
		return
	}
	version = v
	rootCmd.Version = v
}

func currentVersion() string { return version }

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
		presenceCmd,
		publishCmd,
		keysCmd,
		studioCmd,
		upgradeCmd,
	)
}
