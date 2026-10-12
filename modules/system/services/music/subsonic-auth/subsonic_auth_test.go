package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func basic(user, pass string) string {
	return "Basic " + base64.StdEncoding.EncodeToString([]byte(user+":"+pass))
}

// --- credential extraction ---------------------------------------------------

func TestExtractCredential(t *testing.T) {
	tests := []struct {
		name      string
		url       string
		header    string
		wantUser  string
		wantToken string
		wantState credStatus
	}{
		{
			name:      "basic",
			url:       "/rest/ping.view?v=1.16.1&c=test&f=json",
			header:    basic("dummy-DO-NOT-USE@example.invalid", "pat-123"),
			wantUser:  "dummy-DO-NOT-USE@example.invalid",
			wantToken: "pat-123",
			wantState: credOK,
		},
		{
			name:      "query plaintext password",
			url:       "/rest/ping.view?u=dummy-DO-NOT-USE%40example.invalid&p=pat-123",
			wantUser:  "dummy-DO-NOT-USE@example.invalid",
			wantToken: "pat-123",
			wantState: credOK,
		},
		{
			name:      "query enc: hex password",
			url:       "/rest/ping.view?u=dummy-DO-NOT-USE%40example.invalid&p=enc:" + hexOf("pat-123"),
			wantUser:  "dummy-DO-NOT-USE@example.invalid",
			wantToken: "pat-123",
			wantState: credOK,
		},
		{
			name:      "t+s is not a password credential",
			url:       "/rest/ping.view?u=dummy-DO-NOT-USE%40example.invalid&t=abcd&s=efgh",
			wantState: credNone,
		},
		{
			name:      "no credentials",
			url:       "/rest/ping.view?v=1.16.1&c=test&f=json",
			wantState: credNone,
		},
		{
			name:      "malformed basic",
			url:       "/rest/ping.view",
			header:    "Basic not-base64!!",
			wantState: credNone,
		},
		{
			name:      "enc: with bad hex",
			url:       "/rest/ping.view?u=a&p=enc:zzzz",
			wantState: credNone,
		},
		{
			name:      "basic wins over query",
			url:       "/rest/ping.view?u=queryuser&p=querypass",
			header:    basic("basicuser", "basicpass"),
			wantUser:  "basicuser",
			wantToken: "basicpass",
			wantState: credOK,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			r := httptest.NewRequest(http.MethodGet, tt.url, nil)
			if tt.header != "" {
				r.Header.Set("Authorization", tt.header)
			}
			user, token, st := extractCredential(r, nil)
			if st != tt.wantState {
				t.Fatalf("state = %v, want %v", st, tt.wantState)
			}
			if user != tt.wantUser || token != tt.wantToken {
				t.Fatalf("credentials = (%q,%q), want (%q,%q)", user, token, tt.wantUser, tt.wantToken)
			}
		})
	}
}

func TestBearerToken(t *testing.T) {
	tests := []struct {
		name   string
		header string
		want   string
	}{
		{name: "bearer", header: "Bearer tok-1", want: "tok-1"},
		{name: "bearer scheme case-insensitive", header: "bearer tok-1", want: "tok-1"},
		{name: "non-bearer ignored", header: "Basic abc", want: ""},
		{name: "empty", header: "", want: ""},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := bearerToken(tt.header); got != tt.want {
				t.Fatalf("bearerToken(%q) = %q, want %q", tt.header, got, tt.want)
			}
		})
	}
}

func hexOf(s string) string {
	const hexdigits = "0123456789abcdef"
	var b strings.Builder
	for _, c := range []byte(s) {
		b.WriteByte(hexdigits[c>>4])
		b.WriteByte(hexdigits[c&0xf])
	}
	return b.String()
}

// --- end-to-end handler ------------------------------------------------------

