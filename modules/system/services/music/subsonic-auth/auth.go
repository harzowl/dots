package main

import (
	"encoding/base64"
	"encoding/hex"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
)

// credStatus is the outcome of inspecting a request's password credentials.
type credStatus int

const (
	credOK credStatus = iota
	credNone
)

// ndAuthHeader carries the signed token Feishin's "Navidrome" server type
// stores after a successful /auth/login and replays on /api/*.
const ndAuthHeader = "X-Nd-Authorization"

// identityHeaders are the headers a client might use to impersonate the
// authenticated user. They are always stripped before the request is proxied,
// so only this shim's own header can reach Navidrome.
var identityHeaders = []string{
	"X-Auth-Request-Preferred-Username",
	"X-Auth-Request-User",
	"X-Auth-Request-Email",
	"X-Auth-Request-Access-Token",
	"X-Forwarded-User",
	"X-Forwarded-Email",
	"X-Forwarded-Preferred-Username",
	"Remote-User",
	"Remote-Email",
	"Remote-Groups",
}

// param returns the first non-empty value for key from the urlencoded POST body
// (the OpenSubsonic `formPost` transport Feishin's "Navidrome" server type
// uses) or, failing that, the query string. Both must be consulted: a native
// client may send a credential either way.
func param(r *http.Request, form url.Values, key string) string {
	if form != nil {
		if v := form.Get(key); v != "" {
			return v
		}
	}
	return r.URL.Query().Get(key)
}

// extractCredential reads the password credentials in order: HTTP Basic first,
// then the Subsonic `u`/`p` parameters (`p` may be plaintext or `enc:<hex>`),
// from the POST body or the query. A `t`/`s` pair is not read here; it is
// resolved as a session token by the server.
func extractCredential(r *http.Request, form url.Values) (user, token string, st credStatus) {
	if auth := r.Header.Get("Authorization"); auth != "" {
		const prefix = "basic "
		if len(auth) >= len(prefix) && strings.EqualFold(auth[:len(prefix)], prefix) {
			raw, err := base64.StdEncoding.DecodeString(strings.TrimSpace(auth[len(prefix):]))
			if err != nil {
				return "", "", credNone
			}
			u, p, ok := strings.Cut(string(raw), ":")
			if !ok || u == "" {
				return "", "", credNone
			}
			return u, p, credOK
		}
	}
	u, p := param(r, form, "u"), param(r, form, "p")
	if u != "" && p != "" {
		if enc, ok := strings.CutPrefix(p, "enc:"); ok {
			b, err := hex.DecodeString(enc)
			if err != nil {
				return "", "", credNone
			}
			return u, string(b), credOK
		}
		return u, p, credOK
	}
	return "", "", credNone
}

// bearerToken extracts the token from an `X-Nd-Authorization: Bearer <token>`
// header (the native `/api/*` client's session token). Empty if not a bearer.
func bearerToken(v string) string {
	const prefix = "bearer "
	if len(v) >= len(prefix) && strings.EqualFold(v[:len(prefix)], prefix) {
		return strings.TrimSpace(v[len(prefix):])
	}
	return ""
}

func scrubIdentityHeaders(h http.Header) {
	for _, k := range identityHeaders {
		h.Del(k)
	}
}

// credCache is a bounded, TTL'd cache of positive validations, keyed by the
// sha256 of `user\x00token`. The plaintext is never stored or logged.
type credCache struct {
	mu  sync.Mutex
	m   map[[32]byte]cacheEntry
	ttl time.Duration
	max int
}

type cacheEntry struct {
	user    string
	expires time.Time
}

func newCredCache(ttl time.Duration, max int) *credCache {
	if max < 1 {
		max = 1
	}
	return &credCache{m: make(map[[32]byte]cacheEntry), ttl: ttl, max: max}
}

func (c *credCache) get(key [32]byte) (string, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	e, ok := c.m[key]
	if !ok {
		return "", false
	}
	if time.Now().After(e.expires) {
		delete(c.m, key)
		return "", false
	}
	return e.user, true
}

func (c *credCache) set(key [32]byte, user string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if len(c.m) >= c.max {
		c.pruneLocked()
	}
	c.m[key] = cacheEntry{user: user, expires: time.Now().Add(c.ttl)}
}

func (c *credCache) pruneLocked() {
	now := time.Now()
	for k, e := range c.m {
		if now.After(e.expires) {
			delete(c.m, k)
		}
	}
	if len(c.m) >= c.max {
		// Still full: drop everything rather than grow without bound.
		c.m = make(map[[32]byte]cacheEntry)
	}
}
