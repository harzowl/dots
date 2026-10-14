package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// TestRestRejectionIsHTTP200 pins the Subsonic contract: an error is carried in
// the envelope with HTTP 200, in the format the client asked for (XML default).
// A client that gates on the HTTP status — Subtracks throws on any non-2xx
// before reading the body — must still be able to read the code, and code 41
// (token auth unsupported) is what makes it retry with a plaintext password.
func TestRestRejectionIsHTTP200(t *testing.T) {
	tests := []struct {
		name       string
		path       string
		wantFormat string
		wantCode   int
	}{
		{
			name:       "md5 t defaults to xml",
			path:       "/rest/ping.view?u=dummy-DO-NOT-USE%40example.invalid&t=abcd&s=efgh&v=1.16.1&c=test",
			wantFormat: "xml",
			wantCode:   subsonicErrorTokenUnsupported,
		},
		{
			name:       "raw pat in t is token-unsupported",
			path:       "/rest/ping.view?u=dummy-DO-NOT-USE%40example.invalid&t=pat-123&s=abcdef&f=json",
			wantFormat: "json",
			wantCode:   subsonicErrorTokenUnsupported,
		},
		{
			name:       "wrong pat defaults to xml",
			path:       "/rest/ping.view?u=dummy-DO-NOT-USE%40example.invalid&p=wrong-pat",
			wantFormat: "xml",
			wantCode:   subsonicErrorWrongCredentials,
		},
		{
			name:       "no credentials",
			path:       "/rest/ping.view?v=1.16.1&c=test",
			wantFormat: "xml",
			wantCode:   subsonicErrorWrongCredentials,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			kc := fakeKeycloak(t, "dummy-DO-NOT-USE@example.invalid", "pat-123", new(int32))
			defer kc.Close()
			up := fakeUpstream(t, &upstreamCapture{})
			defer up.Close()

			srv := newTestServer(t, kc.URL, up.URL, time.Minute)
			rec := httptest.NewRecorder()
			srv.Handler().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, tt.path, nil))

			if rec.Code != http.StatusOK {
				t.Fatalf("status = %d, want 200 (body %q)", rec.Code, rec.Body.String())
			}
			if ct := rec.Header().Get("Content-Type"); !strings.Contains(ct, tt.wantFormat) {
				t.Fatalf("content-type = %q, want %s", ct, tt.wantFormat)
			}
			if got := subsonicErrorCode(t, rec.Body.Bytes()); got != tt.wantCode {
				t.Fatalf("subsonic error code = %d, want %d (%q)", got, tt.wantCode, rec.Body.String())
			}
			if tt.wantFormat == "xml" && !strings.Contains(rec.Body.String(), "<subsonic-response") {
				t.Fatalf("xml body lacks the subsonic-response root: %q", rec.Body.String())
			}
		})
	}
}

// TestRestJsonpErrorWrapsCallback covers the third Subsonic response format: the
// envelope is wrapped in the caller's callback.
func TestRestJsonpErrorWrapsCallback(t *testing.T) {
	kc := fakeKeycloak(t, "dummy-DO-NOT-USE@example.invalid", "pat-123", new(int32))
	defer kc.Close()
	up := fakeUpstream(t, &upstreamCapture{})
	defer up.Close()

	srv := newTestServer(t, kc.URL, up.URL, time.Minute)
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/rest/ping.view?u=dummy-DO-NOT-USE%40example.invalid&t=abcd&s=efgh&f=jsonp&callback=cb", nil)
	srv.Handler().ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	if !strings.HasPrefix(rec.Body.String(), "cb(") || !strings.HasSuffix(rec.Body.String(), ")") {
		t.Fatalf("jsonp body not wrapped in the callback: %q", rec.Body.String())
	}
	inner := strings.TrimSuffix(strings.TrimPrefix(rec.Body.String(), "cb("), ")")
	if got := subsonicErrorCode(t, []byte(inner)); got != subsonicErrorTokenUnsupported {
		t.Fatalf("jsonp error code = %d, want %d", got, subsonicErrorTokenUnsupported)
	}
}

// TestNonSubsonicPathsStill401 guards the transport status on the paths that are
// not the Subsonic API: a failed native `/api` bearer is a real 401, not a 200
// envelope.
func TestNonSubsonicPathsStill401(t *testing.T) {
	kc := fakeKeycloak(t, "dummy-DO-NOT-USE@example.invalid", "pat-123", new(int32))
	defer kc.Close()
	up := fakeUpstream(t, &upstreamCapture{})
	defer up.Close()

	srv := newTestServer(t, kc.URL, up.URL, time.Minute)
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/api/keepalive", nil)
	req.Header.Set(ndAuthHeader, "Bearer not-a-token")
	srv.Handler().ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want 401", rec.Code)
	}
}
