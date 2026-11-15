package main

import (
	"fmt"
	"log"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"strings"
	"time"
)

// Front mode is the web bridge: oauth2-proxy has already authenticated the
// browser and tells this process who it is with one identity header. The
// bridge mints the same short-lived signed token the native shim mints (it
// shares SUBSONIC_TOKEN_KEY / SUBSONIC_TOKEN_KID), then proxies the request to
// Octo's Subsonic API as `u`/`t`/`s`. The browser never sees a PAT.
//
// Only `/feishin/rest…` is served: the edge routes that prefix through the
// general gate, which strips inbound identity headers and sets its own.
//
// `PUBLIC_COVER_PATH` opens exactly one more path, unauthenticated, for image
// fetchers that cannot hold a session (Discord rich presence). It is forwarded
// to Octo's cover-art endpoint with a token minted for `ADMIN_USER`, never with
// anything the client sent.
type frontConfig struct {
	listenAddr      string
	upstream        *url.URL
	identityHeader  string
	pathPrefix      string
	adminUser       string
	publicCoverPath string
	tokenKid        string
	tokenKeys       map[string][]byte
	tokenTTL        time.Duration
	tokenAud        string
}

// defaultFrontTokenTTL is deliberately short: a browser session is renewed
// from the gate, not from a week-long credential.
const defaultFrontTokenTTL = time.Hour

// coverArtPath is the one Subsonic endpoint a public request can reach: it is
// what the bridge asks Octo for, whatever `PUBLIC_COVER_PATH` the gate exposes.
const coverArtPath = "/rest/getCoverArt.view"

func loadFrontConfig() (frontConfig, error) {
	cfg := frontConfig{
		listenAddr:      getenv("LISTEN_ADDR", "0.0.0.0:8080"),
		identityHeader:  getenv("IDENTITY_HEADER", "X-Forwarded-Preferred-Username"),
		pathPrefix:      strings.TrimSuffix(getenv("PATH_PREFIX", "/feishin"), "/"),
		adminUser:       strings.TrimSpace(os.Getenv("ADMIN_USER")),
		publicCoverPath: strings.TrimSpace(os.Getenv("PUBLIC_COVER_PATH")),
		tokenKid:        getenv("SUBSONIC_TOKEN_KID", "1"),
		tokenAud:        getenv("SUBSONIC_TOKEN_AUD", tokenAudience),
	}

	if cfg.pathPrefix == "" || !strings.HasPrefix(cfg.pathPrefix, "/") {
		return frontConfig{}, fmt.Errorf("PATH_PREFIX must start with /, got %q", cfg.pathPrefix)
	}

	if cfg.publicCoverPath != "" {
		if err := validatePublicCoverPath(cfg.publicCoverPath); err != nil {
			return frontConfig{}, fmt.Errorf("PUBLIC_COVER_PATH: %w", err)
		}
		if cfg.adminUser == "" {
			return frontConfig{}, fmt.Errorf("ADMIN_USER is required when PUBLIC_COVER_PATH is set (the identity the public cover token is minted for)")
		}
	}

	rawUpstream := getenv("UPSTREAM", "http://octo:8080")
	upstream, err := url.Parse(rawUpstream)
	if err != nil || upstream.Scheme == "" || upstream.Host == "" {
		return frontConfig{}, fmt.Errorf("UPSTREAM must be an absolute URL, got %q", rawUpstream)
	}
	// The Subsonic path is added per request (`/rest/…`); an upstream path would
	// be prepended by the reverse proxy and double it.
	if upstream.Path != "" && upstream.Path != "/" {
		return frontConfig{}, fmt.Errorf("UPSTREAM must be the Octo base URL without a path, got %q", rawUpstream)
	}
	upstream.Path = ""
	cfg.upstream = upstream

	rawKey := os.Getenv("SUBSONIC_TOKEN_KEY")
	if rawKey == "" {
		return frontConfig{}, fmt.Errorf("SUBSONIC_TOKEN_KEY is required (the key the native shim signs with); set it in the secretspec env file")
	}
	key, err := parseTokenKey(rawKey)
	if err != nil {
		return frontConfig{}, fmt.Errorf("SUBSONIC_TOKEN_KEY: %w", err)
	}
	cfg.tokenKeys = map[string][]byte{cfg.tokenKid: key}

	ttl, err := parseTokenTTL(getenv("SUBSONIC_TOKEN_TTL", defaultFrontTokenTTL.String()))
	if err != nil {
		return frontConfig{}, fmt.Errorf("SUBSONIC_TOKEN_TTL: %w", err)
	}
	cfg.tokenTTL = ttl

	return cfg, nil
}

type bridgeDeps struct {
	identityHeader  string
	pathPrefix      string
	adminUser       string
	publicCoverPath string
	signer          *tokenSigner
	upstream        *url.URL
	// salt is a seam for tests; production uses randomHex(3).
	salt func() (string, error)
}

