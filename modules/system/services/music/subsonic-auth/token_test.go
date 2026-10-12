package main

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"strings"
	"testing"
	"time"
)

func testSigner(t *testing.T, ttl time.Duration) *tokenSigner {
	t.Helper()
	s, err := newTokenSigner("1", map[string][]byte{"1": bytes.Repeat([]byte("k"), 32)}, ttl, tokenAudience)
	if err != nil {
		t.Fatalf("newTokenSigner: %v", err)
	}
	return s
}

func TestSignedTokenRoundTrip(t *testing.T) {
	s := testSigner(t, time.Hour)
	tok, err := s.Sign("dummy-DO-NOT-USE@example.invalid")
	if err != nil {
		t.Fatalf("Sign: %v", err)
	}
	got, err := s.Verify(tok, "dummy-DO-NOT-USE@example.invalid")
	if err != nil {
		t.Fatalf("Verify: %v", err)
	}
	if got != "dummy-DO-NOT-USE@example.invalid" {
		t.Fatalf("identity = %q, want dummy-DO-NOT-USE@example.invalid", got)
	}
	// An empty `u` still verifies (the /api client sends no username).
	if _, err := s.Verify(tok, ""); err != nil {
		t.Fatalf("Verify with empty user: %v", err)
	}
}

func TestSignedTokenIsNotTheCredential(t *testing.T) {
	s := testSigner(t, time.Hour)
	pat := "dummy-DO-NOT-USE-0000000000000000000000"
	tok, err := s.Sign("dummy-DO-NOT-USE@example.invalid")
	if err != nil {
		t.Fatalf("Sign: %v", err)
	}
	if tok == pat || strings.Contains(tok, pat) {
		t.Fatalf("signed token %q contains the credential", tok)
	}
	// The payload must not carry the PAT either.
	parts := strings.Split(tok, ".")
	raw, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil {
		t.Fatalf("payload is not base64url: %v", err)
	}
	if strings.Contains(string(raw), pat) {
		t.Fatalf("payload %q contains the credential", raw)
	}
	var claims tokenClaims
	if err := json.Unmarshal(raw, &claims); err != nil {
		t.Fatalf("payload is not json: %v", err)
	}
	if claims.Sub != "dummy-DO-NOT-USE@example.invalid" || claims.Aud != tokenAudience {
		t.Fatalf("claims = %+v, want sub+aud", claims)
	}
	if claims.Exp <= claims.Iat || claims.Iat == 0 {
		t.Fatalf("claims times are not sane: iat=%d exp=%d", claims.Iat, claims.Exp)
	}
}

func TestSignedTokenTamperRejected(t *testing.T) {
	s := testSigner(t, time.Hour)
	tok, _ := s.Sign("dummy-DO-NOT-USE@example.invalid")
	parts := strings.Split(tok, ".")
	// Flip the last character of the payload; the signature must no longer match.
	flip := func(seg string) string {
		if seg[len(seg)-1] == 'A' {
			return seg[:len(seg)-1] + "B"
		}
		return seg[:len(seg)-1] + "A"
	}
	tests := map[string]string{
		"payload":   parts[0] + "." + parts[1] + "." + flip(parts[2]) + "." + parts[3],
		"signature": parts[0] + "." + parts[1] + "." + parts[2] + "." + flip(parts[3]),
		"kid":       parts[0] + "." + "9" + "." + parts[2] + "." + parts[3],
	}
	for name, bad := range tests {
		t.Run(name, func(t *testing.T) {
			if _, err := s.Verify(bad, "dummy-DO-NOT-USE@example.invalid"); err == nil {
				t.Fatalf("tampered token (%s) verified", name)
			}
		})
	}
	// Short/long/malformed inputs must be rejected, not panic.
	for _, bad := range []string{"", "x", "v1.a.b", "v1.a.b.c.d", "v2.1.xx.yy"} {
		if _, err := s.Verify(bad, "dummy-DO-NOT-USE@example.invalid"); err == nil {
			t.Fatalf("malformed token %q verified", bad)
		}
	}
}

func TestSignedTokenExpiredRejected(t *testing.T) {
	s := testSigner(t, time.Minute)
	base := time.Unix(1700000000, 0)
	s.now = func() time.Time { return base }
	tok, _ := s.Sign("dummy-DO-NOT-USE@example.invalid")

	s.now = func() time.Time { return base.Add(59 * time.Second) }
	if _, err := s.Verify(tok, "dummy-DO-NOT-USE@example.invalid"); err != nil {
		t.Fatalf("token rejected before expiry: %v", err)
	}
	s.now = func() time.Time { return base.Add(time.Minute) }
	if _, err := s.Verify(tok, "dummy-DO-NOT-USE@example.invalid"); err == nil {
		t.Fatal("expired token verified")
	}
}

func TestSignedTokenWrongAudienceRejected(t *testing.T) {
	s := testSigner(t, time.Hour)
	tok, _ := s.Sign("dummy-DO-NOT-USE@example.invalid")

	other, err := newTokenSigner("1", map[string][]byte{"1": bytes.Repeat([]byte("k"), 32)}, time.Hour, "something-else")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := other.Verify(tok, "dummy-DO-NOT-USE@example.invalid"); err == nil {
		t.Fatal("token with the wrong audience verified")
	}
}

