// subsonic-auth is a small reverse proxy in front of Navidrome that
// authenticates native Subsonic clients against Keycloak personal access
// tokens. Browsers (which carry the oauth2-proxy session cookie) are routed to
// the oauth2-proxy gate by the front proxy instead and never reach this shim.
//
// Its front mode is the web bridge in front of Octo: it trusts the gate's
// identity header and mints the same signed token, so Feishin needs no PAT.
package main

import (
	"context"
	"log"
	"net/http"
	"net/url"
	"os"
	"time"
)

func main() {
	switch mode := os.Getenv("MODE"); mode {
	case "", "native":
		runNative()
	case "front":
		runFront()
	default:
		log.Fatalf("subsonic-auth: unknown MODE %q (want native or front)", mode)
	}
}

func runNative() {
	cfg, err := loadConfig()
	if err != nil {
		log.Fatalf("subsonic-auth: %v", err)
	}

	upstream, err := url.Parse(cfg.upstream)
	if err != nil {
		log.Fatalf("invalid UPSTREAM %q: %v", cfg.upstream, err)
	}
	routes := make([]upstreamRoute, 0, len(cfg.routes))
	for _, rt := range cfg.routes {
		u, err := url.Parse(rt.upstream)
		if err != nil {
			log.Fatalf("invalid ROUTES upstream %q: %v", rt.upstream, err)
		}
		routes = append(routes, upstreamRoute{path: rt.path, upstream: u})
	}
	v, err := newValidator(cfg.keycloakURL, cfg.realm, cfg.requiredRole, &http.Client{Timeout: cfg.validateTimeout})
	if err != nil {
		log.Fatalf("invalid KEYCLOAK_URL %q: %v", cfg.keycloakURL, err)
	}
	signer, err := newTokenSigner(cfg.tokenKid, cfg.tokenKeys, cfg.tokenTTL, cfg.tokenAud)
	if err != nil {
		log.Fatalf("invalid subsonic token signing key: %v", err)
	}
	store := newPATStore(cfg.patStoreDir, cfg.patStoreKey, cfg.patTransientGrace)
	if !store.Enabled() {
		log.Printf("subsonic-auth: PAT store disabled (SUBSONIC_PAT_KEY unset); md5-only clients will be refused")
	} else {
		go store.runRevalidation(context.Background(), v, cfg.patRevalidateInterval)
	}

	srv := newServer(serverDeps{
		identityHeader: cfg.identityHeader,
		adminUser:      cfg.adminUser,
		cache:          newCredCache(cfg.cacheTTL, cfg.cacheSize),
		signer:         signer,
		validator:      v,
		patStore:       store,
		upstream:       upstream,
		routes:         routes,
	})
	httpServer := &http.Server{
		Addr:              cfg.listenAddr,
		Handler:           srv.Handler(),
		ReadHeaderTimeout: 10 * time.Second,
	}

	log.Printf("subsonic-auth: %s -> %s (keycloak %s realm %s, token kid %s ttl %s)",
		cfg.listenAddr, cfg.upstream, cfg.keycloakURL, cfg.realm, cfg.tokenKid, cfg.tokenTTL)
	log.Fatal(httpServer.ListenAndServe())
}

func runFront() {
	cfg, err := loadFrontConfig()
	if err != nil {
		log.Fatalf("subsonic-bridge: %v", err)
	}
	signer, err := newTokenSigner(cfg.tokenKid, cfg.tokenKeys, cfg.tokenTTL, cfg.tokenAud)
	if err != nil {
		log.Fatalf("subsonic-bridge: invalid token signing key: %v", err)
	}
	srv := newBridgeServer(bridgeDeps{
		identityHeader: cfg.identityHeader,
		pathPrefix:     cfg.pathPrefix,
		signer:         signer,
		upstream:       cfg.upstream,
	})
	httpServer := &http.Server{
		Addr:              cfg.listenAddr,
		Handler:           srv.Handler(),
		ReadHeaderTimeout: 10 * time.Second,
	}

	log.Printf("subsonic-bridge: %s -> %s%s (identity %s, token kid %s ttl %s)",
		cfg.listenAddr, cfg.upstream, cfg.pathPrefix, cfg.identityHeader, cfg.tokenKid, cfg.tokenTTL)
	log.Fatal(httpServer.ListenAndServe())
}
