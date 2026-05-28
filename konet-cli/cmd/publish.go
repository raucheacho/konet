package cmd

import (
	"encoding/json"
	"fmt"

	"github.com/konet-io/konet-cli/internal/api"
	"github.com/konet-io/konet-cli/internal/config"
	"github.com/spf13/cobra"
)

var publishEvent string

var publishCmd = &cobra.Command{
	Use:   "publish <channel> <payload>",
	Short: "Broadcast a message to a channel",
	Long: `Broadcast a message to a channel from the CLI.
payload must be valid JSON.

Examples:
  konet publish lobby '{"text":"hello"}'
  konet publish lobby '{"text":"hi"}' --event chat`,
	Args: cobra.ExactArgs(2),
	RunE: func(cmd *cobra.Command, args []string) error {
		channel := args[0]
		rawPayload := args[1]

		var payload map[string]any
		if err := json.Unmarshal([]byte(rawPayload), &payload); err != nil {
			return fmt.Errorf("payload must be valid JSON: %w", err)
		}

		cfg, err := config.LoadFromCWD()
		if err != nil {
			return fmt.Errorf("no konet.config.toml found — run `konet init` first")
		}

		client := api.New(cfg.ServerBaseURL(), cfg.Auth.ServiceKey)
		_, err = client.Broadcast(channel, publishEvent, payload)
		if err != nil {
			return fmt.Errorf("broadcast failed: %w", err)
		}

		fmt.Printf("✓ Broadcast to room:%s — event: %s\n", channel, publishEvent)
		return nil
	},
}

func init() {
	publishCmd.Flags().StringVarP(&publishEvent, "event", "e", "message", "Event name")
}
