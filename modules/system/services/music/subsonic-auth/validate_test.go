package main

import (
	"context"
	"errors"
	"net"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

// assertErrorClass fails unless err matches want via errors.Is. A nil want
// asserts success.
func assertErrorClass(t *testing.T, err, want error) {
	t.Helper()
	if want == nil {
		if err != nil {
			t.Fatalf("validate: unexpected error %v", err)
		}
		return
	}
	if err == nil {
		t.Fatalf("validate accepted the request, want %v", want)
	}
	if !errors.Is(err, want) {
		t.Fatalf("error class = %v, want errors.Is(err, %v)", err, want)
	}
}

// TestValidatorDenialsAreDenied pins the denial cases that must not change:
// 401, 403, and a 200 without X-User.
func TestValidatorDenialsAreDenied(t *testing.T) {
	tests := []struct {
		name   string
		status int
	}{
		{name: "401", status: http.StatusUnauthorized},
		{name: "403", status: http.StatusForbidden},
		{name: "200 without X-User", status: http.StatusOK},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.WriteHeader(tt.status)
			}))
			defer srv.Close()

			v, err := newValidator(srv.URL, "dummy-DO-NOT-USE-realm", "", &http.Client{Timeout: time.Second})
			if err != nil {
				t.Fatal(err)
			}
			_, err = v.validate(context.Background(), "dummy-DO-NOT-USE@example.invalid", "dummy-DO-NOT-USE-pat")
			assertErrorClass(t, err, errDenied)
		})
	}
}

func statusServer(status int, identity string) func(*testing.T) (string, *http.Client) {
	return func(t *testing.T) (string, *http.Client) {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if identity != "" {
				w.Header().Set("X-User", identity)
			}
			w.WriteHeader(status)
		}))
		t.Cleanup(srv.Close)
		return srv.URL, &http.Client{
			Timeout:       time.Second,
			CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
		}
	}
}

func TestValidatorErrorClasses(t *testing.T) {
	const identity = "dummy-DO-NOT-USE@example.invalid"
	tests := []struct {
		name    string
		setup   func(*testing.T) (string, *http.Client)
		wantErr error
		wantID  string
	}{
		{name: "200 with X-User", setup: statusServer(http.StatusOK, identity), wantID: identity},
		{name: "200 without X-User", setup: statusServer(http.StatusOK, ""), wantErr: errDenied},
		{name: "401", setup: statusServer(http.StatusUnauthorized, ""), wantErr: errDenied},
		{name: "403", setup: statusServer(http.StatusForbidden, ""), wantErr: errDenied},
		{name: "400", setup: statusServer(http.StatusBadRequest, ""), wantErr: errDenied},
		{name: "404", setup: statusServer(http.StatusNotFound, ""), wantErr: errDenied},
		{name: "302", setup: statusServer(http.StatusFound, ""), wantErr: errDenied},
		{name: "429", setup: statusServer(http.StatusTooManyRequests, ""), wantErr: errTransient},
		{name: "500", setup: statusServer(http.StatusInternalServerError, ""), wantErr: errTransient},
		{name: "503", setup: statusServer(http.StatusServiceUnavailable, ""), wantErr: errTransient},
		{
			name: "timeout",
			setup: func(t *testing.T) (string, *http.Client) {
				srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
					<-r.Context().Done()
				}))
				t.Cleanup(srv.Close)
				return srv.URL, &http.Client{Timeout: 50 * time.Millisecond}
			},
			wantErr: errTransient,
		},
		{
			name: "connection refused",
			setup: func(t *testing.T) (string, *http.Client) {
				l, err := net.Listen("tcp", "127.0.0.1:0")
				if err != nil {
					t.Fatal(err)
				}
				addr := l.Addr().String()
				if err := l.Close(); err != nil {
					t.Fatal(err)
				}
				return "http://" + addr, &http.Client{Timeout: time.Second}
			},
			wantErr: errTransient,
		},
		{
			name: "DNS failure",
			setup: func(t *testing.T) (string, *http.Client) {
				client := &http.Client{Transport: roundTripFunc(func(*http.Request) (*http.Response, error) {
					return nil, &net.DNSError{Err: "no such host", Name: "dummy-DO-NOT-USE.invalid", IsNotFound: true}
				})}
				return "http://dummy-DO-NOT-USE.invalid", client
			},
			wantErr: errTransient,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			endpoint, client := tt.setup(t)
			v, err := newValidator(endpoint, "dummy-DO-NOT-USE-realm", "", client)
			if err != nil {
				t.Fatal(err)
			}
			id, err := v.validate(context.Background(), identity, "dummy-DO-NOT-USE-pat")
			assertErrorClass(t, err, tt.wantErr)
			if tt.wantErr == nil && id != tt.wantID {
				t.Fatalf("identity = %q, want %q", id, tt.wantID)
			}
		})
	}
}
