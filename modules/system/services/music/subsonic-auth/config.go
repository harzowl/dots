package main

import (
	"encoding/base64"
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"
)

// config is the shim's runtime configuration, all from the environment so the
// Nix module can set it declaratively.
type config struct {
	listenAddr      string
	upstream        string
	keycloakURL     string
	realm           string
	identityHeader  string
	cacheTTL        time.Duration
	cacheSize       int
	validateTimeout time.Duration

	// Signed-token settings. The signing key itself is never a `settings` value
	// (that would put it in the Nix store); it arrives via `environmentFiles`
	// (the secretspec env file), like every other secret.
	tokenKid  string
	tokenKeys map[string][]byte
	tokenTTL  time.Duration
	tokenAud  string
}

func loadConfig() (config, error) {
	cfg := config{
		listenAddr:      getenv("LISTEN_ADDR", "0.0.0.0:8080"),
		upstream:        getenv("UPSTREAM", "http://172.30.0.10:4533"),
		keycloakURL:     getenv("KEYCLOAK_URL", "http://172.30.0.1:8080"),
		realm:           os.Getenv("KEYCLOAK_REALM"),
		identityHeader:  getenv("IDENTITY_HEADER", "X-Forwarded-Preferred-Username"),
		cacheTTL:        getenvDuration("CACHE_TTL", 60*time.Second),
		cacheSize:       getenvInt("CACHE_SIZE", 4096),
		validateTimeout: getenvDuration("VALIDATE_TIMEOUT", 5*time.Second),
		tokenKid:        getenv("SUBSONIC_TOKEN_KID", "1"),
		tokenAud:        getenv("SUBSONIC_TOKEN_AUD", tokenAudience),
	}

	// The realm is the consumer's, not the shim's: never default it.
	if cfg.realm == "" {
		return config{}, fmt.Errorf("KEYCLOAK_REALM is required (the Keycloak realm holding the users and their PATs)")
	}

	rawKey := os.Getenv("SUBSONIC_TOKEN_KEY")
	if rawKey == "" {
		return config{}, fmt.Errorf("SUBSONIC_TOKEN_KEY is required (>= %d random bytes); set it in the secretspec env file", minTokenKeyLen)
	}
	key, err := parseTokenKey(rawKey)
	if err != nil {
		return config{}, fmt.Errorf("SUBSONIC_TOKEN_KEY: %w", err)
	}
	cfg.tokenKeys = map[string][]byte{cfg.tokenKid: key}

	// Optional previous key: verify-only, so tokens minted before a rotation keep
	// working until they expire. Drop it (and its env vars) once they have.
	if prev := os.Getenv("SUBSONIC_TOKEN_KEY_PREVIOUS"); prev != "" {
		prevKid := getenv("SUBSONIC_TOKEN_KID_PREVIOUS", cfg.tokenKid+"-previous")
		prevKey, err := parseTokenKey(prev)
		if err != nil {
			return config{}, fmt.Errorf("SUBSONIC_TOKEN_KEY_PREVIOUS: %w", err)
		}
		cfg.tokenKeys[prevKid] = prevKey
	}

	ttl, err := parseTokenTTL(getenv("SUBSONIC_TOKEN_TTL", "168h"))
	if err != nil {
		return config{}, fmt.Errorf("SUBSONIC_TOKEN_TTL: %w", err)
	}
	cfg.tokenTTL = ttl

	return cfg, nil
}

// parseTokenKey decodes the signing key. It accepts base64 (std or url, padded
// or raw) or, failing that, the raw bytes of the string, and requires at least
// minTokenKeyLen bytes of key material.
func parseTokenKey(v string) ([]byte, error) {
	s := strings.TrimSpace(v)
	encodings := []*base64.Encoding{
		base64.StdEncoding,
		base64.RawStdEncoding,
		base64.URLEncoding,
		base64.RawURLEncoding,
	}
	for _, enc := range encodings {
		if b, err := enc.DecodeString(s); err == nil && len(b) >= minTokenKeyLen {
			return b, nil
		}
	}
	if len(s) >= minTokenKeyLen {
		return []byte(s), nil
	}
	return nil, fmt.Errorf("key is %d bytes, need at least %d (base64 of that many random bytes)", len(s), minTokenKeyLen)
}

// parseTokenTTL parses a Go duration, also accepting a `d` (days) suffix the
// docs use, e.g. `7d` or `30d`.
func parseTokenTTL(v string) (time.Duration, error) {
	if d, err := time.ParseDuration(v); err == nil {
		if d <= 0 {
			return 0, fmt.Errorf("must be positive, got %q", v)
		}
		return d, nil
	}
	if days, ok := strings.CutSuffix(v, "d"); ok {
		if n, err := strconv.Atoi(days); err == nil && n > 0 {
			return time.Duration(n) * 24 * time.Hour, nil
		}
	}
	return 0, fmt.Errorf("invalid duration %q", v)
}

func getenv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func getenvInt(key string, fallback int) int {
	if v := os.Getenv(key); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
	}
	return fallback
}

func getenvDuration(key string, fallback time.Duration) time.Duration {
	if v := os.Getenv(key); v != "" {
		if d, err := time.ParseDuration(v); err == nil {
			return d
		}
	}
	return fallback
}
