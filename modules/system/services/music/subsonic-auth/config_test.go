package main

import (
	"reflect"
	"strings"
	"testing"
)

func TestParseRoutes(t *testing.T) {
	tests := []struct {
		name    string
		raw     string
		want    []route
		wantErr bool
	}{
		{name: "empty", raw: "", want: nil},
		{name: "blank", raw: "  ", want: nil},
		{
			name: "single",
			raw:  "/rest=http://172.30.0.12:4185",
			want: []route{{path: "/rest", upstream: "http://172.30.0.12:4185"}},
		},
		{
			name: "multiple with surrounding whitespace",
			raw:  " /rest=http://a:1 , /rest/ = http://b:2 ",
			want: []route{
				{path: "/rest", upstream: "http://a:1"},
				{path: "/rest/", upstream: "http://b:2"},
			},
		},
		{name: "missing upstream", raw: "/rest=", wantErr: true},
		{name: "no equals", raw: "/rest", wantErr: true},
		{name: "path without leading slash", raw: "rest=http://a:1", wantErr: true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := parseRoutes(tt.raw)
			if tt.wantErr {
				if err == nil {
					t.Fatalf("parseRoutes(%q) = %v, want an error", tt.raw, got)
				}
				return
			}
			if err != nil {
				t.Fatalf("parseRoutes(%q) error = %v", tt.raw, err)
			}
			if !reflect.DeepEqual(got, tt.want) {
				t.Fatalf("parseRoutes(%q) = %v, want %v", tt.raw, got, tt.want)
			}
		})
	}
}

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
