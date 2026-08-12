package cmd

import (
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

// Overwriting a brew- or scoop-managed binary leaves that manager's metadata
// describing a file it no longer controls: `brew list --versions` reports one
// version, `konet --version` another, and the next `brew upgrade` silently
// reverts whatever self-update wrote. So `konet upgrade` only replaces the
// binary when nothing else is tracking it.

func TestDetectInstallMethod(t *testing.T) {
	cases := []struct {
		name string
		path string
		want installMethod
	}{
		{"homebrew cask on apple silicon", "/opt/homebrew/Caskroom/konet/0.3.0/konet", installHomebrew},
		{"homebrew cask on intel macOS", "/usr/local/Caskroom/konet/0.3.0/konet", installHomebrew},
		{"homebrew formula", "/opt/homebrew/Cellar/konet/0.3.0/bin/konet", installHomebrew},
		{"linuxbrew", "/home/linuxbrew/.linuxbrew/Cellar/konet/0.3.0/bin/konet", installHomebrew},
		{"scoop", "C:/Users/x/scoop/apps/konet/0.3.0/konet.exe", installScoop},
		{"install.sh default", "/home/x/.local/bin/konet", installScript},
		{"manual extract", "/usr/local/bin/konet", installScript},
		{"go build output", "/tmp/konet", installScript},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := detectInstallMethod(tc.path); got != tc.want {
				t.Fatalf("detectInstallMethod(%q) = %v, want %v", tc.path, got, tc.want)
			}
		})
	}
}

// Homebrew links a cask's binary into its bin directory, so the *unresolved*
// path looks like an ordinary /opt/homebrew/bin/konet and reveals nothing. The
// classification has to follow the link.
func TestDetectInstallMethodResolvesSymlinks(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("symlinks need privileges on Windows")
	}

	root := t.TempDir()
	caskroom := filepath.Join(root, "Caskroom", "konet", "0.3.0")
	if err := os.MkdirAll(caskroom, 0o755); err != nil {
		t.Fatal(err)
	}
	real := filepath.Join(caskroom, "konet")
	if err := os.WriteFile(real, []byte("binary"), 0o755); err != nil {
		t.Fatal(err)
	}

	bin := filepath.Join(root, "bin")
	if err := os.MkdirAll(bin, 0o755); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(bin, "konet")
	if err := os.Symlink(real, link); err != nil {
		t.Fatal(err)
	}

	if got := detectInstallMethod(link); got != installHomebrew {
		t.Fatalf("a link into a Caskroom classified as %v; brew's install would be overwritten", got)
	}
}

func TestUpgradeCommandPerMethod(t *testing.T) {
	// A cask, not a formula — see homebrew_casks in .goreleaser.yaml.
	if got := installHomebrew.upgradeCommand(); got != "brew upgrade --cask konet" {
		t.Fatalf("homebrew: got %q", got)
	}
	if got := installScoop.upgradeCommand(); got != "scoop update konet" {
		t.Fatalf("scoop: got %q", got)
	}
	// Empty means "no manager owns this — self-update is allowed".
	if got := installScript.upgradeCommand(); got != "" {
		t.Fatalf("script install should self-update, got %q", got)
	}
}

func TestNormalizeVersion(t *testing.T) {
	for _, v := range []string{"v0.3.0", "0.3.0", " v0.3.0 "} {
		if got := normalizeVersion(v); got != "0.3.0" {
			t.Fatalf("normalizeVersion(%q) = %q", v, got)
		}
	}
}
