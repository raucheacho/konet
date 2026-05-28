package api

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"
)

type Client struct {
	baseURL    string
	serviceKey string
	http       *http.Client
}

func New(baseURL, serviceKey string) *Client {
	return &Client{
		baseURL:    baseURL,
		serviceKey: serviceKey,
		http:       &http.Client{Timeout: 10 * time.Second},
	}
}

func (c *Client) Health() (map[string]any, error) {
	return c.get("/api/health", false)
}

func (c *Client) Channels() (map[string]any, error) {
	return c.get("/api/channels", true)
}

func (c *Client) Presence(channel string) (map[string]any, error) {
	return c.get(fmt.Sprintf("/api/presence/%s", channel), true)
}

func (c *Client) Metrics() (map[string]any, error) {
	return c.get("/api/metrics", true)
}

func (c *Client) Broadcast(channel, event string, payload map[string]any) (map[string]any, error) {
	body := map[string]any{
		"channel": channel,
		"event":   event,
		"payload": payload,
	}
	return c.post("/api/broadcast", body)
}

func (c *Client) get(path string, auth bool) (map[string]any, error) {
	req, err := http.NewRequest("GET", c.baseURL+path, nil)
	if err != nil {
		return nil, err
	}
	if auth {
		req.Header.Set("Authorization", "Bearer "+c.serviceKey)
	}

	resp, err := c.http.Do(req)
	if err != nil {
		return nil, fmt.Errorf("request failed: %w", err)
	}
	defer resp.Body.Close()

	return decodeJSON(resp)
}

func (c *Client) post(path string, body any) (map[string]any, error) {
	data, err := json.Marshal(body)
	if err != nil {
		return nil, err
	}

	req, err := http.NewRequest("POST", c.baseURL+path, bytes.NewReader(data))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+c.serviceKey)

	resp, err := c.http.Do(req)
	if err != nil {
		return nil, fmt.Errorf("request failed: %w", err)
	}
	defer resp.Body.Close()

	return decodeJSON(resp)
}

func decodeJSON(resp *http.Response) (map[string]any, error) {
	raw, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}

	var result map[string]any
	if err := json.Unmarshal(raw, &result); err != nil {
		return nil, fmt.Errorf("invalid JSON response: %s", string(raw))
	}

	if resp.StatusCode >= 400 {
		return nil, fmt.Errorf("server error %d: %s", resp.StatusCode, raw)
	}

	return result, nil
}
