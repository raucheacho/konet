package cmd

import (
	"fmt"

	"github.com/raucheacho/konet/konet-cli/internal/api"
	"github.com/raucheacho/konet/konet-cli/internal/config"
	"github.com/spf13/cobra"
)

var presenceCmd = &cobra.Command{
	Use:   "presence <channel>",
	Short: "Show who is present in a channel",
	Long: `Show who is present in a channel.

The channel is named without the "room:" prefix, the same way ` + "`konet publish`" + ` takes it.

Example:
  konet presence lobby`,
	Args: cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		cfg, err := config.LoadFromCWD()
		if err != nil {
			return fmt.Errorf("no konet.config.toml found — run `konet init` first")
		}

		client := api.New(cfg.ServerBaseURL(), cfg.Auth.ServiceKey)
		result, err := client.Presence(args[0])
		if err != nil {
			return fmt.Errorf("failed to fetch presence: %w", err)
		}

		entries, _ := result["presence"].([]any)
		if len(entries) == 0 {
			fmt.Printf("No one is present in room:%s.\n", args[0])
			return nil
		}

		fmt.Printf("%-30s %s\n", "USER", "JOINED")
		fmt.Printf("%-30s %s\n", "----", "------")
		for _, entry := range entries {
			m, ok := entry.(map[string]any)
			if !ok {
				continue
			}
			fmt.Printf("%-30v %v\n", m["user_id"], onlineAt(m))
		}
		fmt.Printf("\n%v present\n", result["count"])
		return nil
	},
}

// onlineAt digs the timestamp out of the first presence meta, which is where
// the server puts it (Presence.track with %{online_at, room, role}).
func onlineAt(entry map[string]any) any {
	metas, ok := entry["metas"].([]any)
	if !ok || len(metas) == 0 {
		return "-"
	}
	meta, ok := metas[0].(map[string]any)
	if !ok {
		return "-"
	}
	if v, ok := meta["online_at"]; ok {
		return v
	}
	return "-"
}
