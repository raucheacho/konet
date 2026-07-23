package cmd

import (
	"fmt"
	"os"
	"path/filepath"

	"github.com/raucheacho/konet/konet-cli/internal/config"
	"github.com/spf13/cobra"
)

var initCmd = &cobra.Command{
	Use:   "init",
	Short: "Generate konet.config.toml in the current directory",
	RunE: func(cmd *cobra.Command, args []string) error {
		cwd, err := os.Getwd()
		if err != nil {
			return err
		}

		path := filepath.Join(cwd, config.ConfigFileName)
		if _, err := os.Stat(path); err == nil {
			fmt.Printf("✓ %s already exists\n", config.ConfigFileName)
			return nil
		}

		cfg := config.Default()
		if err := config.Save(cfg, cwd); err != nil {
			return fmt.Errorf("failed to write config: %w", err)
		}

		fmt.Printf("✓ Created %s\n\n", config.ConfigFileName)
		fmt.Println("Next steps:")
		fmt.Println("  1. Edit konet.config.toml — set jwt_secret to a strong random value")
		fmt.Println("  2. Run: konet keys generate — to create anon_key and service_key")
		fmt.Println("  3. Run: konet start         — to start the server")
		fmt.Println("  4. Run: konet studio        — to open the dashboard")
		return nil
	},
}