// fakeKeycloak answers the PAT endpoint: 200 + X-User when the Basic password
// equals wantToken, otherwise 401.
func fakeKeycloak(t *testing.T, wantUser, wantToken string, calls *int32) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(calls, 1)
		u, p, ok := r.BasicAuth()
		if !ok || u != wantUser || p != wantToken {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		w.Header().Set("X-User", u)
		w.Header().Set("X-User-Id", "uuid-1")
		w.WriteHeader(http.StatusOK)
	}))
}

type upstreamCapture struct {
	identityHeader  string
	authorization   string
	ndAuthorization string
	path            string
	rawQuery        string
	rangeHeader     string
	hits            int32
	body            string
}

func fakeUpstream(t *testing.T, cap *upstreamCapture) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&cap.hits, 1)
		cap.identityHeader = r.Header.Get("X-Forwarded-Preferred-Username")
		cap.authorization = r.Header.Get("Authorization")
		cap.ndAuthorization = r.Header.Get(ndAuthHeader)
		cap.path = r.URL.Path
		cap.rawQuery = r.URL.RawQuery
		cap.rangeHeader = r.Header.Get("Range")
		b, _ := io.ReadAll(r.Body)
		cap.body = string(b)
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	}))
}

func newTestServer(t *testing.T, keycloakURL string, upstreamURL string, ttl time.Duration) *server {
	t.Helper()
	u, err := url.Parse(upstreamURL)
	if err != nil {
		t.Fatalf("parse upstream: %v", err)
	}
	v, err := newValidator(keycloakURL, "dummy-DO-NOT-USE-realm", &http.Client{Timeout: 2 * time.Second})
	if err != nil {
		t.Fatalf("validator: %v", err)
	}
	return newServer(serverDeps{
		identityHeader: "X-Forwarded-Preferred-Username",
		cache:          newCredCache(ttl, 16),
		signer:         testSigner(t, ttl),
		validator:      v,
		upstream:       u,
	})
}

func postLogin(t *testing.T, srv *server, user, pass string) *httptest.ResponseRecorder {
	t.Helper()
	b, err := json.Marshal(loginRequest{Username: user, Password: pass})
	if err != nil {
		t.Fatalf("marshal login: %v", err)
	}
	req := httptest.NewRequest(http.MethodPost, loginPath, bytes.NewReader(b))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec, req)
	return rec
}

func TestLoginReturnsDerivedTokenNotPAT(t *testing.T) {
	var kcCalls int32
	kc := fakeKeycloak(t, "dummy-DO-NOT-USE@example.invalid", "pat-123", &kcCalls)
	defer kc.Close()
	up := fakeUpstream(t, &upstreamCapture{})
	defer up.Close()

	srv := newTestServer(t, kc.URL, up.URL, time.Minute)
	rec := postLogin(t, srv, "dummy-DO-NOT-USE@example.invalid", "pat-123")
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 (body %q)", rec.Code, rec.Body.String())
	}

	var resp loginResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("body is not json: %v (%q)", err, rec.Body.String())
	}
	if resp.ID != "dummy-DO-NOT-USE@example.invalid" || resp.Name != "dummy-DO-NOT-USE@example.invalid" || resp.Username != "dummy-DO-NOT-USE@example.invalid" {
		t.Fatalf("identity fields = (%q,%q,%q), want dummy-DO-NOT-USE@example.invalid", resp.ID, resp.Name, resp.Username)
	}
	if resp.IsAdmin {
		t.Fatalf("isAdmin = true, want false")
	}
	if len(resp.SubsonicSalt) != 6 {
		t.Fatalf("subsonicSalt = %q, want 6 hex chars", resp.SubsonicSalt)
	}
	// The PAT must NEVER be handed back: both fields are a derived signed token.
	if resp.SubsonicToken == "pat-123" || resp.Token == "pat-123" {
		t.Fatalf("login returned the raw PAT (subsonicToken=%q token=%q)", resp.SubsonicToken, resp.Token)
	}
	for name, tok := range map[string]string{"subsonicToken": resp.SubsonicToken, "token": resp.Token} {
		if !strings.HasPrefix(tok, "v1.") {
			t.Fatalf("%s = %q, want a v1 signed token", name, tok)
		}
		if _, err := srv.signer.Verify(tok, "dummy-DO-NOT-USE@example.invalid"); err != nil {
			t.Fatalf("%s does not verify: %v", name, err)
		}
		if _, err := srv.signer.Verify(tok, "dummy-DO-NOT-USE-other@example.invalid"); err == nil {
			t.Fatalf("%s verified for a different u", name)
		}
	}
}

