package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

const (
	sessionUser = "dummy-DO-NOT-USE@example.invalid"
	sessionPAT  = "dummy-DO-NOT-USE-pat-session-0123456789"
)

// newSessionServer builds a handler whose store already holds sessionPAT, so a
// `ph` token minted for it passes the per-request lookup.
func newSessionServer(t *testing.T, store *patStore) (*server, *upstreamCapture) {
	t.Helper()
	kc := fakeKeycloak(t, sessionUser, sessionPAT, new(int32))
	t.Cleanup(kc.Close)
	cap := &upstreamCapture{}
	up := fakeUpstream(t, cap)
	t.Cleanup(up.Close)
	return newTestServerWithStore(t, kc.URL, up.URL, time.Hour, store), cap
}

// mintExpiredPATToken mints a PAT-bound token at base and then moves the
// signer's clock past its expiry, returning the now-expired token.
func mintExpiredPATToken(t *testing.T, srv *server) string {
	t.Helper()
	base := time.Unix(1_700_000_000, 0)
	srv.signer.now = func() time.Time { return base }
	token, err := srv.signer.SignWithPAT(sessionUser, sessionPAT)
	if err != nil {
		t.Fatalf("SignWithPAT: %v", err)
	}
	srv.signer.now = func() time.Time { return base.Add(time.Hour) }
	return token
}

func sessionRequest(t *testing.T, srv *server, path, header, token string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodGet, path, nil)
	if header != "" {
		req.Header.Set(header, token)
	}
	rec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec, req)
	return rec
}

// TestUnexpiredTokenRevokedPAT is the revocation guarantee: an unexpired token
// whose PAT has been dropped from the store is refused on both transports.
func TestUnexpiredTokenRevokedPAT(t *testing.T) {
	store := testStore(t)
	if err := store.Record(sessionUser, sessionPAT); err != nil {
		t.Fatalf("Record: %v", err)
	}
	srv, cap := newSessionServer(t, store)
	token, err := srv.signer.SignWithPAT(sessionUser, sessionPAT)
	if err != nil {
		t.Fatalf("SignWithPAT: %v", err)
	}

	denied := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
	}))
	defer denied.Close()
	store.revalidate(context.Background(), newTestValidator(t, denied.URL))
	if store.Lookup(sessionUser, PATHash(sessionPAT)) {
		t.Fatal("revalidation did not drop the revoked PAT")
	}

	if rec := sessionRequest(t, srv, "/api/keepalive", ndAuthHeader, "Bearer "+token); rec.Code != http.StatusUnauthorized {
		t.Fatalf("/api status = %d, want 401 (body %q)", rec.Code, rec.Body.String())
	}
	if got := atomic.LoadInt32(&cap.hits); got != 0 {
		t.Fatalf("/api proxied a revoked token (%d upstream hits)", got)
	}

	restPath := "/rest/ping.view?u=" + sessionUser + "&t=" + token + "&s=abcdef&f=json"
	rec := sessionRequest(t, srv, restPath, "", "")
	if rec.Code != http.StatusOK {
		t.Fatalf("/rest status = %d, want 200", rec.Code)
	}
	if got := subsonicErrorCode(t, rec.Body.Bytes()); got != subsonicErrorTokenUnsupported {
		t.Fatalf("/rest code = %d, want %d", got, subsonicErrorTokenUnsupported)
	}
	if got := atomic.LoadInt32(&cap.hits); got != 0 {
		t.Fatalf("/rest proxied a revoked token (%d upstream hits)", got)
	}
}

// TestExpiredTokenRefreshesBoundPAT proves the token's `exp` is a refresh hint,
// not the session bound: an expired `ph` token whose PAT is still stored is
// accepted and a fresh token is returned in the response header.
func TestExpiredTokenRefreshesBoundPAT(t *testing.T) {
	store := testStore(t)
	if err := store.Record(sessionUser, sessionPAT); err != nil {
		t.Fatalf("Record: %v", err)
	}
	srv, cap := newSessionServer(t, store)
	old := mintExpiredPATToken(t, srv)

	rec := sessionRequest(t, srv, "/api/keepalive", ndAuthHeader, "Bearer "+old)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 (body %q)", rec.Code, rec.Body.String())
	}
	if atomic.LoadInt32(&cap.hits) != 1 {
		t.Fatalf("upstream hits = %d, want 1", cap.hits)
	}
	if cap.identityHeader != sessionUser {
		t.Fatalf("upstream identity = %q, want %q", cap.identityHeader, sessionUser)
	}

	header := rec.Header().Get(ndAuthHeader)
	if !strings.HasPrefix(header, "Bearer ") {
		t.Fatalf("refreshed header = %q, want a Bearer token", header)
	}
	fresh := strings.TrimPrefix(header, "Bearer ")
	if fresh == old {
		t.Fatal("refreshed token equals the expired one")
	}
	claims, expired, err := srv.signer.VerifyClaims(fresh, sessionUser)
	if err != nil {
		t.Fatalf("fresh token does not verify: %v", err)
	}
	if expired {
		t.Fatal("fresh token is already expired")
	}
	if claims.Ph != PATHash(sessionPAT) {
		t.Fatalf("fresh token ph = %q, want %q", claims.Ph, PATHash(sessionPAT))
	}
}

