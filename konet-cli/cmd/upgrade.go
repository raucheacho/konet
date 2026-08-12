package cmd

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"github.com/raucheacho/konet/konet-cli/internal/docker"
	"github.com/spf13/cobra"
)

const (
	installScriptURL = "https://raw.githubusercontent.com/raucheacho/konet/main/install.sh"
	latestReleaseURL = "https://api.github.com/repos/raucheacho/konet/releases/latest"
	releasesPageURL  = "https://github.com/raucheacho/konet/releases/latest"
)

// installMethod is how this binary got onto the machine, which decides who is
// allowed to replace it.
type installMethod int

const (
	// installScript covers install.sh and a hand-extracted archive alike: in
	// both cases nothing else tracks the file, so replacing it in place is safe.
	installScript installMethod = iota
	installHomebrew
	installScoop
)

// detectInstallMethod classifies the running binary by where it actually lives.
//
// Symlinks are resolved first: Homebrew puts a cask's binary in the Caskroom
// and links it into its bin directory, so the unresolved path looks like an
// ordinary /opt/homebrew/bin/konet and reveals nothing.
func detectInstallMethod(execPath string) installMethod {
	resolved, err := filepath.EvalSymlinks(execPath)
	if err != nil {
		resolved = execPath
	}
	slashed := filepath.ToSlash(resolved)
	lower := strings.ToLower(slashed)

	switch {
	case strings.Contains(slashed, "/Caskroom/"),
		strings.Contains(slashed, "/Cellar/"),
		strings.Contains(lower, "/linuxbrew/"):
		return installHomebrew
	case strings.Contains(lower, "/scoop/apps/"):
		return installScoop
	default:
		return installScript
	}
}

func (m installMethod) upgradeCommand() string {
	switch m {
	case installHomebrew:
		// A cask, not a formula — see homebrew_casks in .goreleaser.yaml.
		return "brew upgrade --cask konet"
	case installScoop:
		return "scoop update konet"
	default:
		return ""
	}
}

var upgradeCmd = &cobra.Command{
	Use:   "upgrade",
	Short: "Upgrade konet CLI to the latest version",
	Long: `Upgrade konet CLI to the latest version.

When konet was installed by Homebrew or Scoop, this prints the command to run
rather than replacing the binary itself: overwriting a managed install leaves
that manager's metadata describing a file it no longer controls, and the next
` + "`brew upgrade`" + ` silently reverts it.`,
	RunE: func(cmd *cobra.Command, args []string) error {
		// Who owns this binary is knowable without the network, so it is decided
		// first: on a managed install the answer is the same whether or not
		// GitHub answers, and a rate-limited API should not turn "run brew
		// upgrade" into an error.
		method := installScript
		if exe, err := os.Executable(); err == nil {
			method = detectInstallMethod(exe)
		}
		command := method.upgradeCommand()

		fmt.Println("Checking for updates...")

		latest, versionErr := fetchLatestVersion()
		current := currentVersion()

		switch {
		case versionErr != nil:
			fmt.Printf("⚠ Could not reach the release API (%v)\n", versionErr)

		case current == devVersion:
			fmt.Printf("This is a development build; the latest release is %s.\n", latest)

		case normalizeVersion(latest) == normalizeVersion(current):
			fmt.Printf("✓ Already on the latest version (%s)\n", current)
			if command == "" {
				return nil
			}

		default:
			fmt.Printf("New version available: %s → %s\n", current, latest)
		}

		// A package manager installed it, so a package manager replaces it.
		// Overwriting here would leave its metadata describing a binary it no
		// longer controls, and the next upgrade would silently revert us.
		if command != "" {
			fmt.Printf("\nInstalled via %s. To upgrade:\n\n    %s\n", method, command)
			return nil
		}

		if versionErr != nil {
			return fmt.Errorf("cannot self-update without knowing the latest version: %w", versionErr)
		}

		if current != devVersion && normalizeVersion(latest) == normalizeVersion(current) {
			return nil
		}

		if current == devVersion {
			fmt.Printf("\nInstall a released build from %s\n", releasesPageURL)
			return nil
		}

		if runtime.GOOS == "windows" {
			fmt.Printf("\nDownload the latest release from:\n  %s\n", releasesPageURL)
			return nil
		}

		fmt.Println("Installing update...")
		script, err := downloadScript(installScriptURL)
		if err != nil {
			// The script used to be fetched without checking the status code, so
			// a 404 page was handed to `sh` and executed as a shell script.
			fmt.Printf("Auto-update unavailable (%v).\nDownload the latest release from:\n  %s\n",
				err, releasesPageURL)
			return nil
		}

		f, err := os.CreateTemp("", "konet-install-*.sh")
		if err != nil {
			return err
		}
		defer os.Remove(f.Name())

		if _, err := f.WriteString(script); err != nil {
			f.Close()
			return err
		}
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

func (m installMethod) String() string {
	switch m {
	case installHomebrew:
		return "Homebrew"
	case installScoop:
		return "Scoop"
	default:
		return "install.sh"
	}
}

// normalizeVersion makes "v0.3.0" and "0.3.0" comparable.
func normalizeVersion(v string) string {
	return strings.TrimPrefix(strings.TrimSpace(v), "v")
}

func pullServerImage() error {
	cli, err := docker.New()
	if err != nil {
		return err
	}
	defer cli.Close()
	return cli.Pull(context.Background(), docker.ImageName)
}

func httpGet(url string) ([]byte, error) {
	client := &http.Client{Timeout: 15 * time.Second}
	resp, err := client.Get(url)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	// Checking this is the whole point: without it GitHub's 404 HTML page looks
	// like a successful download.
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("%s returned HTTP %d", url, resp.StatusCode)
	}

	return io.ReadAll(io.LimitReader(resp.Body, 1<<20))
}

func fetchLatestVersion() (string, error) {
	body, err := httpGet(latestReleaseURL)
	if err != nil {
		return "", err
	}

	var release struct {
		TagName string `json:"tag_name"`
	}
	if err := json.Unmarshal(body, &release); err != nil {
		return "", err
	}
	if release.TagName == "" {
		return "", fmt.Errorf("no tag_name in the latest release")
	}
	return release.TagName, nil
}

func downloadScript(url string) (string, error) {
	body, err := httpGet(url)
	if err != nil {
		return "", err
	}

	script := string(body)
	// A shell script served from raw.githubusercontent starts with a shebang or
	// a comment; an HTML error page does not. Cheap guard against executing
	// whatever a proxy or captive portal decided to return.
	trimmed := strings.TrimSpace(script)
	if !strings.HasPrefix(trimmed, "#!") && !strings.HasPrefix(trimmed, "#") {
		return "", fmt.Errorf("%s did not return a shell script", url)
	}
	return script, nil
}