func TestLoginBadPATReturns401(t *testing.T) {
	tests := []struct {
		name string
		user string
		pass string
	}{
		{name: "wrong password", user: "dummy-DO-NOT-USE@example.invalid", pass: "wrong-pat"},
		{name: "empty password", user: "dummy-DO-NOT-USE@example.invalid", pass: ""},
		{name: "empty username", user: "", pass: "pat-123"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var kcCalls int32
			kc := fakeKeycloak(t, "dummy-DO-NOT-USE@example.invalid", "pat-123", &kcCalls)
			defer kc.Close()
			up := fakeUpstream(t, &upstreamCapture{})
			defer up.Close()

			srv := newTestServer(t, kc.URL, up.URL, time.Minute)
			rec := postLogin(t, srv, tt.user, tt.pass)
			if rec.Code != http.StatusUnauthorized {
				t.Fatalf("status = %d, want 401", rec.Code)
			}
			if ct := rec.Header().Get("Content-Type"); !strings.Contains(ct, "application/json") {
				t.Fatalf("content-type = %q, want json", ct)
			}
		})
	}
}

func TestLoginMalformedJSONReturns401(t *testing.T) {
	var kcCalls int32
	kc := fakeKeycloak(t, "dummy-DO-NOT-USE@example.invalid", "pat-123", &kcCalls)
	defer kc.Close()
	up := fakeUpstream(t, &upstreamCapture{})
	defer up.Close()

	srv := newTestServer(t, kc.URL, up.URL, time.Minute)
	req := httptest.NewRequest(http.MethodPost, loginPath, strings.NewReader("not json"))
	rec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want 401", rec.Code)
	}
}

