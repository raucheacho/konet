package cmd

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/raucheacho/konet/konet-cli/internal/config"
	"github.com/spf13/cobra"
)

var keysCmd = &cobra.Command{
	Use:   "keys",
	Short: "Manage API keys",
}

var keysGenerateCmd = &cobra.Command{
	Use:   "generate",
	Short: "Generate anon_key and service_key from jwt_secret",
	RunE: func(cmd *cobra.Command, args []string) error {
		cfg, err := config.LoadFromCWD()
		if err != nil {
			return fmt.Errorf("no konet.config.toml found — run `konet init` first")
		}

		// `konet init` now generates a random secret, so reaching either of
		// these means the file was hand-edited back to an unsafe value.
		if cfg.Auth.JWTSecret == "" {
			return fmt.Errorf("jwt_secret is empty in %s — set one, or delete the file and re-run `konet init`",
				config.ConfigFileName)
		}
		if cfg.Auth.JWTSecret == "change-me-in-production-min-32-chars!!" {
			fmt.Fprintln(os.Stderr, "⚠ jwt_secret is still the documented placeholder — anyone can forge tokens against it")
		}

		anonKey, err := signJWT(map[string]any{"role": "anon"}, cfg.Auth.JWTSecret)
		if err != nil {
			return fmt.Errorf("generate anon_key: %w", err)
		}

		serviceKey, err := signJWT(map[string]any{"role": "service"}, cfg.Auth.JWTSecret)
		if err != nil {
			return fmt.Errorf("generate service_key: %w", err)
		}

		cfg.Auth.AnonKey = anonKey
		cfg.Auth.ServiceKey = serviceKey

		cwd, _ := os.Getwd()
		if err := config.Save(cfg, cwd); err != nil {
			return fmt.Errorf("save config: %w", err)
		}

		fmt.Println("✓ Keys generated and saved to konet.config.toml")
		fmt.Printf("\nanon_key:    %s\n", anonKey)
		fmt.Printf("service_key: %s\n", serviceKey)
		fmt.Println("\n⚠ service_key is sensitive — never expose it in client code")
		return nil
	},
}

func signJWT(claims map[string]any, secret string) (string, error) {
	header := base64URLEncode(`{"alg":"HS256","typ":"JWT"}`)

	claims["iat"] = time.Now().Unix()
	claimsJSON, err := json.Marshal(claims)
	if err != nil {
		return "", err
	}
	payload := base64URLEncode(string(claimsJSON))

	sigInput := header + "." + payload
	sig := hmacSHA256(sigInput, secret)

	return sigInput + "." + sig, nil
}

func base64URLEncode(s string) string {
	encoded := base64.URLEncoding.EncodeToString([]byte(s))
	encoded = strings.TrimRight(encoded, "=")
	return encoded
}

func hmacSHA256(data, key string) string {
	mac := hmac.New(sha256.New, []byte(key))
	mac.Write([]byte(data))
	sig := mac.Sum(nil)
	encoded := base64.URLEncoding.EncodeToString(sig)
	return strings.TrimRight(encoded, "=")
}

func init() {
	keysCmd.AddCommand(keysGenerateCmd)
}
