package main

import (
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

const bridgeIdentity = "dummy-DO-NOT-USE@example.invalid"

type bridgeCapture struct {
	hits      int32
	path      string
	rawQuery  string
	identity  string
	auth      string
	ndAuth    string
	userAgent string
}

func fakeBridgeUpstream(t *testing.T, cap *bridgeCapture) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&cap.hits, 1)
		cap.path = r.URL.Path
		cap.rawQuery = r.URL.RawQuery
		cap.identity = r.Header.Get("X-Forwarded-Preferred-Username")
		cap.auth = r.Header.Get("Authorization")
		cap.ndAuth = r.Header.Get(ndAuthHeader)
		cap.userAgent = r.Header.Get("User-Agent")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	}))
}

func newBridge(t *testing.T, upstreamURL string, ttl time.Duration) *bridgeServer {
	t.Helper()
	u, err := url.Parse(upstreamURL)
	if err != nil {
		t.Fatalf("parse upstream: %v", err)
	}
	return newBridgeServer(bridgeDeps{
		identityHeader: "X-Forwarded-Preferred-Username",
		pathPrefix:     "/feishin",
		signer:         testSigner(t, ttl),
		upstream:       u,
		salt:           func() (string, error) { return "abcdef", nil },
	})
}

func bridgeRequest(t *testing.T, srv *bridgeServer, method, path string, headers map[string]string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(method, path, nil)
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	rec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec, req)
	return rec
}

// TestBridgeMintsTokenAndProxies is the happy path: the gate's identity header
// becomes a signed token in `t`, the client's own credentials never reach Octo,
// and the rest of the Subsonic query is preserved.
func TestBridgeMintsTokenAndProxies(t *testing.T) {
	cap := &bridgeCapture{}
	up := fakeBridgeUpstream(t, cap)
	defer up.Close()

	srv := newBridge(t, up.URL, time.Hour)
	rec := bridgeRequest(t, srv, http.MethodGet,
		"/feishin/rest/ping.view?u=attacker&p=dummy-DO-NOT-USE-pat&t=stale&s=stale&v=1.16.1&c=Feishin&f=json",
		map[string]string{
			"X-Forwarded-Preferred-Username": bridgeIdentity,
			"X-Auth-Request-User":            "attacker",
			"Authorization":                  "Basic YXR0YWNrZXI6cGF0",
			ndAuthHeader:                     "Bearer client-token",
		})

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 (body %q)", rec.Code, rec.Body.String())
	}
	if got := atomic.LoadInt32(&cap.hits); got != 1 {
		t.Fatalf("upstream hits = %d, want 1", got)
	}
	if cap.path != "/rest/ping.view" {
		t.Fatalf("upstream path = %q, want /rest/ping.view", cap.path)
	}
	if cap.identity != "" || cap.auth != "" || cap.ndAuth != "" {
		t.Fatalf("client credentials or identity leaked upstream: identity=%q auth=%q ndAuth=%q",
			cap.identity, cap.auth, cap.ndAuth)
	}

	q, err := url.ParseQuery(cap.rawQuery)
	if err != nil {
		t.Fatalf("upstream query is not urlencoded: %v", err)
	}
	if got := q.Get("u"); got != bridgeIdentity {
		t.Fatalf("u = %q, want the gate identity %q", got, bridgeIdentity)
	}
	if got := q.Get("s"); got != "abcdef" {
		t.Fatalf("s = %q, want the bridge salt", got)
	}
	if q.Has("p") {
		t.Fatalf("client password forwarded upstream: %q", cap.rawQuery)
	}
	if strings.Contains(cap.rawQuery, "stale") {
		t.Fatalf("client t/s values forwarded upstream: %q", cap.rawQuery)
	}
	for k, want := range map[string]string{"v": "1.16.1", "c": "Feishin", "f": "json"} {
		if got := q.Get(k); got != want {
			t.Fatalf("%s = %q, want %q", k, got, want)
		}
	}

	claims, expired, err := srv.signer.VerifyClaims(q.Get("t"), bridgeIdentity)
	if err != nil {
		t.Fatalf("minted t does not verify: %v", err)
	}
	if expired {
		t.Fatal("minted t is already expired")
	}
	if claims.Sub != bridgeIdentity || claims.Aud != tokenAudience {
		t.Fatalf("minted claims = sub %q aud %q, want %q / %q", claims.Sub, claims.Aud, bridgeIdentity, tokenAudience)
	}
	if got, want := claims.Exp-claims.Iat, int64(time.Hour/time.Second); got != want {
		t.Fatalf("token lifetime = %ds, want %ds", got, want)
	}
}