// TestCredentialResolution covers every way a native request can be
// authenticated (and the ways it must be rejected), end to end through the
// handler.
func TestCredentialResolution(t *testing.T) {
	tests := []struct {
		name         string
		path         string
		setHeaders   map[string]string
		wantStatus   int
		wantIdentity string // "" means the upstream must not be called
		wantCode     int    // Subsonic error code, 0 when not applicable
	}{
		{
			name:         "api bearer signed token",
			path:         "/api/keepalive",
			setHeaders:   map[string]string{ndAuthHeader: "Bearer {token}"},
			wantStatus:   http.StatusOK,
			wantIdentity: "dummy-DO-NOT-USE@example.invalid",
		},
		{
			name:         "api bearer signed token lowercase scheme",
			path:         "/api/keepalive",
			setHeaders:   map[string]string{ndAuthHeader: "bearer {token}"},
			wantStatus:   http.StatusOK,
			wantIdentity: "dummy-DO-NOT-USE@example.invalid",
		},
		{
			name:         "rest t signed token",
			path:         "/rest/ping.view?u=dummy-DO-NOT-USE%40example.invalid&t={token}&s=abcdef&v=1.16.1&c=test&f=json",
			wantStatus:   http.StatusOK,
			wantIdentity: "dummy-DO-NOT-USE@example.invalid",
		},
		{
			name:       "rest t signed token bound to a different u",
			path:       "/rest/ping.view?u=dummy-DO-NOT-USE-other%40example.invalid&t={token}&s=abcdef&v=1.16.1&c=test&f=json",
			wantStatus: http.StatusUnauthorized,
			wantCode:   subsonicErrorWrongCredentials,
		},
		{
			name:       "rest t carrying a raw PAT is refused",
			path:       "/rest/ping.view?u=dummy-DO-NOT-USE%40example.invalid&t=pat-123&s=abcdef&v=1.16.1&c=test&f=json",
			wantStatus: http.StatusUnauthorized,
			wantCode:   subsonicErrorWrongCredentials,
		},
		{
			name:         "basic pat",
			path:         "/rest/ping.view?v=1.16.1&c=test&f=json",
			setHeaders:   map[string]string{"Authorization": basic("dummy-DO-NOT-USE@example.invalid", "pat-123")},
			wantStatus:   http.StatusOK,
			wantIdentity: "dummy-DO-NOT-USE@example.invalid",
		},
		{
			name:         "query u p pat",
			path:         "/rest/ping.view?u=dummy-DO-NOT-USE%40example.invalid&p=pat-123&v=1.16.1&c=test&f=json",
			wantStatus:   http.StatusOK,
			wantIdentity: "dummy-DO-NOT-USE@example.invalid",
		},
		{
			name:       "unknown t",
			path:       "/rest/ping.view?u=dummy-DO-NOT-USE%40example.invalid&t=unknown&s=abcdef&v=1.16.1&c=test&f=json",
			wantStatus: http.StatusUnauthorized,
			wantCode:   subsonicErrorWrongCredentials,
		},
		{
			name:       "unknown bearer token",
			path:       "/api/keepalive",
			setHeaders: map[string]string{ndAuthHeader: "Bearer expired"},
			wantStatus: http.StatusUnauthorized,
		},
		{
			name:       "invalid pat",
			path:       "/rest/ping.view",
			setHeaders: map[string]string{"Authorization": basic("dummy-DO-NOT-USE@example.invalid", "wrong-pat")},
			wantStatus: http.StatusUnauthorized,
			wantCode:   subsonicErrorWrongCredentials,
		},
		{
			name:       "no credentials",
			path:       "/rest/ping.view?v=1.16.1&c=test&f=json",
			wantStatus: http.StatusUnauthorized,
			wantCode:   subsonicErrorWrongCredentials,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var kcCalls int32
			kc := fakeKeycloak(t, "dummy-DO-NOT-USE@example.invalid", "pat-123", &kcCalls)
			defer kc.Close()
			cap := &upstreamCapture{}
			up := fakeUpstream(t, cap)
			defer up.Close()

			srv := newTestServer(t, kc.URL, up.URL, time.Minute)
			token, err := srv.signer.Sign("dummy-DO-NOT-USE@example.invalid")
			if err != nil {
				t.Fatalf("sign: %v", err)
			}

			path := strings.ReplaceAll(tt.path, "{token}", token)
			req := httptest.NewRequest(http.MethodGet, path, nil)
			for k, v := range tt.setHeaders {
				req.Header.Set(k, strings.ReplaceAll(v, "{token}", token))
			}
			rec := httptest.NewRecorder()
			srv.Handler().ServeHTTP(rec, req)

			if rec.Code != tt.wantStatus {
				t.Fatalf("status = %d, want %d (body %q)", rec.Code, tt.wantStatus, rec.Body.String())
			}
			if tt.wantIdentity == "" {
				if got := atomic.LoadInt32(&cap.hits); got != 0 {
					t.Fatalf("upstream called %d times, want 0", got)
				}
			} else {
				if got := atomic.LoadInt32(&cap.hits); got != 1 {
					t.Fatalf("upstream called %d times, want 1", got)
				}
				if cap.identityHeader != tt.wantIdentity {
					t.Fatalf("upstream identity = %q, want %q", cap.identityHeader, tt.wantIdentity)
				}
				if cap.authorization != "" || cap.ndAuthorization != "" {
					t.Fatalf("upstream saw client credentials: Authorization=%q ndAuth=%q", cap.authorization, cap.ndAuthorization)
				}
			}
			if tt.wantCode != 0 {
				if !strings.HasPrefix(path, "/rest") {
					t.Fatalf("wantCode set for non-rest path %q", path)
				}
				if got := subsonicErrorCode(t, rec.Body.Bytes()); got != tt.wantCode {
					t.Fatalf("subsonic error code = %d, want %d (%q)", got, tt.wantCode, rec.Body.String())
				}
			}
		})
	}
}

