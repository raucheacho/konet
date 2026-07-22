package docker

import (
	"context"
	"fmt"
	"io"
	"os"
	"slices"
	"time"

	"github.com/docker/docker/api/types/container"
	"github.com/docker/docker/api/types/filters"
	"github.com/docker/docker/api/types/image"
	dockerclient "github.com/docker/docker/client"
	"github.com/docker/go-connections/nat"
)

const (
	ImageName     = "ghcr.io/raucheacho/konet:latest"
	ContainerName = "konet-server"
)

type Client struct {
	docker *dockerclient.Client
}

func New() (*Client, error) {
	cli, err := dockerclient.NewClientWithOpts(
		dockerclient.FromEnv,
		dockerclient.WithAPIVersionNegotiation(),
	)
	if err != nil {
		return nil, fmt.Errorf("docker client: %w", err)
	}
	return &Client{docker: cli}, nil
}

type StartOptions struct {
	Image          string
	Port           int
	JWTSecret      string
	AnonKey        string
	ServiceKey     string
	SecretKey      string
	StudioPassword string
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

	resp, err := c.docker.ContainerCreate(ctx,
		&container.Config{
			Image: opts.Image,
			Env: []string{
				"MIX_ENV=prod",
				"PHX_SERVER=true",
				fmt.Sprintf("KONET_PORT=%d", opts.Port),
				fmt.Sprintf("KONET_JWT_SECRET=%s", opts.JWTSecret),
				fmt.Sprintf("KONET_ANON_KEY=%s", opts.AnonKey),
				fmt.Sprintf("KONET_SERVICE_KEY=%s", opts.ServiceKey),
				fmt.Sprintf("KONET_STUDIO_PASSWORD=%s", opts.StudioPassword),
				fmt.Sprintf("SECRET_KEY_BASE=%s", opts.SecretKey),
			},
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

func (c *Client) Stop(ctx context.Context) error {
	timeout := 15
	if err := c.docker.ContainerStop(ctx, ContainerName, container.StopOptions{Timeout: &timeout}); err != nil {
		return fmt.Errorf("stop container: %w", err)
	}
	return c.docker.ContainerRemove(ctx, ContainerName, container.RemoveOptions{})
}

func (c *Client) IsRunning(ctx context.Context) (bool, string, error) {
	f := filters.NewArgs(filters.Arg("name", ContainerName))
	containers, err := c.docker.ContainerList(ctx, container.ListOptions{Filters: f})
	if err != nil {
		return false, "", err
	}
	if len(containers) == 0 {
		return false, "", nil
	}
	return containers[0].State == "running", containers[0].ID[:12], nil
}

func (c *Client) Logs(ctx context.Context, follow bool) (io.ReadCloser, error) {
	return c.docker.ContainerLogs(ctx, ContainerName, container.LogsOptions{
		ShowStdout: true,
		ShowStderr: true,
		Follow:     follow,
		Timestamps: true,
		Tail:       "100",
	})
}

func (c *Client) Close() {
	c.docker.Close()
}

// waitDuration returns a human-readable wait hint used when first starting
func WaitDuration() time.Duration {
	return 20 * time.Second
}
