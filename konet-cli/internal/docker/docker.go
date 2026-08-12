package docker

import (
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"time"

	"github.com/docker/docker/api/types"
	"github.com/docker/docker/api/types/container"
	"github.com/docker/docker/api/types/filters"
	"github.com/docker/docker/api/types/image"
	dockerclient "github.com/docker/docker/client"
	"github.com/docker/docker/pkg/stdcopy"
	"github.com/docker/go-connections/nat"
)

const (
	// ImageName is the published server image. Prefer config.Config.Image(),
	// which lets a project override it; this is the fallback and the target of
	// `konet upgrade`.
	ImageName     = "ghcr.io/raucheacho/konet:latest"
	ContainerName = "konet-server"
)

type Client struct {
	docker *dockerclient.Client
}

// New connects to the Docker daemon.
//
// FromEnv alone is not enough: it reads DOCKER_HOST and otherwise assumes
// /var/run/docker.sock, but it does **not** read Docker CLI contexts. On a
// stock Docker Desktop install for macOS that socket does not exist — the
// daemon listens on ~/.docker/run/docker.sock — so every command failed with
// "Is the docker daemon running?" while the daemon was in fact running. Colima
// and rootless Linux move it too.
//
// So: honour DOCKER_HOST when set, otherwise probe the known locations and use
// the first that answers a ping.
func New() (*Client, error) {
	if host := os.Getenv("DOCKER_HOST"); host != "" {
		cli, err := connect(dockerclient.FromEnv)
		if err != nil {
			return nil, fmt.Errorf("docker client (DOCKER_HOST=%s): %w", host, err)
		}
		return &Client{docker: cli}, nil
	}

	var tried []string
	for _, host := range candidateHosts() {
		tried = append(tried, host)
		if cli, err := connect(dockerclient.WithHost(host)); err == nil {
			return &Client{docker: cli}, nil
		}
	}

	return nil, fmt.Errorf(
		"could not reach the Docker daemon. Tried: %s\n"+
			"If Docker is running somewhere else, set DOCKER_HOST "+
			"(e.g. DOCKER_HOST=$(docker context inspect --format '{{.Endpoints.docker.Host}}'))",
		strings.Join(tried, ", "))
}

// connect builds a client and verifies it can actually talk to a daemon, since
// creating one never fails on its own.
func connect(opt dockerclient.Opt) (*dockerclient.Client, error) {
	cli, err := dockerclient.NewClientWithOpts(opt, dockerclient.WithAPIVersionNegotiation())
	if err != nil {
		return nil, err
	}

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()

	if _, err := cli.Ping(ctx); err != nil {
		cli.Close()
		return nil, err
	}
	return cli, nil
}

// candidateHosts lists where a daemon socket is normally found, most specific
// first.
func candidateHosts() []string {
	var hosts []string

	if home, err := os.UserHomeDir(); err == nil {
		// Docker Desktop (macOS, and Windows under WSL).
		hosts = append(hosts, "unix://"+filepath.Join(home, ".docker", "run", "docker.sock"))
		// Colima.
		hosts = append(hosts, "unix://"+filepath.Join(home, ".colima", "default", "docker.sock"))
	}

	// Rootless Docker on Linux.
	if runtimeDir := os.Getenv("XDG_RUNTIME_DIR"); runtimeDir != "" {
		hosts = append(hosts, "unix://"+filepath.Join(runtimeDir, "docker.sock"))
	}

	// The classic location, and what FromEnv would have assumed.
	hosts = append(hosts, "unix:///var/run/docker.sock")

	return hosts
}

type StartOptions struct {
	Image string
	Port  int
	// Env is the full container environment, built by config.Config.ServerEnv.
	Env []string
}

func (c *Client) ImageExists(ctx context.Context, img string) (bool, error) {
	images, err := c.docker.ImageList(ctx, image.ListOptions{})
	if err != nil {
		return false, err
	}
	for _, im := range images {
		if slices.Contains(im.RepoTags, img) {
			return true, nil
		}
	}
	return false, nil
}

func (c *Client) Pull(ctx context.Context, img string) error {
	out, err := c.docker.ImagePull(ctx, img, image.PullOptions{})
	if err != nil {
		return fmt.Errorf("pull %s: %w", img, err)
	}
	defer out.Close()
	io.Copy(os.Stdout, out)
	return nil
}