func subsonicErrorCode(t *testing.T, body []byte) int {
	t.Helper()
	var resp struct {
		Subsonic struct {
			Error struct {
				Code int `json:"code"`
			} `json:"error"`
		} `json:"subsonic-response"`
	}
	if err := json.Unmarshal(body, &resp); err != nil {
		t.Fatalf("body is not subsonic json: %v (%q)", err, body)
	}
	return resp.Subsonic.Error.Code
}

func TestRestSignedTokenIsStrippedUpstream(t *testing.T) {
	var kcCalls int32
	kc := fakeKeycloak(t, "dummy-DO-NOT-USE@example.invalid", "pat-123", &kcCalls)
	defer kc.Close()
	cap := &upstreamCapture{}
	up := fakeUpstream(t, cap)
	defer up.Close()

	srv := newTestServer(t, kc.URL, up.URL, time.Minute)
	token, err := srv.signer.Sign("dummy-DO-NOT-USE@example.invalid")
	if err != nil {
		t.Fatalf("sign: %v", err)
	}
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/rest/scrobble.view?u=dummy-DO-NOT-USE%40example.invalid&t="+token+"&s=abcdef&id=x&submission=false&v=1.16.1&c=test&f=json", nil)
	srv.Handler().ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	if cap.identityHeader != "dummy-DO-NOT-USE@example.invalid" {
		t.Fatalf("upstream identity = %q", cap.identityHeader)
	}
	for _, k := range []string{"t=", "s="} {
		if strings.Contains(cap.rawQuery, k) {
			t.Fatalf("credential param %q forwarded upstream: %q", k, cap.rawQuery)
		}
	}
}

// TestPublicCoverArtPassthrough is the S1 regression test: Navidrome serves
// artist/album art as a public `/share/img/<signed-token>` URL, and a native
// client reaches it through this shim (edge routes `/share*` without a session
// cookie here). It must pass through with no credential and no identity header —
// Navidrome authorises it by the token in the path.
func TestPublicCoverArtPassthrough(t *testing.T) {
	var kcCalls int32
	kc := fakeKeycloak(t, "dummy-DO-NOT-USE@example.invalid", "pat-123", &kcCalls)
	defer kc.Close()
	cap := &upstreamCapture{}
	up := fakeUpstream(t, cap)
	defer up.Close()

	srv := newTestServer(t, kc.URL, up.URL, time.Minute)
	for _, path := range []string{
		"/share/img/eyJhbGciOiJIUzI1NiJ9.abc.def?size=1200",
		"/share/img",
	} {
		cap.hits = 0
		cap.identityHeader = "unset"
		rec := httptest.NewRecorder()
		req := httptest.NewRequest(http.MethodGet, path, nil)
		// A public path must ignore any credential and any spoofed identity.
		req.Header.Set("Authorization", basic("attacker", "x"))
		req.Header.Set("X-Forwarded-Preferred-Username", "attacker")
		srv.Handler().ServeHTTP(rec, req)

		if rec.Code != http.StatusOK {
			t.Fatalf("%s: status = %d, want 200 (body %q)", path, rec.Code, rec.Body.String())
		}
		if atomic.LoadInt32(&cap.hits) != 1 {
			t.Fatalf("%s: upstream hits = %d, want 1", path, cap.hits)
		}
		if cap.identityHeader != "" {
			t.Fatalf("%s: identity header leaked upstream: %q", path, cap.identityHeader)
		}
	}
	resetKC := atomic.SwapInt32(&kcCalls, 0)
	if resetKC != 0 {
		t.Fatalf("keycloak called %d times for a public image", resetKC)
	}
}

