package api

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestPresenceEscapesTheChannelAsOnePathSegment(t *testing.T) {
	var got string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got = r.URL.EscapedPath()
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{}`))
	}))
	defer server.Close()

	client := New(server.URL, "service")
	cases := map[string]string{
		"lobby":       "/api/presence/lobby",
		"team-42:map": "/api/presence/team-42:map",
		"a/b":         "/api/presence/a%2Fb",
		"q?x=1":       "/api/presence/q%3Fx=1",
		"frag#1":      "/api/presence/frag%231",
		"équipe 1":    "/api/presence/%C3%A9quipe%201",
	}
	for channel, want := range cases {
		if _, err := client.Presence(channel); err != nil {
			t.Fatalf("%q: %v", channel, err)
		}
		if got != want {
			t.Errorf("%q: requested %q, want %q", channel, got, want)
		}
	}
}
