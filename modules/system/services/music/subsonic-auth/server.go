package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"log"
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

// shareImagePath is Navidrome's *public* artist/album-art endpoint:
// `/share/img/<signed-token>`. Navidrome authorises the request by the token in
// the path, so it needs no client credential — and the shim must let it through
// unauthenticated, or a native client (which edge routes to the shim) gets a 401
// and cover art never renders. Only this exact prefix is opened; the other
// `/share/*` share endpoints stay credential-required.
const shareImagePath = "/share/img"

// isPublicImagePath reports whether a request path is Navidrome's public image
// endpoint (or a child of it).
func isPublicImagePath(p string) bool {
	return p == shareImagePath || strings.HasPrefix(p, shareImagePath+"/")
}

// server authenticates a native client's credential against Keycloak and, on
// success, proxies to Navidrome with a single trusted identity header.
type server struct {
	identityHeader string
	cache          *credCache
	signer         *tokenSigner
	validator      *validator
	patStore       *patStore
	reverseProxy   *httputil.ReverseProxy
}

type serverDeps struct {
	identityHeader string
	cache          *credCache
	signer         *tokenSigner
	validator      *validator
	patStore       *patStore
	upstream       *url.URL
}

func newServer(d serverDeps) *server {
	rp := httputil.NewSingleHostReverseProxy(d.upstream)
	// Stream responses (audio, Range) without buffering.
	rp.FlushInterval = -1
	store := d.patStore
	if store == nil {
		store = newPATStore("", nil)
	}
	return &server{
		identityHeader: d.identityHeader,
		cache:          d.cache,
		signer:         d.signer,
		validator:      d.validator,
		patStore:       store,
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
		s.deny(w, r, form, subsonicErrorWrongCredentials, "malformed request body")
		return
	}

	// Navidrome's public cover-art endpoint: pass it through with no credential
	// (Navidrome authorises it by the token in the path). A native client reaches
	// this shim for every `/share*` path, so without this branch cover art 401s.
	if isPublicImagePath(r.URL.Path) {
		s.proxyAnonymous(w, r)
		return
	}

	// Explicit password credentials: HTTP Basic, or the Subsonic `u`/`p`
	// parameters (a Keycloak PAT, plaintext or `enc:<hex>`).
	if user, token, st := extractCredential(r, form); st == credOK {
		identity, ok := s.validatePAT(r.Context(), user, token)
		if !ok {
			s.deny(w, r, form, subsonicErrorWrongCredentials, "invalid or expired personal access token")
			return
		}
		s.proxy(w, r, identity, form)
		return
	}

	// `X-Nd-Authorization` carries the signed token /auth/login mints for the
	// native `/api/*` client; it is verified statelessly, so it survives a
	// restart until it expires, then the client re-logs-in with its saved PAT.
	if token := bearerToken(r.Header.Get(ndAuthHeader)); token != "" {
		identity, err := s.signer.Verify(token, "")
		if err != nil {
			s.deny(w, r, form, subsonicErrorTokenUnsupported, "invalid or expired token")
			return
		}
		s.proxy(w, r, identity, form)
		return
	}

	// The Subsonic `t` parameter is either the signed token /auth/login hands
	// back (`subsonicToken`, verified against `u` so it only authenticates the
	// identity it was minted for) or a raw client-side md5
	// (`t = md5(password + s)`). The md5 is checked against the user's recorded
	// PATs; when it matches none the shim answers 41, the code clients key on to
	// retry with the credential in plaintext `p` instead.
	if token := param(r, form, "t"); token != "" {
		user := param(r, form, "u")
		if identity, err := s.signer.Verify(token, user); err == nil {
			s.proxy(w, r, identity, form)
			return
		}
		if salt := param(r, form, "s"); salt != "" {
			if identity, ok := s.patStore.Match(user, token, salt); ok {
				s.proxy(w, r, identity, form)
				return
			}
		}
		s.deny(w, r, form, subsonicErrorTokenUnsupported, "invalid or expired token")
		return
	}

	s.deny(w, r, form, subsonicErrorWrongCredentials, "missing or malformed credentials")
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
// `subsonicToken` and `token` are both a short-lived *signed* token minted here
// after the PAT is validated — never the PAT itself, so the credential the
// client replays on `/rest` and `/api` is derived and expiry-bounded.
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

	token, err := s.signer.Sign(identity)
	if err != nil {
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	salt, err := randomHex(3)
	if err != nil {
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	s.writeJSON(w, http.StatusOK, loginResponse{
		ID:            identity,
		Name:          identity,
		Username:      identity,
		SubsonicSalt:  salt,
		SubsonicToken: token,
		Token:         token,
	})
}

// validatePAT resolves (user, PAT) to the Keycloak identity, caching positive
// validations briefly so polling and streaming do not re-hit Keycloak.
func (s *server) validatePAT(ctx context.Context, user, token string) (string, bool) {
	key := sha256.Sum256([]byte(user + "\x00" + token))
	if identity, ok := s.cache.get(key); ok {
		s.recordPAT(identity, token)
		return identity, true
	}
	identity, err := s.validator.validate(ctx, user, token)
	if err != nil {
		return "", false
	}
	s.cache.set(key, identity)
	s.recordPAT(identity, token)
	return identity, true
}

// recordPAT remembers a validated PAT so md5-only clients can later be checked
// against it. It is best-effort: a store failure must not fail the request.
func (s *server) recordPAT(identity, token string) {
	if err := s.patStore.Record(identity, token); err != nil {
		log.Printf("subsonic-auth: recording PAT: %v", err)
	}
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

// proxyAnonymous forwards a public request (Navidrome's `/share/img/<token>`
// cover art) without requiring or setting any identity: Navidrome authorises it
// by the signed token in the path. Client-supplied identity and credential
// headers are still stripped, so the public path cannot be used to spoof one.
func (s *server) proxyAnonymous(w http.ResponseWriter, r *http.Request) {
	r.Header.Del("Authorization")
	r.Header.Del(ndAuthHeader)
	scrubIdentityHeaders(r.Header)
	stripSubsonicCreds(r.URL)
	s.reverseProxy.ServeHTTP(w, r)
}

func (s *server) writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}

func (s *server) deny(w http.ResponseWriter, r *http.Request, form url.Values, code int, message string) {
	if strings.HasPrefix(r.URL.Path, "/rest") {
		s.writeSubsonicError(w, r, form, code, message)
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