// TestRefreshedTokenKeepsPh exercises the refresh through the Subsonic `t`
// transport and pins that the new token still carries the PAT binding, without
// carrying the PAT itself.
func TestRefreshedTokenKeepsPh(t *testing.T) {
	store := testStore(t)
	if err := store.Record(sessionUser, sessionPAT); err != nil {
		t.Fatalf("Record: %v", err)
	}
	srv, _ := newSessionServer(t, store)
	old := mintExpiredPATToken(t, srv)

	path := "/rest/ping.view?u=" + sessionUser + "&t=" + old + "&s=abcdef&f=json"
	rec := sessionRequest(t, srv, path, "", "")
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 (body %q)", rec.Code, rec.Body.String())
	}
	header := rec.Header().Get(ndAuthHeader)
	if !strings.HasPrefix(header, "Bearer ") {
		t.Fatalf("refreshed header = %q, want a Bearer token", header)
	}
	fresh := strings.TrimPrefix(header, "Bearer ")
	claims := decodeTokenClaims(t, fresh)
	if claims.Sub != sessionUser || claims.Ph != PATHash(sessionPAT) {
		t.Fatalf("refreshed claims = sub %q ph %q, want sub %q ph %q", claims.Sub, claims.Ph, sessionUser, PATHash(sessionPAT))
	}
	if strings.Contains(fresh, sessionPAT) {
		t.Fatal("refreshed token contains the plaintext PAT")
	}
}

// TestOldTokenStillAccepted proves the refresh is additive: the expired token
// that triggered it remains accepted because acceptance is the per-request
// store check, not the token's expiry.
func TestOldTokenStillAccepted(t *testing.T) {
	store := testStore(t)
	if err := store.Record(sessionUser, sessionPAT); err != nil {
		t.Fatalf("Record: %v", err)
	}
	srv, cap := newSessionServer(t, store)
	old := mintExpiredPATToken(t, srv)

	rec := sessionRequest(t, srv, "/api/keepalive", ndAuthHeader, "Bearer "+old)
	if rec.Code != http.StatusOK {
		t.Fatalf("first request status = %d, want 200 (body %q)", rec.Code, rec.Body.String())
	}
	fresh := strings.TrimPrefix(rec.Header().Get(ndAuthHeader), "Bearer ")
	if fresh == "" || fresh == old {
		t.Fatalf("first request did not mint a refresh (%q)", fresh)
	}

	for name, token := range map[string]string{"old": old, "fresh": fresh} {
		if rec := sessionRequest(t, srv, "/api/keepalive", ndAuthHeader, "Bearer "+token); rec.Code != http.StatusOK {
			t.Fatalf("%s token status = %d, want 200 (body %q)", name, rec.Code, rec.Body.String())
		}
	}
	if got := atomic.LoadInt32(&cap.hits); got != 3 {
		t.Fatalf("upstream hits = %d, want 3", got)
	}
}

// TestRestExpiredTokenRepeats covers two consecutive expired-`t` requests: each
// is accepted by the store, not just the request that observed the expiry.
func TestRestExpiredTokenRepeats(t *testing.T) {
	store := testStore(t)
	if err := store.Record(sessionUser, sessionPAT); err != nil {
		t.Fatalf("Record: %v", err)
	}
	srv, cap := newSessionServer(t, store)
	old := mintExpiredPATToken(t, srv)
	path := "/rest/ping.view?u=" + sessionUser + "&t=" + old + "&s=abcdef&f=json"

	for i := 1; i <= 2; i++ {
		rec := sessionRequest(t, srv, path, "", "")
		if rec.Code != http.StatusOK {
			t.Fatalf("request %d status = %d, want 200 (body %q)", i, rec.Code, rec.Body.String())
		}
		if got := atomic.LoadInt32(&cap.hits); got != int32(i) {
			t.Fatalf("request %d upstream hits = %d, want %d", i, got, i)
		}
	}
}

