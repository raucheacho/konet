package cmd

import (
	"fmt"

	"github.com/raucheacho/konet/konet-cli/internal/api"
	"github.com/raucheacho/konet/konet-cli/internal/config"
	"github.com/spf13/cobra"
)

var channelsCmd = &cobra.Command{
	Use:   "channels",
	Short: "Manage channels",
}

var channelsListCmd = &cobra.Command{
	Use:   "list",
	Short: "List active channels",
	RunE: func(cmd *cobra.Command, args []string) error {
		cfg, err := config.LoadFromCWD()
		if err != nil {
			return fmt.Errorf("no konet.config.toml found — run `konet init` first")
		}

		client := api.New(cfg.ServerBaseURL(), cfg.Auth.ServiceKey)
		result, err := client.Channels()
		if err != nil {
			return fmt.Errorf("failed to fetch channels: %w", err)
		}

		channels, ok := result["channels"].([]any)
		if !ok || len(channels) == 0 {
			fmt.Println("No active channels.")
			return nil
		}

		fmt.Printf("%-30s %s\n", "CHANNEL", "SUBSCRIBERS")
		fmt.Printf("%-30s %s\n", "-------", "-----------")
		for _, ch := range channels {
			if m, ok := ch.(map[string]any); ok {
				fmt.Printf("%-30s %v\n", fmt.Sprintf("room:%v", m["id"]), m["subscribers"])
			}
		}
		return nil
	},
}

func init() {
	channelsCmd.AddCommand(channelsListCmd)
}