func TestBridgeEndpointPaths(t *testing.T) {
	tests := []struct {
		name       string
		path       string
		wantStatus int
		wantPath   string
	}{
		{name: "rest collection", path: "/feishin/rest", wantStatus: http.StatusOK, wantPath: "/rest"},
		{name: "rest view", path: "/feishin/rest/ping.view", wantStatus: http.StatusOK, wantPath: "/rest/ping.view"},
		{name: "prefix itself", path: "/feishin", wantStatus: http.StatusNotFound},
		{name: "prefix root", path: "/feishin/", wantStatus: http.StatusNotFound},
		{name: "other octo api", path: "/feishin/api/keepalive", wantStatus: http.StatusNotFound},
		{name: "rest-like sibling", path: "/feishin/restless", wantStatus: http.StatusNotFound},
		{name: "outside the prefix", path: "/rest/ping.view", wantStatus: http.StatusNotFound},
		{name: "admin path", path: "/admin", wantStatus: http.StatusNotFound},
		{name: "path traversal lookalike", path: "/feishin/../rest/ping.view", wantStatus: http.StatusNotFound},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			cap := &bridgeCapture{}
			up := fakeBridgeUpstream(t, cap)
			defer up.Close()
			srv := newBridge(t, up.URL, time.Hour)

			rec := bridgeRequest(t, srv, http.MethodGet, tt.path,
				map[string]string{"X-Forwarded-Preferred-Username": bridgeIdentity})
			if rec.Code != tt.wantStatus {
				t.Fatalf("%s: status = %d, want %d (body %q)", tt.path, rec.Code, tt.wantStatus, rec.Body.String())
			}
			if tt.wantStatus != http.StatusOK {
				if got := atomic.LoadInt32(&cap.hits); got != 0 {
					t.Fatalf("%s: upstream called %d times, want 0", tt.path, got)
				}
				return
			}
			if cap.path != tt.wantPath {
				t.Fatalf("%s: upstream path = %q, want %q", tt.path, cap.path, tt.wantPath)
			}
		})
	}
}

func TestBridgeMissingIdentityIsUnauthorized(t *testing.T) {
	cap := &bridgeCapture{}
	up := fakeBridgeUpstream(t, cap)
	defer up.Close()
	srv := newBridge(t, up.URL, time.Hour)

	// A client may send other identity headers; only the gate's header counts.
	rec := bridgeRequest(t, srv, http.MethodGet,
		"/feishin/rest/ping.view?u=attacker&p=dummy-DO-NOT-USE-pat&v=1.16.1&c=Feishin&f=json",
		map[string]string{"X-Auth-Request-User": "attacker"})

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want 401 (body %q)", rec.Code, rec.Body.String())
	}
	if strings.Contains(rec.Body.String(), "dummy-DO-NOT-USE-pat") {
		t.Fatalf("401 body echoed the client credential: %q", rec.Body.String())
	}
	if got := atomic.LoadInt32(&cap.hits); got != 0 {
		t.Fatalf("upstream called %d times without a gate identity", got)
	}
}

func TestLoadFrontConfigDefaults(t *testing.T) {
	for _, k := range []string{
		"LISTEN_ADDR", "UPSTREAM", "PATH_PREFIX", "IDENTITY_HEADER",
		"SUBSONIC_TOKEN_KID", "SUBSONIC_TOKEN_AUD", "SUBSONIC_TOKEN_TTL",
	} {
		t.Setenv(k, "")
	}
	t.Setenv("SUBSONIC_TOKEN_KEY", strings.Repeat("k", 32))

	cfg, err := loadFrontConfig()
	if err != nil {
		t.Fatalf("loadFrontConfig: %v", err)
	}
	if cfg.tokenTTL != time.Hour {
		t.Fatalf("default token TTL = %s, want %s (the native shim's week is not inherited)", cfg.tokenTTL, time.Hour)
	}
	if cfg.pathPrefix != "/feishin" {
		t.Fatalf("default path prefix = %q, want /feishin", cfg.pathPrefix)
	}
	if cfg.identityHeader != "X-Forwarded-Preferred-Username" {
		t.Fatalf("default identity header = %q", cfg.identityHeader)
	}
	if got := cfg.upstream.String(); got != "http://octo:8080" {
		t.Fatalf("default upstream = %q, want http://octo:8080", got)
	}
	if cfg.tokenKid != "1" {
		t.Fatalf("default token kid = %q, want 1", cfg.tokenKid)
	}
}

func TestLoadFrontConfigHonoursTTLAndKey(t *testing.T) {
	t.Setenv("SUBSONIC_TOKEN_KEY", strings.Repeat("k", 32))
	t.Setenv("SUBSONIC_TOKEN_TTL", "90m")

	cfg, err := loadFrontConfig()
	if err != nil {
		t.Fatalf("loadFrontConfig: %v", err)
	}
	if cfg.tokenTTL != 90*time.Minute {
		t.Fatalf("token TTL = %s, want 90m", cfg.tokenTTL)
	}
	if len(cfg.tokenKeys[cfg.tokenKid]) < minTokenKeyLen {
		t.Fatalf("signing key is missing or too short")
	}
}

func TestLoadFrontConfigRequiresTokenKey(t *testing.T) {
	t.Setenv("SUBSONIC_TOKEN_KEY", "")

	_, err := loadFrontConfig()
	if err == nil || !strings.Contains(err.Error(), "SUBSONIC_TOKEN_KEY") {
		t.Fatalf("loadFrontConfig() error = %v, want it to name SUBSONIC_TOKEN_KEY", err)
	}
}

func TestLoadFrontConfigRejectsUpstreamPath(t *testing.T) {
	t.Setenv("SUBSONIC_TOKEN_KEY", strings.Repeat("k", 32))
	t.Setenv("UPSTREAM", "http://octo:8080/rest")

	_, err := loadFrontConfig()
	if err == nil {
		t.Fatal("loadFrontConfig accepted an upstream with a path; it would double /rest")
	}
}
