package main

import (
	"bytes"
	"log"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

const (
	bridgeIdentity = "dummy-DO-NOT-USE@example.invalid"
	bridgeAdmin    = "dummy-admin-DO-NOT-USE@example.invalid"
	publicCover    = "/rest/getCoverArt.view"
)

type bridgeCapture struct {
	hits      int32
	method    string
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
		cap.method = r.Method
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
		identityHeader:  "X-Forwarded-Preferred-Username",
		pathPrefix:      "/feishin",
		adminUser:       bridgeAdmin,
		publicCoverPath: publicCover,
		signer:          testSigner(t, ttl),
		upstream:        u,
		salt:            func() (string, error) { return "abcdef", nil },
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

// TestBridgePublicCoverWithoutIdentity is the public path's happy case: no gate
// identity header, no client credential, and the request still reaches Octo as
// the configured admin with a token that verifies for that admin.
func TestBridgePublicCoverWithoutIdentity(t *testing.T) {
	cap := &bridgeCapture{}
	up := fakeBridgeUpstream(t, cap)
	defer up.Close()
	srv := newBridge(t, up.URL, time.Hour)

	rec := bridgeRequest(t, srv, http.MethodGet,
		publicCover+"?id=al-1&size=300&v=1.16.1&c=Feishin&f=json&u=attacker&p=dummy-DO-NOT-USE-pat&t=stale&s=stale",
		map[string]string{
			"X-Forwarded-Preferred-Username": "attacker@example.invalid",
			"Authorization":                  "Basic YXR0YWNrZXI6cGF0",
			ndAuthHeader:                     "Bearer client-token",
		})

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 (body %q)", rec.Code, rec.Body.String())
	}
	if got := atomic.LoadInt32(&cap.hits); got != 1 {
		t.Fatalf("upstream hits = %d, want 1", got)
	}
	if cap.path != coverArtPath {
		t.Fatalf("upstream path = %q, want %q", cap.path, coverArtPath)
	}
	if cap.method != http.MethodGet {
		t.Fatalf("upstream method = %q, want GET", cap.method)
	}
	if cap.identity != "" || cap.auth != "" || cap.ndAuth != "" {
		t.Fatalf("client identity or credential leaked upstream: identity=%q auth=%q ndAuth=%q",
			cap.identity, cap.auth, cap.ndAuth)
	}

	q, err := url.ParseQuery(cap.rawQuery)
	if err != nil {
		t.Fatalf("upstream query is not urlencoded: %v", err)
	}
	if got := q.Get("u"); got != bridgeAdmin {
		t.Fatalf("u = %q, want the admin identity %q", got, bridgeAdmin)
	}
	if q.Has("p") || strings.Contains(cap.rawQuery, "stale") {
		t.Fatalf("client credential forwarded upstream: %q", cap.rawQuery)
	}
	for k, want := range map[string]string{
		"id": "al-1", "size": "300", "v": "1.16.1", "c": "Feishin", "f": "json",
	} {
		if got := q.Get(k); got != want {
			t.Fatalf("%s = %q, want %q", k, got, want)
		}
	}

	claims, expired, err := srv.signer.VerifyClaims(q.Get("t"), bridgeAdmin)
	if err != nil {
		t.Fatalf("minted t does not verify for the admin: %v", err)
	}
	if expired {
		t.Fatal("minted cover token is already expired")
	}
	if got, want := claims.Exp-claims.Iat, int64(time.Hour/time.Second); got != want {
		t.Fatalf("token lifetime = %ds, want %ds (the bridge TTL)", got, want)
	}
}

func TestBridgePublicCoverAllowsHeadOnly(t *testing.T) {
	for _, tt := range []struct {
		method     string
		wantStatus int
		wantHits   int32
	}{
		{method: http.MethodHead, wantStatus: http.StatusOK, wantHits: 1},
		{method: http.MethodPost, wantStatus: http.StatusMethodNotAllowed, wantHits: 0},
		{method: http.MethodPut, wantStatus: http.StatusMethodNotAllowed, wantHits: 0},
	} {
		t.Run(tt.method, func(t *testing.T) {
			cap := &bridgeCapture{}
			up := fakeBridgeUpstream(t, cap)
			defer up.Close()
			srv := newBridge(t, up.URL, time.Hour)

			rec := bridgeRequest(t, srv, tt.method, publicCover+"?id=al-1", nil)
			if rec.Code != tt.wantStatus {
				t.Fatalf("status = %d, want %d", rec.Code, tt.wantStatus)
			}
			if got := atomic.LoadInt32(&cap.hits); got != tt.wantHits {
				t.Fatalf("upstream hits = %d, want %d", got, tt.wantHits)
			}
		})
	}
}

func TestBridgePublicCoverIsExactAndAlone(t *testing.T) {
	for _, path := range []string{
		"/rest/ping.view",
		"/rest/getAlbum.view?id=al-1",
		"/rest/getArtists.view",
		"/rest/stream?id=tr-1",
		"/rest/search3.view?query=x",
		publicCover + "/",
		publicCover + "/extra",
		"/rest/getCoverArt.viewx",
		"/admin",
	} {
		t.Run(path, func(t *testing.T) {
			cap := &bridgeCapture{}
			up := fakeBridgeUpstream(t, cap)
			defer up.Close()
			srv := newBridge(t, up.URL, time.Hour)

			rec := bridgeRequest(t, srv, http.MethodGet, path, nil)
			if rec.Code != http.StatusNotFound {
				t.Fatalf("%s: status = %d, want 404 (body %q)", path, rec.Code, rec.Body.String())
			}
			if got := atomic.LoadInt32(&cap.hits); got != 0 {
				t.Fatalf("%s: upstream called %d times, want 0", path, got)
			}
		})
	}
}

func TestBridgePublicCoverDoesNotLogToken(t *testing.T) {
	cap := &bridgeCapture{}
	up := fakeBridgeUpstream(t, cap)
	defer up.Close()
	srv := newBridge(t, up.URL, time.Hour)

	var logs bytes.Buffer
	original := log.Writer()
	log.SetOutput(&logs)
	defer log.SetOutput(original)

	rec := bridgeRequest(t, srv, http.MethodGet, publicCover+"?id=al-1&size=300", nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	q, err := url.ParseQuery(cap.rawQuery)
	if err != nil {
		t.Fatalf("upstream query is not urlencoded: %v", err)
	}
	token := q.Get("t")
	if token == "" {
		t.Fatal("no token was minted")
	}
	if strings.Contains(logs.String(), token) {
		t.Fatalf("log output contains the minted token: %q", logs.String())
	}
}

func TestLoadFrontConfigPublicCover(t *testing.T) {
	t.Setenv("SUBSONIC_TOKEN_KEY", strings.Repeat("k", 32))
	t.Setenv("ADMIN_USER", bridgeAdmin)
	t.Setenv("PUBLIC_COVER_PATH", publicCover)

	cfg, err := loadFrontConfig()
	if err != nil {
		t.Fatalf("loadFrontConfig: %v", err)
	}
	if cfg.publicCoverPath != publicCover {
		t.Fatalf("public cover path = %q, want %q", cfg.publicCoverPath, publicCover)
	}
	if cfg.adminUser != bridgeAdmin {
		t.Fatalf("admin user = %q, want %q", cfg.adminUser, bridgeAdmin)
	}
}

func TestLoadFrontConfigPublicCoverNeedsAdmin(t *testing.T) {
	t.Setenv("SUBSONIC_TOKEN_KEY", strings.Repeat("k", 32))
	t.Setenv("ADMIN_USER", "")
	t.Setenv("PUBLIC_COVER_PATH", publicCover)

	_, err := loadFrontConfig()
	if err == nil || !strings.Contains(err.Error(), "ADMIN_USER") {
		t.Fatalf("loadFrontConfig() error = %v, want it to name ADMIN_USER", err)
	}
}

func TestLoadFrontConfigRejectsBroadCoverPath(t *testing.T) {
	t.Setenv("SUBSONIC_TOKEN_KEY", strings.Repeat("k", 32))
	t.Setenv("ADMIN_USER", bridgeAdmin)
	for _, path := range []string{"/rest/*", "/rest/", "/rest", "/cover", publicCover + "/"} {
		t.Setenv("PUBLIC_COVER_PATH", path)
		if _, err := loadFrontConfig(); err == nil {
			t.Fatalf("loadFrontConfig accepted PUBLIC_COVER_PATH %q", path)
		}
	}
}

func TestLoadFrontConfigDefaults(t *testing.T) {
	for _, k := range []string{
		"LISTEN_ADDR", "UPSTREAM", "PATH_PREFIX", "IDENTITY_HEADER",
		"SUBSONIC_TOKEN_KID", "SUBSONIC_TOKEN_AUD", "SUBSONIC_TOKEN_TTL",
		"ADMIN_USER", "PUBLIC_COVER_PATH",
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