// bridgeServer authenticates a gated browser request and proxies it to Octo
// with a derived Subsonic credential.
type bridgeServer struct {
	identityHeader  string
	pathPrefix      string
	adminUser       string
	publicCoverPath string
	signer          *tokenSigner
	proxy           *httputil.ReverseProxy
	salt            func() (string, error)
}

func newBridgeServer(d bridgeDeps) *bridgeServer {
	proxy := httputil.NewSingleHostReverseProxy(d.upstream)
	// Stream audio and Range responses without buffering.
	proxy.FlushInterval = -1
	proxy.ErrorHandler = func(w http.ResponseWriter, _ *http.Request, err error) {
		log.Printf("subsonic-bridge: upstream error: %v", err)
		http.Error(w, "bad gateway", http.StatusBadGateway)
	}
	salt := d.salt
	if salt == nil {
		salt = func() (string, error) { return randomHex(3) }
	}
	return &bridgeServer{
		identityHeader:  d.identityHeader,
		pathPrefix:      d.pathPrefix,
		adminUser:       d.adminUser,
		publicCoverPath: d.publicCoverPath,
		signer:          d.signer,
		proxy:           proxy,
		salt:            salt,
	}
}

func (b *bridgeServer) Handler() http.Handler { return http.HandlerFunc(b.handle) }

func (b *bridgeServer) handle(w http.ResponseWriter, r *http.Request) {
	if b.publicCoverPath != "" && r.URL.Path == b.publicCoverPath {
		b.handlePublicCover(w, r)
		return
	}

	rest, ok := b.restPath(r.URL.Path)
	if !ok {
		http.NotFound(w, r)
		return
	}

	// The gate is the only writer of this header (the edge and the gate strip
	// inbound copies), so it is the single identity source. Every other identity
	// header is dropped rather than forwarded.
	identity := strings.TrimSpace(r.Header.Get(b.identityHeader))
	scrubIdentityHeaders(r.Header)
	if identity == "" {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	token, err := b.signer.Sign(identity)
	if err != nil {
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	salt, err := b.salt()
	if err != nil {
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}

	r.Header.Del("Authorization")
	r.Header.Del(ndAuthHeader)
	r.URL.Path = rest
	r.URL.RawPath = ""

	q := r.URL.Query()
	// Drop any credential the client sent: the token minted here is the only
	// one Octo and the shim should see, and a client-supplied PAT must never
	// reach them (or their logs).
	for _, k := range []string{"u", "p", "t", "s"} {
		q.Del(k)
	}
	q.Set("u", identity)
	q.Set("t", token)
	q.Set("s", salt)
	r.URL.RawQuery = q.Encode()

	b.proxy.ServeHTTP(w, r)
}

// handlePublicCover serves the one unauthenticated path. The client's identity,
// credential and every other Subsonic parameter are discarded; the request goes
// to Octo as the configured admin with a fresh short-lived token.
func (b *bridgeServer) handlePublicCover(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET, HEAD")
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	token, err := b.signer.Sign(b.adminUser)
	if err != nil {
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	salt, err := b.salt()
	if err != nil {
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}

	r.Header.Del("Authorization")
	r.Header.Del(ndAuthHeader)
	scrubIdentityHeaders(r.Header)
	r.URL.Path = coverArtPath
	r.URL.RawPath = ""

	in := r.URL.Query()
	q := make(url.Values, 3)
	for _, k := range []string{"id", "size", "v", "c", "f"} {
		if values, ok := in[k]; ok {
			q[k] = values
		}
	}
	q.Set("u", b.adminUser)
	q.Set("t", token)
	q.Set("s", salt)
	r.URL.RawQuery = q.Encode()

	b.proxy.ServeHTTP(w, r)
}

// validatePublicCoverPath keeps the public surface a single, exact REST path:
// no wildcard, no trailing slash, nothing outside `/rest/`.
func validatePublicCoverPath(p string) error {
	if !strings.HasPrefix(p, "/rest/") || p == "/rest/" {
		return fmt.Errorf("must be a single path under /rest/, got %q", p)
	}
	if strings.HasSuffix(p, "/") || strings.ContainsAny(p, "*? ") {
		return fmt.Errorf("must be an exact path without a trailing slash or wildcard, got %q", p)
	}
	return nil
}

// restPath maps `/feishin/rest/…` to the `/rest/…` path Octo serves. Only the
// whole-segment prefix is accepted and the remainder must be the Subsonic API,
// so the bridge cannot be used as a general Octo proxy.
func (b *bridgeServer) restPath(p string) (string, bool) {
	if p != b.pathPrefix && !strings.HasPrefix(p, b.pathPrefix+"/") {
		return "", false
	}
	rest := strings.TrimPrefix(p, b.pathPrefix)
	if rest == "" {
		rest = "/"
	}
	if rest != "/rest" && !strings.HasPrefix(rest, "/rest/") {
		return "", false
	}
	return rest, true
}