// TestPrivateSharePathsStillRequireCredentials guards the public-image
// allowlist against being widened: every other `/share/*` path stays
// credential-gated (no unauthenticated passthrough).
func TestPrivateSharePathsStillRequireCredentials(t *testing.T) {
	var kcCalls int32
	kc := fakeKeycloak(t, "dummy-DO-NOT-USE@example.invalid", "pat-123", &kcCalls)
	defer kc.Close()
	cap := &upstreamCapture{}
	up := fakeUpstream(t, cap)
	defer up.Close()

	srv := newTestServer(t, kc.URL, up.URL, time.Minute)
	for _, path := range []string{"/share/abc123", "/share", "/shareX/img", "/share/imaginary"} {
		rec := httptest.NewRecorder()
		req := httptest.NewRequest(http.MethodGet, path, nil)
		srv.Handler().ServeHTTP(rec, req)
		if rec.Code != http.StatusUnauthorized {
			t.Fatalf("%s: status = %d, want 401", path, rec.Code)
		}
	}
	if atomic.LoadInt32(&cap.hits) != 0 {
		t.Fatalf("upstream called %d times for private share paths", cap.hits)
	}
}

// TestFormPostCredentialResolution covers OpenSubsonic `formPost` clients
// (Feishin's "Navidrome" server type), which send the credential in a urlencoded
// POST body instead of the query string.
func TestFormPostCredentialResolution(t *testing.T) {
	tests := []struct {
		name       string
		body       string
		wantStatus int
		wantCode   int
	}{
		{
			name:       "body u p pat",
			body:       "u=dummy-DO-NOT-USE%40example.invalid&p=pat-123&id=x&submission=false&c=Feishin&f=json&v=1.13.0",
			wantStatus: http.StatusOK,
		},
		{
			name:       "body t signed token",
			body:       "u=dummy-DO-NOT-USE%40example.invalid&t={token}&s=abcdef&id=x&submission=false&c=Feishin&f=json&v=1.13.0",
			wantStatus: http.StatusOK,
		},
		{
			name:       "body t raw PAT is refused",
			body:       "u=dummy-DO-NOT-USE%40example.invalid&t=pat-123&s=abcdef&id=x&submission=false&c=Feishin&f=json&v=1.13.0",
			wantStatus: http.StatusUnauthorized,
			wantCode:   subsonicErrorWrongCredentials,
		},
		{
			name:       "body without credential",
			body:       "id=x&submission=false&c=Feishin&f=json&v=1.13.0",
			wantStatus: http.StatusUnauthorized,
			wantCode:   subsonicErrorWrongCredentials,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var kcCalls int32
			kc := fakeKeycloak(t, "dummy-DO-NOT-USE@example.invalid", "pat-123", &kcCalls)
			defer kc.Close()
			cap := &upstreamCapture{}
			up := fakeUpstream(t, cap)
			defer up.Close()

			srv := newTestServer(t, kc.URL, up.URL, time.Minute)
			token, err := srv.signer.Sign("dummy-DO-NOT-USE@example.invalid")
			if err != nil {
				t.Fatalf("sign: %v", err)
			}
			body := strings.ReplaceAll(tt.body, "{token}", token)
			req := httptest.NewRequest(http.MethodPost, "/rest/scrobble.view", strings.NewReader(body))
			req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
			rec := httptest.NewRecorder()
			srv.Handler().ServeHTTP(rec, req)

			if rec.Code != tt.wantStatus {
				t.Fatalf("status = %d, want %d (body %q)", rec.Code, tt.wantStatus, rec.Body.String())
			}
			if tt.wantStatus != http.StatusOK {
				if tt.wantCode != 0 {
					if got := subsonicErrorCode(t, rec.Body.Bytes()); got != tt.wantCode {
						t.Fatalf("subsonic error code = %d, want %d", got, tt.wantCode)
					}
				}
				if atomic.LoadInt32(&cap.hits) != 0 {
					t.Fatalf("upstream called for a rejected request")
				}
				return
			}
			if atomic.LoadInt32(&cap.hits) != 1 {
				t.Fatalf("upstream hits = %d, want 1", cap.hits)
			}
			if cap.identityHeader != "dummy-DO-NOT-USE@example.invalid" {
				t.Fatalf("upstream identity = %q, want dummy-DO-NOT-USE@example.invalid", cap.identityHeader)
			}
			if cap.path != "/rest/scrobble.view" {
				t.Fatalf("upstream path = %q", cap.path)
			}
			for _, k := range []string{"p=", "t=", "s="} {
				if strings.Contains(cap.body, k) {
					t.Fatalf("credential %q forwarded in the body: %q", k, cap.body)
				}
			}
			if !strings.Contains(cap.body, "submission=false") {
				t.Fatalf("non-credential body params dropped: %q", cap.body)
			}
		})
	}
}