func TestSignedTokenSubMismatchRejected(t *testing.T) {
	s := testSigner(t, time.Hour)
	tok, _ := s.Sign("dummy-DO-NOT-USE@example.invalid")
	if _, err := s.Verify(tok, "dummy-DO-NOT-USE-other@example.invalid"); err == nil {
		t.Fatal("token verified for a different u")
	}
}

func TestSignedTokenFutureIatRejected(t *testing.T) {
	s := testSigner(t, time.Hour)
	base := time.Unix(1700000000, 0)
	s.now = func() time.Time { return base }
	tok, _ := s.Sign("dummy-DO-NOT-USE@example.invalid")
	s.now = func() time.Time { return base.Add(-10 * time.Minute) }
	if _, err := s.Verify(tok, "dummy-DO-NOT-USE@example.invalid"); err == nil {
		t.Fatal("token with a far-future iat verified")
	}
}

func TestUnknownKidRejected(t *testing.T) {
	s := testSigner(t, time.Hour)
	tok, _ := s.Sign("dummy-DO-NOT-USE@example.invalid")
	// A second signer that does not know kid "1".
	other, err := newTokenSigner("2", map[string][]byte{"2": bytes.Repeat([]byte("z"), 32)}, time.Hour, tokenAudience)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := other.Verify(tok, "dummy-DO-NOT-USE@example.invalid"); err == nil {
		t.Fatal("token signed with an unknown kid verified")
	}
}

func TestSignedTokenKeyRotation(t *testing.T) {
	old, err := newTokenSigner("1", map[string][]byte{"1": bytes.Repeat([]byte("o"), 32)}, time.Hour, tokenAudience)
	if err != nil {
		t.Fatal(err)
	}
	tok, _ := old.Sign("dummy-DO-NOT-USE@example.invalid")

	// The rotated signer signs with the new kid but still holds the old key for
	// verification: new tokens use the new kid, old tokens keep verifying.
	rotated, err := newTokenSigner("2", map[string][]byte{
		"2": bytes.Repeat([]byte("n"), 32),
		"1": bytes.Repeat([]byte("o"), 32),
	}, time.Hour, tokenAudience)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := rotated.Verify(tok, "dummy-DO-NOT-USE@example.invalid"); err != nil {
		t.Fatalf("old token rejected after rotation: %v", err)
	}
	fresh, _ := rotated.Sign("dummy-DO-NOT-USE@example.invalid")
	if !strings.HasPrefix(fresh, "v1.2.") {
		t.Fatalf("fresh token = %q, want the new kid", fresh)
	}
	if _, err := rotated.Verify(fresh, "dummy-DO-NOT-USE@example.invalid"); err != nil {
		t.Fatalf("fresh token rejected: %v", err)
	}
}

func TestNewTokenSignerRejectsBadConfig(t *testing.T) {
	tests := []struct {
		name      string
		kid       string
		keys      map[string][]byte
		ttl       time.Duration
		wantError bool
	}{
		{"short key", "1", map[string][]byte{"1": []byte("short")}, time.Hour, true},
		{"missing active kid", "2", map[string][]byte{"1": bytes.Repeat([]byte("k"), 32)}, time.Hour, true},
		{"empty kid", "", map[string][]byte{"1": bytes.Repeat([]byte("k"), 32)}, time.Hour, true},
		{"zero ttl", "1", map[string][]byte{"1": bytes.Repeat([]byte("k"), 32)}, 0, true},
		{"ok", "1", map[string][]byte{"1": bytes.Repeat([]byte("k"), 32)}, time.Hour, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, err := newTokenSigner(tt.kid, tt.keys, tt.ttl, tokenAudience)
			if tt.wantError && err == nil {
				t.Fatal("expected an error")
			}
			if !tt.wantError && err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
		})
	}
}

func TestParseTokenKey(t *testing.T) {
	raw := bytes.Repeat([]byte("a"), 32)
	for name, enc := range map[string]string{
		"std":     base64.StdEncoding.EncodeToString(raw),
		"raw":     base64.RawStdEncoding.EncodeToString(raw),
		"url":     base64.URLEncoding.EncodeToString(raw),
		"raw-url": base64.RawURLEncoding.EncodeToString(raw),
	} {
		t.Run(name, func(t *testing.T) {
			got, err := parseTokenKey(enc)
			if err != nil {
				t.Fatalf("parseTokenKey(%q): %v", enc, err)
			}
			if !bytes.Equal(got, raw) {
				t.Fatalf("decoded %q, want the original bytes", got)
			}
		})
	}
	if _, err := parseTokenKey("tooshort"); err == nil {
		t.Fatal("accepted a short key")
	}
}

func TestParseTokenTTL(t *testing.T) {
	tests := map[string]time.Duration{
		"24h":  24 * time.Hour,
		"7d":   7 * 24 * time.Hour,
		"30d":  30 * 24 * time.Hour,
		"90m":  90 * time.Minute,
	}
	for in, want := range tests {
		got, err := parseTokenTTL(in)
		if err != nil {
			t.Fatalf("parseTokenTTL(%q): %v", in, err)
		}
		if got != want {
			t.Fatalf("parseTokenTTL(%q) = %s, want %s", in, got, want)
		}
	}
	for _, bad := range []string{"", "0", "-1h", "7days", "0d"} {
		if _, err := parseTokenTTL(bad); err == nil {
			t.Fatalf("parseTokenTTL(%q) accepted an invalid value", bad)
		}
	}
}
