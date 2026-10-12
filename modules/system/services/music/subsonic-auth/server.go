package main

import (
	"crypto/sha256"
	"encoding/json"
	"net/http"
	"net/http/httputil"
	"net/url"
	"strings"
)

// Subsonic error codes: 40 = wrong username/password, 41 = token auth unsupported.
const (
	subsonicErrorWrongCredentials = 40
	subsonicErrorTokenUnsupported = 41
)

// server authenticates a native client's credential against Keycloak and, on
// success, proxies to Navidrome with a single trusted identity header.
type server struct {
	identityHeader string
	cache          *credCache
	validator      *validator
	reverseProxy   *httputil.ReverseProxy
}

func newServer(identityHeader string, cache *credCache, v *validator, upstream *url.URL) *server {
	rp := httputil.NewSingleHostReverseProxy(upstream)
	// Stream responses (audio, Range) without buffering.
	rp.FlushInterval = -1
	return &server{
		identityHeader: identityHeader,
		cache:          cache,
		validator:      v,
		reverseProxy:   rp,
	}
}

func (s *server) Handler() http.Handler { return http.HandlerFunc(s.handle) }

func (s *server) handle(w http.ResponseWriter, r *http.Request) {
	user, token, st := extractCredential(r)
	switch st {
	case credUnsupportedToken:
		s.deny(w, r, subsonicErrorTokenUnsupported,
			"token (t/s) authentication is not supported; use Basic auth or u/p with a Keycloak personal access token")
		return
	case credNone:
		s.deny(w, r, subsonicErrorWrongCredentials, "missing or malformed credentials")
		return
	}

	key := sha256.Sum256([]byte(user + "\x00" + token))
	identity, ok := s.cache.get(key)
	if !ok {
		var err error
		identity, err = s.validator.validate(r.Context(), user, token)
		if err != nil {
			s.deny(w, r, subsonicErrorWrongCredentials, "invalid or expired personal access token")
			return
		}
		s.cache.set(key, identity)
	}
	s.proxy(w, r, identity)
}

// proxy strips every client-supplied identity header (and the credential) and
// sets the one identity header the upstream trusts.
func (s *server) proxy(w http.ResponseWriter, r *http.Request, identity string) {
	r.Header.Del("Authorization")
	scrubIdentityHeaders(r.Header)
	r.Header.Set(s.identityHeader, identity)
	stripSubsonicCreds(r.URL)
	s.reverseProxy.ServeHTTP(w, r)
}

func (s *server) deny(w http.ResponseWriter, r *http.Request, code int, message string) {
	if strings.HasPrefix(r.URL.Path, "/rest") {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusUnauthorized)
		_ = json.NewEncoder(w).Encode(map[string]any{
			"subsonic-response": map[string]any{
				"status":  "failed",
				"version": "1.16.1",
				"error":   map[string]any{"code": code, "message": message},
			},
		})
		return
	}
	http.Error(w, message, http.StatusUnauthorized)
}

// stripSubsonicCreds removes the credential-bearing Subsonic parameters before
// the request reaches Navidrome. Under ExtAuth Navidrome identifies the user
// from the identity header, so forwarding `p`/`t`/`s` would only leak the token
// into the upstream's logs.
func stripSubsonicCreds(u *url.URL) {
	q := u.Query()
	changed := false
	for _, k := range []string{"p", "t", "s"} {
		if q.Has(k) {
			q.Del(k)
			changed = true
		}
	}
	if changed {
		u.RawQuery = q.Encode()
	}
}
