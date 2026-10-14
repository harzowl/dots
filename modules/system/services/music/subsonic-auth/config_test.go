package main

import (
	"strings"
	"testing"
)

// The realm is the consumer's, not the shim's: it must be supplied, never
// defaulted to a baked-in realm name.
func TestLoadConfigRequiresRealm(t *testing.T) {
	t.Setenv("SUBSONIC_TOKEN_KEY", "dummy-DO-NOT-USE-token-signing-key-0123456789abcdef")
	t.Setenv("KEYCLOAK_REALM", "")

	_, err := loadConfig()
	if err == nil {
		t.Fatal("loadConfig() succeeded with an empty KEYCLOAK_REALM; want an error naming it")
	}
	if !strings.Contains(err.Error(), "KEYCLOAK_REALM") {
		t.Fatalf("loadConfig() error = %q, want it to name KEYCLOAK_REALM", err)
	}
}

func TestLoadConfigReadsRealm(t *testing.T) {
	t.Setenv("SUBSONIC_TOKEN_KEY", "dummy-DO-NOT-USE-token-signing-key-0123456789abcdef")
	t.Setenv("KEYCLOAK_REALM", "example-realm")

	cfg, err := loadConfig()
	if err != nil {
		t.Fatalf("loadConfig() error = %v, want nil", err)
	}
	if cfg.realm != "example-realm" {
		t.Fatalf("cfg.realm = %q, want %q", cfg.realm, "example-realm")
	}
}
