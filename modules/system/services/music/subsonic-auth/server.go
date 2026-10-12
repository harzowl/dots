package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"mime"
	"net/http"
	"net/http/httputil"
	"net/url"
	"strconv"
	"strings"
)

// Subsonic error codes: 40 = wrong username/password, 41 = token auth unsupported.
const (
	subsonicErrorWrongCredentials = 40
	subsonicErrorTokenUnsupported = 41
)

// loginPath is the endpoint Feishin's "Navidrome" server type POSTs to with a
// JSON {username,password} body. Navidrome validates the password against its
// own database, so this shim answers it instead, using the Keycloak PAT.
const loginPath = "/auth/login"

// server authenticates a native client's credential against Keycloak and, on
// success, proxies to Navidrome with a single trusted identity header.
type server struct {
	identityHeader string
	cache          *credCache
	sessions       *sessionCache
	validator      *validator
	reverseProxy   *httputil.ReverseProxy
}

type serverDeps struct {
	identityHeader string
	cache          *credCache
	sessions       *sessionCache
	validator      *validator
	upstream       *url.URL
}

func newServer(d serverDeps) *server {
	rp := httputil.NewSingleHostReverseProxy(d.upstream)
	// Stream responses (audio, Range) without buffering.
	rp.FlushInterval = -1
	return &server{
		identityHeader: d.identityHeader,
		cache:          d.cache,
		sessions:       d.sessions,
		validator:      d.validator,
		reverseProxy:   rp,
	}
}

func (s *server) Handler() http.Handler { return http.HandlerFunc(s.handle) }

func (s *server) handle(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodPost && r.URL.Path == loginPath {
		s.handleLogin(w, r)
		return
	}

	// OpenSubsonic clients that honour the `formPost` extension — Feishin's
	// "Navidrome" server type does — send the Subsonic parameters, credential
	// included, in a urlencoded body rather than the query string. Parse them
	// here so `u`/`p`/`t` are found, and hand the values to proxy() so it can
	// strip the credential from the body before it reaches Navidrome.
	form, err := readFormBody(r)
	if err != nil {
		s.deny(w, r, subsonicErrorWrongCredentials, "malformed request body")
		return
	}

	// Explicit password credentials: HTTP Basic, or the Subsonic `u`/`p`
	// parameters (a Keycloak PAT, plaintext or `enc:<hex>`).
	if user, token, st := extractCredential(r, form); st == credOK {
		identity, ok := s.validatePAT(r.Context(), user, token)
		if !ok {
			s.deny(w, r, subsonicErrorWrongCredentials, "invalid or expired personal access token")
			return
		}
		s.proxy(w, r, identity, form)
		return
	}

	// `X-Nd-Authorization` carries the opaque session token /auth/login minted
	// for the native `/api/*` client. The client re-logs-in when it expires.
	if token := bearerToken(r.Header.Get(ndAuthHeader)); token != "" {
		identity, ok := s.sessions.get(token)
		if !ok {
			s.deny(w, r, subsonicErrorTokenUnsupported, "invalid or expired session token")
			return
		}
		s.proxy(w, r, identity, form)
		return
	}

	// The Subsonic `t` parameter is the credential /auth/login hands back for
	// `/rest` — the PAT itself, not a session token, so it keeps working across
	// a shim restart. A session token is still accepted first for compatibility.
	if token := param(r, form, "t"); token != "" {
		if identity, ok := s.sessions.get(token); ok {
			s.proxy(w, r, identity, form)
			return
		}
		if user := param(r, form, "u"); user != "" {
			if identity, ok := s.validatePAT(r.Context(), user, token); ok {
				s.proxy(w, r, identity, form)
				return
			}
		}
		s.deny(w, r, subsonicErrorWrongCredentials, "invalid or expired personal access token")
		return
	}

	s.deny(w, r, subsonicErrorWrongCredentials, "missing or malformed credentials")
}

// maxFormBody bounds a urlencoded request body we will buffer. A Subsonic
// `formPost` request carries only a small parameter set, never media.
const maxFormBody = 1 << 20

