package cmd

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"runtime"

	"github.com/raucheacho/konet/konet-cli/internal/docker"
	"github.com/spf13/cobra"
)

const upgradeScriptURL = "https://raw.githubusercontent.com/raucheacho/konet/main/install.sh"
const latestReleaseURL = "https://api.github.com/repos/raucheacho/konet/releases/latest"

var upgradeCmd = &cobra.Command{
	Use:   "upgrade",
	Short: "Upgrade konet CLI to the latest version",
	RunE: func(cmd *cobra.Command, args []string) error {
		fmt.Println("Checking for updates...")

		latest, err := fetchLatestVersion()
		if err != nil {
			return fmt.Errorf("cannot check for updates: %w", err)
		}

		current := "v" + rootCmd.Version
		if latest == current {
			fmt.Printf("✓ Already on latest version (%s)\n", current)
			return nil
		}

		fmt.Printf("New version available: %s → %s\n", current, latest)

		if runtime.GOOS == "windows" {
			fmt.Printf("Download the latest release from:\n  https://github.com/raucheacho/konet/konet-cli/releases/latest\n")
			return nil
		}

		fmt.Println("Installing update...")
		script, err := downloadScript(upgradeScriptURL)
		if err != nil {
			fmt.Printf("Auto-update failed. Please visit:\n  https://github.com/raucheacho/konet/konet-cli/releases/latest\n")
			return nil
		}

		f, err := os.CreateTemp("", "konet-install-*.sh")
		if err != nil {
			return err
		}
		defer os.Remove(f.Name())

		f.WriteString(script)
		f.Close()

		c := exec.Command("sh", f.Name())
		c.Stdout = os.Stdout
		c.Stderr = os.Stderr
		if err := c.Run(); err != nil {
			return fmt.Errorf("install script failed: %w", err)
		}

		fmt.Printf("✓ Updated to %s\n", latest)

		// Also pull the latest server image
		fmt.Printf("\nPulling latest server image %s...\n", docker.ImageName)
		if err := pullServerImage(); err != nil {
			fmt.Printf("⚠ Could not update server image: %v\n", err)
			fmt.Println("  Run `konet start` to pull it on next start.")
		} else {
			fmt.Printf("✓ Server image updated\n")
		}
		return nil
	},
}

func pullServerImage() error {
	cli, err := docker.New()
	if err != nil {
		return err
	}
	defer cli.Close()
	return cli.Pull(context.Background(), docker.ImageName)
}

func fetchLatestVersion() (string, error) {
	resp, err := http.Get(latestReleaseURL)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	var release struct {
		TagName string `json:"tag_name"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&release); err != nil {
		return "", err
	}
	return release.TagName, nil
}

func downloadScript(url string) (string, error) {
	resp, err := http.Get(url)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	data, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", err
	}
	return string(data), nil
}