func (c *Client) Start(ctx context.Context, opts StartOptions) error {
	portStr := fmt.Sprintf("%d", opts.Port)
	hostPort := nat.Port(portStr + "/tcp")

	// A previous run that crashed, or was stopped outside the CLI, leaves a
	// container of this name behind. ContainerCreate would then fail with a
	// name conflict whose message says nothing about `docker rm`, so clear it
	// first — the container holds no state worth keeping, since the server
	// keeps everything in memory anyway.
	if err := c.removeIfExists(ctx); err != nil {
		return err
	}

	resp, err := c.docker.ContainerCreate(ctx,
		&container.Config{
			Image:        opts.Image,
			Env:          opts.Env,
			ExposedPorts: nat.PortSet{hostPort: struct{}{}},
		},
		&container.HostConfig{
			PortBindings: nat.PortMap{
				hostPort: []nat.PortBinding{{HostIP: "0.0.0.0", HostPort: portStr}},
			},
			RestartPolicy: container.RestartPolicy{Name: "unless-stopped"},
		},
		nil, nil, ContainerName,
	)
	if err != nil {
		return fmt.Errorf("create container: %w", err)
	}

	if err := c.docker.ContainerStart(ctx, resp.ID, container.StartOptions{}); err != nil {
		return fmt.Errorf("start container: %w", err)
	}
	return nil
}

// removeIfExists deletes any container named ContainerName, running or not.
func (c *Client) removeIfExists(ctx context.Context) error {
	existing, err := c.find(ctx)
	if err != nil {
		return err
	}
	if existing == nil {
		return nil
	}

	if existing.State == "running" {
		timeout := 15
		if err := c.docker.ContainerStop(ctx, existing.ID, container.StopOptions{Timeout: &timeout}); err != nil {
			return fmt.Errorf("stop the existing %s container: %w", ContainerName, err)
		}
	}

	if err := c.docker.ContainerRemove(ctx, existing.ID, container.RemoveOptions{}); err != nil {
		return fmt.Errorf("remove the existing %s container: %w", ContainerName, err)
	}
	return nil
}

func (c *Client) Stop(ctx context.Context) error {
	timeout := 15
	if err := c.docker.ContainerStop(ctx, ContainerName, container.StopOptions{Timeout: &timeout}); err != nil {
		return fmt.Errorf("stop container: %w", err)
	}
	return c.docker.ContainerRemove(ctx, ContainerName, container.RemoveOptions{})
}

// find returns the container named ContainerName whatever its state, or nil.
func (c *Client) find(ctx context.Context) (*types.Container, error) {
	f := filters.NewArgs(filters.Arg("name", ContainerName))
	containers, err := c.docker.ContainerList(ctx, container.ListOptions{All: true, Filters: f})
	if err != nil {
		return nil, err
	}

	// The name filter is a substring match, so "konet-server-2" would match too.
	for i := range containers {
		for _, name := range containers[i].Names {
			if strings.TrimPrefix(name, "/") == ContainerName {
				return &containers[i], nil
			}
		}
	}
	return nil, nil
}

func (c *Client) IsRunning(ctx context.Context) (bool, string, error) {
	found, err := c.find(ctx)
	if err != nil || found == nil {
		return false, "", err
	}

	id := found.ID
	if len(id) > 12 {
		id = id[:12]
	}
	return found.State == "running", id, nil
}

// Logs streams the container's output to w.
//
// Docker multiplexes stdout and stderr with an 8-byte header per frame when the
// container has no TTY, so copying the stream raw printed those header bytes
// inline with the log lines. stdcopy demultiplexes them.
func (c *Client) Logs(ctx context.Context, follow bool, stdout, stderr io.Writer) error {
	reader, err := c.docker.ContainerLogs(ctx, ContainerName, container.LogsOptions{
		ShowStdout: true,
		ShowStderr: true,
		Follow:     follow,
		Timestamps: true,
		Tail:       "100",
	})
	if err != nil {
		return err
	}
	defer reader.Close()

	_, err = stdcopy.StdCopy(stdout, stderr, reader)
	return err
}

func (c *Client) Close() {
	c.docker.Close()
}