func TestHappyPathInjectsIdentity(t *testing.T) {
	var kcCalls int32
	kc := fakeKeycloak(t, "dummy-DO-NOT-USE@example.invalid", "pat-123", &kcCalls)
	defer kc.Close()
	cap := &upstreamCapture{}
	up := fakeUpstream(t, cap)
	defer up.Close()

	srv := newTestServer(t, kc.URL, up.URL, time.Minute)
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/rest/ping.view?v=1.16.1&c=test&f=json", nil)
	req.Header.Set("Authorization", basic("dummy-DO-NOT-USE@example.invalid", "pat-123"))
	srv.Handler().ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 (body %q)", rec.Code, rec.Body.String())
	}
	if cap.identityHeader != "dummy-DO-NOT-USE@example.invalid" {
		t.Fatalf("upstream identity header = %q, want dummy-DO-NOT-USE@example.invalid", cap.identityHeader)
	}
	if cap.authorization != "" {
		t.Fatalf("upstream saw Authorization %q; must be stripped", cap.authorization)
	}
	if cap.path != "/rest/ping.view" {
		t.Fatalf("upstream path = %q", cap.path)
	}
	if !strings.Contains(cap.rawQuery, "v=1.16.1") {
		t.Fatalf("upstream query = %q; expected v preserved", cap.rawQuery)
	}
}

func TestSpoofedIdentityHeaderIsStripped(t *testing.T) {
	var kcCalls int32
	kc := fakeKeycloak(t, "dummy-DO-NOT-USE@example.invalid", "pat-123", &kcCalls)
	defer kc.Close()
	cap := &upstreamCapture{}
	up := fakeUpstream(t, cap)
	defer up.Close()

	srv := newTestServer(t, kc.URL, up.URL, time.Minute)
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/rest/ping.view", nil)
	req.Header.Set("Authorization", basic("dummy-DO-NOT-USE@example.invalid", "pat-123"))
	req.Header.Set("X-Forwarded-Preferred-Username", "attacker")
	req.Header.Set("X-Auth-Request-User", "attacker")
	req.Header.Set("Remote-User", "attacker")
	srv.Handler().ServeHTTP(rec, req)

	if cap.identityHeader != "dummy-DO-NOT-USE@example.invalid" {
		t.Fatalf("identity header = %q; spoof was not overwritten", cap.identityHeader)
	}
}

func TestInvalidTokenDeniedNoHeader(t *testing.T) {
	var kcCalls int32
	kc := fakeKeycloak(t, "dummy-DO-NOT-USE@example.invalid", "pat-123", &kcCalls)
	defer kc.Close()
	cap := &upstreamCapture{}
	up := fakeUpstream(t, cap)
	defer up.Close()

	srv := newTestServer(t, kc.URL, up.URL, time.Minute)
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/rest/ping.view?v=1.16.1&c=test&f=json", nil)
	req.Header.Set("Authorization", basic("dummy-DO-NOT-USE@example.invalid", "wrong-pat"))
	srv.Handler().ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want 401", rec.Code)
	}
	if atomic.LoadInt32(&cap.hits) != 0 {
		t.Fatalf("upstream was called for an invalid credential")
	}
}