// readFormBody parses an application/x-www-form-urlencoded POST body (the
// OpenSubsonic `formPost` transport) and returns its values. For any other
// request it returns nil and leaves the body for the upstream.
func readFormBody(r *http.Request) (url.Values, error) {
	if r.Method != http.MethodPost || r.Body == nil {
		return nil, nil
	}
	mt, _, err := mime.ParseMediaType(r.Header.Get("Content-Type"))
	if err != nil || mt != "application/x-www-form-urlencoded" {
		return nil, nil
	}
	raw, err := io.ReadAll(io.LimitReader(r.Body, maxFormBody))
	if err != nil {
		return nil, err
	}
	_ = r.Body.Close()
	form, err := url.ParseQuery(string(raw))
	if err != nil {
		return nil, err
	}
	r.Body = io.NopCloser(bytes.NewReader(raw))
	return form, nil
}

// loginRequest and loginResponse mirror the JSON shapes Navidrome's
// /auth/login uses, so Feishin's "Navidrome" server type parses them unchanged.
// `subsonicToken` is returned as the PAT so Feishin's `/rest` credential stays
// valid across a shim restart (sessions live only in memory); `token` is the
// opaque session for the native `/api/*` client, which re-logs-in on expiry.
type loginRequest struct {
	Username string `json:"username"`
	Password string `json:"password"`
}

type loginResponse struct {
	ID            string `json:"id"`
	Name          string `json:"name"`
	Username      string `json:"username"`
	IsAdmin       bool   `json:"isAdmin"`
	SubsonicSalt  string `json:"subsonicSalt"`
	SubsonicToken string `json:"subsonicToken"`
	Token         string `json:"token"`
}

func (s *server) handleLogin(w http.ResponseWriter, r *http.Request) {
	var req loginRequest
	err := json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&req)
	if err != nil || req.Username == "" || req.Password == "" {
		s.writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "invalid credentials"})
		return
	}
	identity, ok := s.validatePAT(r.Context(), req.Username, req.Password)
	if !ok {
		s.writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "invalid credentials"})
		return
	}

	token, err := randomHex(32)
	if err != nil {
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	salt, err := randomHex(3)
	if err != nil {
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	s.sessions.set(token, identity)
	s.writeJSON(w, http.StatusOK, loginResponse{
		ID:            identity,
		Name:          identity,
		Username:      identity,
		SubsonicSalt:  salt,
		SubsonicToken: req.Password,
		Token:         token,
	})
}

// validatePAT resolves (user, PAT) to the Keycloak identity, caching positive
// validations briefly so polling and streaming do not re-hit Keycloak.
func (s *server) validatePAT(ctx context.Context, user, token string) (string, bool) {
	key := sha256.Sum256([]byte(user + "\x00" + token))
	if identity, ok := s.cache.get(key); ok {
		return identity, true
	}
	identity, err := s.validator.validate(ctx, user, token)
	if err != nil {
		return "", false
	}
	s.cache.set(key, identity)
	return identity, true
}

// proxy strips every client-supplied identity header (and the credential) and
// sets the one identity header the upstream trusts.
func (s *server) proxy(w http.ResponseWriter, r *http.Request, identity string, form url.Values) {
	r.Header.Del("Authorization")
	r.Header.Del(ndAuthHeader)
	scrubIdentityHeaders(r.Header)
	r.Header.Set(s.identityHeader, identity)
	stripSubsonicCreds(r.URL)

	// A `formPost` credential lives in the body, so drop it there too before
	// re-encoding, keeping the token out of the upstream's logs.
	if form != nil {
		for _, k := range []string{"p", "t", "s"} {
			form.Del(k)
		}
		buf := []byte(form.Encode())
		r.Body = io.NopCloser(bytes.NewReader(buf))
		r.ContentLength = int64(len(buf))
		r.Header.Set("Content-Length", strconv.Itoa(len(buf)))
	}

	s.reverseProxy.ServeHTTP(w, r)
}

func (s *server) writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}

func (s *server) deny(w http.ResponseWriter, r *http.Request, code int, message string) {
	if strings.HasPrefix(r.URL.Path, "/rest") {
		s.writeJSON(w, http.StatusUnauthorized, map[string]any{
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

func randomHex(n int) (string, error) {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
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
