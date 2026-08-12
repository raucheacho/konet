package cmd

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"strings"
	"testing"
)

// The CLI signs HS256 by hand rather than pulling in a JWT library, so it has
// to stay byte-compatible with Joken on the server. Nothing covered that: a
// change to the header, the claim encoding or the base64 padding would have
// broken every generated key with no signal from CI.
//
// These assertions state the JWT wire format rather than agree with whatever
// signJWT currently emits.

func decodeSegment(t *testing.T, segment string) []byte {
	t.Helper()
	// base64url, padding stripped — RFC 7515 §2.
	if strings.ContainsAny(segment, "+/=") {
		t.Fatalf("segment %q is not base64url without padding", segment)
	}
	decoded, err := base64.RawURLEncoding.DecodeString(segment)
	if err != nil {
		t.Fatalf("segment %q does not decode: %v", segment, err)
	}
	return decoded
}

func TestSignJWTStructure(t *testing.T) {
	token, err := signJWT(map[string]any{"role": "anon"}, "secret")
	if err != nil {
		t.Fatal(err)
	}

	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		t.Fatalf("expected three dot-separated segments, got %d", len(parts))
	}

	var header map[string]any
	if err := json.Unmarshal(decodeSegment(t, parts[0]), &header); err != nil {
		t.Fatal(err)
	}
	if header["alg"] != "HS256" {
		t.Fatalf("alg = %v, want HS256 — the server verifies with HS256 only", header["alg"])
	}
	if header["typ"] != "JWT" {
		t.Fatalf("typ = %v, want JWT", header["typ"])
	}
}

func TestSignJWTClaims(t *testing.T) {
	token, err := signJWT(map[string]any{"role": "service"}, "secret")
	if err != nil {
		t.Fatal(err)
	}

	var claims map[string]any
	if err := json.Unmarshal(decodeSegment(t, strings.Split(token, ".")[1]), &claims); err != nil {
		t.Fatal(err)
	}

	if claims["role"] != "service" {
		t.Fatalf("role = %v, want service", claims["role"])
	}

	// iat is added, exp deliberately is not: the server only enforces an expiry
	// when the token declares one, and every anon/service key ever minted has
	// none. Adding one here would invalidate them on the next rotation.
	if _, ok := claims["iat"]; !ok {
		t.Fatal("iat should be added automatically")
	}
	if _, ok := claims["exp"]; ok {
		t.Fatal("exp must not be added: keys are long-lived by design")
	}
}

func TestSignJWTSignatureIsVerifiable(t *testing.T) {
	const secret = "a-secret-of-at-least-32-characters!!"

	token, err := signJWT(map[string]any{"role": "anon"}, secret)
	if err != nil {
		t.Fatal(err)
	}

	parts := strings.Split(token, ".")
	signingInput := parts[0] + "." + parts[1]

	// Recomputed independently of hmacSHA256, so a change to that helper cannot
	// make this test agree with it by construction.
	mac := hmac.New(sha256.New, []byte(secret))
	mac.Write([]byte(signingInput))
	want := base64.RawURLEncoding.EncodeToString(mac.Sum(nil))

	if parts[2] != want {
		t.Fatalf("signature = %q, want %q", parts[2], want)
	}
}

func TestSignJWTIsSecretSensitive(t *testing.T) {
	a, err := signJWT(map[string]any{"role": "anon"}, "secret-a")
	if err != nil {
		t.Fatal(err)
	}
	b, err := signJWT(map[string]any{"role": "anon"}, "secret-b")
	if err != nil {
		t.Fatal(err)
	}

	sigA := strings.Split(a, ".")[2]
	sigB := strings.Split(b, ".")[2]
	if sigA == sigB {
		t.Fatal("two secrets produced the same signature")
	}
}

func TestBase64URLEncodeStripsPadding(t *testing.T) {
	// "a" base64-encodes to "YQ==" — the padding has to go, or the server's
	// decoder rejects the segment.
	if got := base64URLEncode("a"); got != "YQ" {
		t.Fatalf("base64URLEncode(%q) = %q, want %q", "a", got, "YQ")
	}
	// A byte sequence that produces '-' and '_' in base64url but '+' and '/' in
	// standard base64, which the server would not accept.
	if got := base64URLEncode(string([]byte{0xfb, 0xff})); strings.ContainsAny(got, "+/=") {
		t.Fatalf("base64URLEncode produced non-url-safe output: %q", got)
	}
}
