package main

import (
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
			name:      "query t+s is unsupported",
			url:       "/rest/ping.view?u=dummy-DO-NOT-USE%40example.invalid&t=abcd&s=efgh",
			wantState: credUnsupportedToken,
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
			user, token, st := extractCredential(r)
			if st != tt.wantState {
				t.Fatalf("state = %v, want %v", st, tt.wantState)
			}
			if user != tt.wantUser || token != tt.wantToken {
				t.Fatalf("credentials = (%q,%q), want (%q,%q)", user, token, tt.wantUser, tt.wantToken)
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
	identityHeader string
	authorization  string
	path           string
	rawQuery       string
	rangeHeader    string
	hits           int32
	body           string
}

func fakeUpstream(t *testing.T, cap *upstreamCapture) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&cap.hits, 1)
		cap.identityHeader = r.Header.Get("X-Forwarded-Preferred-Username")
		cap.authorization = r.Header.Get("Authorization")
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
	return newServer("X-Forwarded-Preferred-Username", newCredCache(ttl, 16), v, u)
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

func TestUnsupportedTokenAuthReturnsCode41(t *testing.T) {
	var kcCalls int32
	kc := fakeKeycloak(t, "dummy-DO-NOT-USE@example.invalid", "pat-123", &kcCalls)
	defer kc.Close()
	cap := &upstreamCapture{}
	up := fakeUpstream(t, cap)
	defer up.Close()

	srv := newTestServer(t, kc.URL, up.URL, time.Minute)
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/rest/ping.view?u=dummy-DO-NOT-USE%40example.invalid&t=abcd&s=efgh&v=1.16.1&c=test&f=json", nil)
	srv.Handler().ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want 401", rec.Code)
	}
	if atomic.LoadInt32(&cap.hits) != 0 {
		t.Fatalf("upstream was called for an unsupported credential")
	}
	var body struct {
		Resp struct {
			Status string `json:"status"`
			Error  struct {
				Code int `json:"code"`
			} `json:"error"`
		} `json:"subsonic-response"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("body is not subsonic json: %v (%q)", err, rec.Body.String())
	}
	if body.Resp.Error.Code != subsonicErrorTokenUnsupported {
		t.Fatalf("error code = %d, want %d", body.Resp.Error.Code, subsonicErrorTokenUnsupported)
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
