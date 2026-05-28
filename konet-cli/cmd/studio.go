package cmd

import (
	"fmt"
	"os/exec"
	"runtime"

	"github.com/konet-io/konet-cli/internal/config"
	"github.com/spf13/cobra"
)

var studioCmd = &cobra.Command{
	Use:   "studio",
	Short: "Open the Studio dashboard in the browser",
	RunE: func(cmd *cobra.Command, args []string) error {
		cfg, err := config.LoadFromCWD()
		if err != nil {
			return fmt.Errorf("no konet.config.toml found — run `konet init` first")
		}

		url := cfg.StudioURL()
		fmt.Printf("Opening Studio at %s\n", url)

		return openBrowser(url)
	},
}

func openBrowser(url string) error {
	var c *exec.Cmd
	switch runtime.GOOS {
	case "darwin":
		c = exec.Command("open", url)
	case "linux":
		c = exec.Command("xdg-open", url)
	case "windows":
		c = exec.Command("rundll32", "url.dll,FileProtocolHandler", url)
	default:
		fmt.Printf("Open this URL in your browser: %s\n", url)
		return nil
	}
	return c.Start()
}
