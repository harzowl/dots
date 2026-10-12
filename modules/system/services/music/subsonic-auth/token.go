package main

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"
)

// Signed subsonic tokens are stateless, short-lived credentials the shim mints
// once it has validated a Keycloak personal access token. They are what
// /auth/login hands back for both `subsonicToken` (replayed as the Subsonic `t`)
// and `token` (the native `/api` client's `X-Nd-Authorization`), so the raw PAT
// — a long-lived credential — never has to travel in a URL, in a client store,
// or through a log line.
//
// Format (all base64url, unpadded):
//
//	v1.<kid>.<base64url(payload)>.<base64url(HMAC-SHA256(key_kid, "v1.<kid>.<payload>"))>
//
// The payload carries the Keycloak identity (`sub`), an audience, issued/expiry
// times and a `jti`; the only thing naming the key is the `kid` segment, so keys
// rotate by adding a new `kid` and retiring the old one once its tokens expire.
const (
	tokenVersion  = "v1"
	tokenAudience = "subsonic"

	// tokenIatLeeway tolerates a small clock skew when rejecting a token whose
	// `iat` is in the future.
	tokenIatLeeway = 2 * time.Minute

	// minTokenKeyLen is the shortest HMAC key the signer accepts. 32 bytes is
	// the SHA-256 block-equivalent floor; the secret is 32 random bytes.
	minTokenKeyLen = 32
)

var (
	errTokenMalformed    = errors.New("malformed token")
	errTokenUnknownKey   = errors.New("unknown token key id")
	errTokenBadSignature = errors.New("bad token signature")
	errTokenExpired      = errors.New("expired token")
	errTokenAudience     = errors.New("wrong token audience")
	errTokenSubject      = errors.New("token subject mismatch")
)

// tokenClaims is the signed payload. `V`, `Kid` and `Ver` are carried for
// forward compatibility: a future format can change its meaning without a
// signature-breaking migration, and `Ver` is reserved for a per-user revocation
// epoch (unused today — the shim stays stateless; revocation is bounded by the
// TTL and by key rotation).
type tokenClaims struct {
	V   string `json:"v"`
	Kid string `json:"kid"`
	Sub string `json:"sub"`
	Aud string `json:"aud"`
	Iat int64  `json:"iat"`
	Exp int64  `json:"exp"`
	Jti string `json:"jti"`
	Ver int    `json:"ver"`
}

// tokenSigner mints and verifies the shim's signed subsonic tokens. It holds one
// active signing key plus any previous keys still accepted for verification, so
// a key can be rotated without invalidating tokens minted with the old one.
type tokenSigner struct {
	activeKid string
	keys      map[string][]byte
	ttl       time.Duration
	audience  string
	now       func() time.Time
}

func newTokenSigner(activeKid string, keys map[string][]byte, ttl time.Duration, audience string) (*tokenSigner, error) {
	if activeKid == "" {
		return nil, errors.New("token key id must not be empty")
	}
	if ttl <= 0 {
		return nil, fmt.Errorf("token ttl must be positive, got %s", ttl)
	}
	if audience == "" {
		audience = tokenAudience
	}
	ring := make(map[string][]byte, len(keys))
	for kid, key := range keys {
		if len(key) < minTokenKeyLen {
			return nil, fmt.Errorf("token key %q is %d bytes, need at least %d", kid, len(key), minTokenKeyLen)
		}
		ring[kid] = key
	}
	if _, ok := ring[activeKid]; !ok {
		return nil, fmt.Errorf("active token key %q is not in the key ring", activeKid)
	}
	return &tokenSigner{activeKid: activeKid, keys: ring, ttl: ttl, audience: audience, now: time.Now}, nil
}

// Sign mints a token for the Keycloak identity `sub`.
func (s *tokenSigner) Sign(sub string) (string, error) {
	if sub == "" {
		return "", errors.New("token subject must not be empty")
	}
	jti, err := randomHex(16)
	if err != nil {
		return "", err
	}
	now := s.now()
	claims := tokenClaims{
		V:   tokenVersion,
		Kid: s.activeKid,
		Sub: sub,
		Aud: s.audience,
		Iat: now.Unix(),
		Exp: now.Add(s.ttl).Unix(),
		Jti: jti,
	}
	payload, err := json.Marshal(claims)
	if err != nil {
		return "", err
	}
	p := base64.RawURLEncoding.EncodeToString(payload)
	signingInput := tokenVersion + "." + s.activeKid + "." + p
	return signingInput + "." + base64.RawURLEncoding.EncodeToString(s.mac(s.keys[s.activeKid], signingInput)), nil
}

// Verify checks a token's signature, audience, subject and expiry, and returns
// the identity it was minted for. When `user` is non-empty it must equal the
// token's `sub` (the Subsonic `u` parameter): a token is bound to one identity.
func (s *tokenSigner) Verify(token, user string) (string, error) {
	parts := strings.Split(token, ".")
	if len(parts) != 4 || parts[0] != tokenVersion {
		return "", errTokenMalformed
	}
	version, kid, p, sigPart := parts[0], parts[1], parts[2], parts[3]

	key, ok := s.keys[kid]
	if !ok {
		return "", errTokenUnknownKey
	}
	if !hmac.Equal(s.mac(key, version+"."+kid+"."+p), decodeSig(sigPart)) {
		return "", errTokenBadSignature
	}

	raw, err := base64.RawURLEncoding.DecodeString(p)
	if err != nil {
		return "", errTokenMalformed
	}
	var claims tokenClaims
	if err := json.Unmarshal(raw, &claims); err != nil {
		return "", errTokenMalformed
	}

	now := s.now()
	if claims.Exp <= 0 || !now.Before(time.Unix(claims.Exp, 0)) {
		return "", errTokenExpired
	}
	if claims.Iat > 0 && time.Unix(claims.Iat, 0).After(now.Add(tokenIatLeeway)) {
		return "", errTokenMalformed
	}
	if claims.Aud != s.audience {
		return "", errTokenAudience
	}
	if claims.Sub == "" {
		return "", errTokenMalformed
	}
	if user != "" && claims.Sub != user {
		return "", errTokenSubject
	}
	return claims.Sub, nil
}

func (s *tokenSigner) mac(key []byte, input string) []byte {
	m := hmac.New(sha256.New, key)
	m.Write([]byte(input))
	return m.Sum(nil)
}

// decodeSig base64url-decodes a signature segment, returning nil on error so a
// malformed signature simply fails the constant-time compare.
func decodeSig(v string) []byte {
	b, err := base64.RawURLEncoding.DecodeString(v)
	if err != nil {
		return nil
	}
	return b
}
