package main

import (
	"os"
	"strconv"
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
	sessionTTL      time.Duration
	validateTimeout time.Duration
}

func loadConfig() config {
	return config{
		listenAddr:      getenv("LISTEN_ADDR", "0.0.0.0:8080"),
		upstream:        getenv("UPSTREAM", "http://172.30.0.10:4533"),
		keycloakURL:     getenv("KEYCLOAK_URL", "http://172.30.0.1:8080"),
		realm:           getenv("KEYCLOAK_REALM", "dummy-DO-NOT-USE-realm"),
		identityHeader:  getenv("IDENTITY_HEADER", "X-Forwarded-Preferred-Username"),
		cacheTTL:        getenvDuration("CACHE_TTL", 60*time.Second),
		cacheSize:       getenvInt("CACHE_SIZE", 4096),
		sessionTTL:      getenvDuration("SESSION_TTL", 12*time.Hour),
		validateTimeout: getenvDuration("VALIDATE_TIMEOUT", 5*time.Second),
	}
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
