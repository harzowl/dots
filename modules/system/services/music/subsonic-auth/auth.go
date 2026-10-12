package main

import (
	"encoding/base64"
	"encoding/hex"
	"net/http"
	"strings"
	"sync"
	"time"
)

// credStatus is the outcome of inspecting a request's credentials.
type credStatus int

const (
	credOK credStatus = iota
	credNone
	credUnsupportedToken // Subsonic t=+s= (md5): one-way, cannot be validated
)

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

// extractCredential reads the credentials in order: HTTP Basic first, then the
// Subsonic `u`/`p` query parameters (`p` may be plaintext or `enc:<hex>`). A
// `t`/`s` (md5) pair on its own is unsupported — the hash is one-way, so it
// cannot be validated against a Keycloak PAT.
func extractCredential(r *http.Request) (user, token string, st credStatus) {
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
	q := r.URL.Query()
	if u, p := q.Get("u"), q.Get("p"); u != "" && p != "" {
		if enc, ok := strings.CutPrefix(p, "enc:"); ok {
			b, err := hex.DecodeString(enc)
			if err != nil {
				return "", "", credNone
			}
			return u, string(b), credOK
		}
		return u, p, credOK
	}
	if q.Get("t") != "" && q.Get("s") != "" {
		return "", "", credUnsupportedToken
	}
	return "", "", credNone
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