// TestTransientDoesNotDeny pins the failure classification: a Keycloak outage
// is not a credential denial. The native `/api` path answers 503 with a retry
// hint, `/rest` answers 200 with Subsonic code 0, login answers 503 JSON, and
// the credential still works once Keycloak recovers.
func TestTransientDoesNotDeny(t *testing.T) {
	var unavailable atomic.Bool
	unavailable.Store(true)
	var kcCalls int32
	kc := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&kcCalls, 1)
		if unavailable.Load() {
			w.WriteHeader(http.StatusServiceUnavailable)
			return
		}
		u, p, ok := r.BasicAuth()
		if !ok || u != sessionUser || p != sessionPAT {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		w.Header().Set("X-User", u)
		w.WriteHeader(http.StatusOK)
	}))
	defer kc.Close()
	cap := &upstreamCapture{}
	up := fakeUpstream(t, cap)
	defer up.Close()
	srv := newTestServerWithStore(t, kc.URL, up.URL, time.Hour, testStore(t))

	t.Run("api 503", func(t *testing.T) {
		req := httptest.NewRequest(http.MethodGet, "/api/keepalive", nil)
		req.Header.Set("Authorization", basic(sessionUser, sessionPAT))
		rec := httptest.NewRecorder()
		srv.Handler().ServeHTTP(rec, req)

		if rec.Code != http.StatusServiceUnavailable {
			t.Fatalf("status = %d, want 503 (body %q)", rec.Code, rec.Body.String())
		}
		if got := rec.Header().Get("Retry-After"); got == "" {
			t.Fatal("503 lacks Retry-After")
		}
		if got := atomic.LoadInt32(&cap.hits); got != 0 {
			t.Fatalf("upstream hit on a transient failure (%d)", got)
		}
	})

	t.Run("rest 200 code 0", func(t *testing.T) {
		req := httptest.NewRequest(http.MethodGet, "/rest/ping.view?f=json", nil)
		req.Header.Set("Authorization", basic(sessionUser, sessionPAT))
		rec := httptest.NewRecorder()
		srv.Handler().ServeHTTP(rec, req)

		if rec.Code != http.StatusOK {
			t.Fatalf("status = %d, want 200 (body %q)", rec.Code, rec.Body.String())
		}
		var resp struct {
			Subsonic struct {
				Status  string `json:"status"`
				Message string `json:"message"`
				Error   *struct {
					Code int `json:"code"`
				} `json:"error"`
			} `json:"subsonic-response"`
		}
		if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
			t.Fatalf("body is not json: %v (%q)", err, rec.Body.String())
		}
		if resp.Subsonic.Status != "ok" {
			t.Fatalf("status = %q, want ok (body %q)", resp.Subsonic.Status, rec.Body.String())
		}
		if resp.Subsonic.Error != nil && resp.Subsonic.Error.Code != 0 {
			t.Fatalf("subsonic error code = %d, want 0", resp.Subsonic.Error.Code)
		}
		if !strings.Contains(resp.Subsonic.Message, "temporarily unavailable") {
			t.Fatalf("body lacks the retry message: %q", rec.Body.String())
		}
		if got := atomic.LoadInt32(&cap.hits); got != 0 {
			t.Fatalf("upstream hit on a transient failure (%d)", got)
		}
	})

	t.Run("login 503", func(t *testing.T) {
		rec := postLogin(t, srv, sessionUser, sessionPAT)
		if rec.Code != http.StatusServiceUnavailable {
			t.Fatalf("status = %d, want 503 (body %q)", rec.Code, rec.Body.String())
		}
		if ct := rec.Header().Get("Content-Type"); !strings.Contains(ct, "application/json") {
			t.Fatalf("content-type = %q, want json", ct)
		}
		if !strings.Contains(rec.Body.String(), "temporarily unavailable") {
			t.Fatalf("body lacks the retry message: %q", rec.Body.String())
		}
	})

	unavailable.Store(false)
	req := httptest.NewRequest(http.MethodGet, "/api/keepalive", nil)
	req.Header.Set("Authorization", basic(sessionUser, sessionPAT))
	rec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("after recovery status = %d, want 200 (body %q)", rec.Code, rec.Body.String())
	}
}

// TestExpiredTokenWithoutPhDenied pins backward compatibility: a token minted
// before the `ph` claim keeps the strict expiry behaviour.
func TestExpiredTokenWithoutPhDenied(t *testing.T) {
	store := testStore(t)
	srv, cap := newSessionServer(t, store)

	base := time.Unix(1_700_000_000, 0)
	srv.signer.now = func() time.Time { return base }
	token, err := srv.signer.Sign(sessionUser)
	if err != nil {
		t.Fatalf("Sign: %v", err)
	}
	srv.signer.now = func() time.Time { return base.Add(time.Hour) }

	if rec := sessionRequest(t, srv, "/api/keepalive", ndAuthHeader, "Bearer "+token); rec.Code != http.StatusUnauthorized {
		t.Fatalf("/api status = %d, want 401 (body %q)", rec.Code, rec.Body.String())
	}
	restPath := "/rest/ping.view?u=" + sessionUser + "&t=" + token + "&s=abcdef&f=json"
	rec := sessionRequest(t, srv, restPath, "", "")
	if rec.Code != http.StatusOK {
		t.Fatalf("/rest status = %d, want 200", rec.Code)
	}
	if got := subsonicErrorCode(t, rec.Body.Bytes()); got != subsonicErrorTokenUnsupported {
		t.Fatalf("/rest code = %d, want %d", got, subsonicErrorTokenUnsupported)
	}
	if got := atomic.LoadInt32(&cap.hits); got != 0 {
		t.Fatalf("upstream accepted an expired no-ph token (%d hits)", got)
	}
}