func TestPositiveCacheSkipsKeycloak(t *testing.T) {
	var kcCalls int32
	kc := fakeKeycloak(t, "dummy-DO-NOT-USE@example.invalid", "pat-123", &kcCalls)
	defer kc.Close()
	cap := &upstreamCapture{}
	up := fakeUpstream(t, cap)
	defer up.Close()

	srv := newTestServer(t, kc.URL, up.URL, time.Minute)
	for i := 0; i < 5; i++ {
		rec := httptest.NewRecorder()
		req := httptest.NewRequest(http.MethodGet, "/rest/ping.view", nil)
		req.Header.Set("Authorization", basic("dummy-DO-NOT-USE@example.invalid", "pat-123"))
		srv.Handler().ServeHTTP(rec, req)
		if rec.Code != http.StatusOK {
			t.Fatalf("call %d status = %d", i, rec.Code)
		}
	}
	if got := atomic.LoadInt32(&kcCalls); got != 1 {
		t.Fatalf("keycloak called %d times, want 1 (cache miss then hits)", got)
	}
	if got := atomic.LoadInt32(&cap.hits); got != 5 {
		t.Fatalf("upstream called %d times, want 5", got)
	}
}

func TestCacheExpiry(t *testing.T) {
	kc := &credCache{m: map[[32]byte]cacheEntry{}, ttl: 20 * time.Millisecond, max: 4}
	key := [32]byte{1}
	kc.set(key, "dummy-DO-NOT-USE@example.invalid")
	if _, ok := kc.get(key); !ok {
		t.Fatal("entry should be a fresh hit")
	}
	time.Sleep(40 * time.Millisecond)
	if _, ok := kc.get(key); ok {
		t.Fatal("entry should have expired")
	}
}

func TestCacheIsBounded(t *testing.T) {
	kc := &credCache{m: map[[32]byte]cacheEntry{}, ttl: time.Minute, max: 3}
	for i := 0; i < 100; i++ {
		kc.set([32]byte{byte(i)}, "u")
	}
	kc.mu.Lock()
	n := len(kc.m)
	kc.mu.Unlock()
	if n > 3 {
		t.Fatalf("cache grew to %d entries, cap is 3", n)
	}
}

func TestRandomHexLength(t *testing.T) {
	for _, n := range []int{3, 32} {
		s, err := randomHex(n)
		if err != nil {
			t.Fatal(err)
		}
		if len(s) != n*2 {
			t.Fatalf("randomHex(%d) = %q, want %d hex chars", n, s, n*2)
		}
	}
}

func TestStripSubsonicCreds(t *testing.T) {
	u, _ := url.Parse("/rest/ping.view?u=dummy-DO-NOT-USE%40example.invalid&p=enc:6162&t=xx&s=yy&v=1.16.1&c=test&f=json")
	stripSubsonicCreds(u)
	q := u.Query()
	for _, k := range []string{"p", "t", "s"} {
		if q.Has(k) {
			t.Fatalf("credential param %q was forwarded", k)
		}
	}
	if !q.Has("v") || !q.Has("c") || !q.Has("f") || !q.Has("u") {
		t.Fatalf("non-credential params dropped: %q", u.RawQuery)
	}
}

func TestValidatorRejectsNon200(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusTooManyRequests)
	}))
	defer srv.Close()
	v, err := newValidator(srv.URL, "dummy-DO-NOT-USE-realm", &http.Client{Timeout: time.Second})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := v.validate(context.Background(), "a", "b"); err == nil {
		t.Fatal("validator accepted a 429")
	}
}
