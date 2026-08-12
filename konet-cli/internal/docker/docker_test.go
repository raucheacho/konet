package docker

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// dockerclient.FromEnv reads DOCKER_HOST and otherwise assumes
// /var/run/docker.sock. It does not read Docker CLI contexts, so on a stock
// Docker Desktop install for macOS — where the daemon listens on
// ~/.docker/run/docker.sock — every command failed with "Is the docker daemon
// running?" while the daemon was running. These pin the probe order.

func TestCandidateHostsIncludesDockerDesktop(t *testing.T) {
	home, err := os.UserHomeDir()
	if err != nil {
		t.Skip("no home directory")
	}

	want := "unix://" + filepath.Join(home, ".docker", "run", "docker.sock")
	hosts := candidateHosts()

	for _, h := range hosts {
		if h == want {
			return
		}
	}
	t.Fatalf("Docker Desktop's socket %q is not probed; got %v", want, hosts)
}

func TestCandidateHostsIncludesTheClassicSocket(t *testing.T) {
	for _, h := range candidateHosts() {
		if h == "unix:///var/run/docker.sock" {
			return
		}
	}
	t.Fatal("the standard Linux socket is not probed")
}

func TestCandidateHostsPrefersSpecificLocations(t *testing.T) {
	hosts := candidateHosts()
	classic := -1
	for i, h := range hosts {
		if h == "unix:///var/run/docker.sock" {
			classic = i
		}
	}

	if classic != len(hosts)-1 {
		t.Fatalf("the classic socket should be the last resort, got position %d of %d", classic, len(hosts))
	}
}

func TestCandidateHostsHonoursXDGRuntimeDir(t *testing.T) {
	t.Setenv("XDG_RUNTIME_DIR", "/run/user/1000")

	for _, h := range candidateHosts() {
		if strings.Contains(h, "/run/user/1000/docker.sock") {
			return
		}
	}
	t.Fatal("rootless Docker's socket is not probed when XDG_RUNTIME_DIR is set")
}

func TestCandidateHostsAreAllUnixURLs(t *testing.T) {
	for _, h := range candidateHosts() {
		if !strings.HasPrefix(h, "unix://") {
			t.Fatalf("candidate %q is not a unix socket URL", h)
		}
	}
}
