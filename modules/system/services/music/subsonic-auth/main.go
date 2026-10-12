// subsonic-auth is a small reverse proxy in front of Navidrome that
// authenticates native Subsonic clients against Keycloak personal access
// tokens. Browsers (which carry the oauth2-proxy session cookie) are routed to
// the oauth2-proxy gate by the front proxy instead and never reach this shim.
package main

import (
	"log"
	"net/http"
	"net/url"
	"time"
)

func main() {
	cfg := loadConfig()

	upstream, err := url.Parse(cfg.upstream)
	if err != nil {
		log.Fatalf("invalid UPSTREAM %q: %v", cfg.upstream, err)
	}
	v, err := newValidator(cfg.keycloakURL, cfg.realm, &http.Client{Timeout: cfg.validateTimeout})
	if err != nil {
		log.Fatalf("invalid KEYCLOAK_URL %q: %v", cfg.keycloakURL, err)
	}

	srv := newServer(serverDeps{
		identityHeader: cfg.identityHeader,
		cache:          newCredCache(cfg.cacheTTL, cfg.cacheSize),
		sessions:       newSessionCache(cfg.sessionTTL, cfg.cacheSize),
		validator:      v,
		upstream:       upstream,
	})
	httpServer := &http.Server{
		Addr:              cfg.listenAddr,
		Handler:           srv.Handler(),
		ReadHeaderTimeout: 10 * time.Second,
	}

	log.Printf("subsonic-auth: %s -> %s (keycloak %s realm %s)",
		cfg.listenAddr, cfg.upstream, cfg.keycloakURL, cfg.realm)
	log.Fatal(httpServer.ListenAndServe())
}
