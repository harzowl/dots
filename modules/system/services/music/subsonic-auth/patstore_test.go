package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func testStore(t *testing.T) *patStore {
	t.Helper()
	return newPATStore(t.TempDir(), bytes.Repeat([]byte("s"), patKeyLen), 15*time.Minute)
}

func TestPATStoreEncryptionRoundTrip(t *testing.T) {
	key := bytes.Repeat([]byte("k"), patKeyLen)
	plain := []byte(`{"identity":"dummy-DO-NOT-USE@example.invalid","pats":["pat-1"]}`)

	blob, err := encryptPATSet(key, plain)
	if err != nil {
		t.Fatalf("encrypt: %v", err)
	}
	if bytes.Contains(blob, plain) {
		t.Fatal("plaintext is present in the ciphertext")
	}
	got, err := decryptPATSet(key, blob)
	if err != nil {
		t.Fatalf("decrypt: %v", err)
	}
	if !bytes.Equal(got, plain) {
		t.Fatalf("round-trip = %q, want %q", got, plain)
	}
	if _, err := decryptPATSet(bytes.Repeat([]byte("j"), patKeyLen), blob); err == nil {
		t.Fatal("decrypted with the wrong key")
	}
	// A fresh nonce: two encryptions of the same plaintext must differ.
	other, err := encryptPATSet(key, plain)
	if err != nil {
		t.Fatalf("encrypt: %v", err)
	}
	if bytes.Equal(blob, other) {
		t.Fatal("nonce reused across encryptions")
	}
	if _, err := decryptPATSet(key, blob[:4]); err == nil {
		t.Fatal("accepted a truncated ciphertext")
	}
}

func TestPATStoreRecordAndMatch(t *testing.T) {
	const (
		user = "dummy-DO-NOT-USE@example.invalid"
		pat  = "dummy-DO-NOT-USE-pat-0123456789"
		salt = "deadbeef"
	)
	store := testStore(t)
	if err := store.Record(user, pat); err != nil {
		t.Fatalf("Record: %v", err)
	}

	// A second store over the same directory and key sees the persisted PAT.
	reopened := newPATStore(store.dir, store.key, store.grace)
	identity, ok := reopened.Match(user, md5Hex(pat+salt), salt)
	if !ok || identity != user {
		t.Fatalf("Match = (%q,%v), want (%q,true)", identity, ok, user)
	}
	if _, ok := reopened.Match(user, strings.ToUpper(md5Hex(pat+salt)), salt); !ok {
		t.Fatal("case-insensitive md5 did not match")
	}

	for name, tc := range map[string]struct{ user, token, salt string }{
		"wrong md5":    {user, md5Hex("other" + salt), salt},
		"wrong salt":   {user, md5Hex(pat + salt), "other"},
		"unknown user": {"dummy-DO-NOT-USE-other@example.invalid", md5Hex(pat + salt), salt},
		"empty salt":   {user, md5Hex(pat + salt), ""},
		"empty token":  {user, "", salt},
		"empty user":   {"", md5Hex(pat + salt), salt},
	} {
		t.Run(name, func(t *testing.T) {
			if _, ok := reopened.Match(tc.user, tc.token, tc.salt); ok {
				t.Fatal("unexpected match")
			}
		})
	}
}

func TestPATStoreDeduplicates(t *testing.T) {
	const user = "dummy-DO-NOT-USE@example.invalid"
	store := testStore(t)
	for i := 0; i < 3; i++ {
		if err := store.Record(user, "pat-1"); err != nil {
			t.Fatalf("Record: %v", err)
		}
	}
	set, err := store.loadLocked(user)
	if err != nil {
		t.Fatalf("loadLocked: %v", err)
	}
	if set == nil || len(set.PATs) != 1 {
		t.Fatalf("stored %v, want a single deduplicated PAT", set)
	}
}

func TestPATStoreMissingKeyDisabled(t *testing.T) {
	tests := map[string]*patStore{
		"nil key":   newPATStore(t.TempDir(), nil, 15*time.Minute),
		"empty dir": newPATStore("", bytes.Repeat([]byte("s"), patKeyLen), 15*time.Minute),
	}
	for name, store := range tests {
		t.Run(name, func(t *testing.T) {
			if store.Enabled() {
				t.Fatal("store reports enabled without a usable key/dir")
			}
			if err := store.Record("dummy-DO-NOT-USE@example.invalid", "pat-1"); err != nil {
				t.Fatalf("Record on a disabled store: %v", err)
			}
			if _, ok := store.Match("dummy-DO-NOT-USE@example.invalid", md5Hex("pat-1"+"s"), "s"); ok {
				t.Fatal("a disabled store matched")
			}
		})
	}
	var nilStore *patStore
	if nilStore.Enabled() {
		t.Fatal("nil store reports enabled")
	}
}

func TestPATStoreRevalidationDropsRevoked(t *testing.T) {
	const user = "dummy-DO-NOT-USE@example.invalid"
	store := testStore(t)
	for _, pat := range []string{"pat-good", "pat-revoked"} {
		if err := store.Record(user, pat); err != nil {
			t.Fatalf("Record: %v", err)
		}
	}

	kc := fakeKeycloak(t, user, "pat-good", new(int32))
	defer kc.Close()
	v, err := newValidator(kc.URL, "dummy-DO-NOT-USE-realm", "", &http.Client{Timeout: time.Second})
	if err != nil {
		t.Fatal(err)
	}

	store.revalidate(context.Background(), v)

	const salt = "f00d"
	if _, ok := store.Match(user, md5Hex("pat-good"+salt), salt); !ok {
		t.Fatal("a still-valid PAT was dropped by revalidation")
	}
	if _, ok := store.Match(user, md5Hex("pat-revoked"+salt), salt); ok {
		t.Fatal("a revoked PAT survived revalidation")
	}
}

// --- end-to-end: md5-only clients -------------------------------------------

// TestPlaintextValidationRecordsPAT proves the shim keeps a validated PAT so a
// later md5 request can be checked against it.
func TestPlaintextValidationRecordsPAT(t *testing.T) {
	const user = "dummy-DO-NOT-USE@example.invalid"
	var kcCalls int32
	kc := fakeKeycloak(t, user, "pat-123", &kcCalls)
	defer kc.Close()
	cap := &upstreamCapture{}
	up := fakeUpstream(t, cap)
	defer up.Close()

	store := testStore(t)
	srv := newTestServerWithStore(t, kc.URL, up.URL, time.Minute, store)

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/rest/ping.view?v=1.16.1&c=test&f=json", nil)
	req.Header.Set("Authorization", basic(user, "pat-123"))
	srv.Handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 (body %q)", rec.Code, rec.Body.String())
	}
	if _, ok := store.Match(user, md5Hex("pat-123"+"salt"), "salt"); !ok {
		t.Fatal("the validated PAT was not recorded")
	}
}

func TestMD5ClientAgainstRecordedPAT(t *testing.T) {
	const user = "dummy-DO-NOT-USE@example.invalid"
	const salt = "c0ffee"
	var kcCalls int32
	kc := fakeKeycloak(t, user, "pat-123", &kcCalls)
	defer kc.Close()
	cap := &upstreamCapture{}
	up := fakeUpstream(t, cap)
	defer up.Close()

	srv := newTestServerWithStore(t, kc.URL, up.URL, time.Minute, testStore(t))

	// Record via a plaintext query credential.
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/rest/ping.view?u="+url.QueryEscape(user)+"&p=pat-123&f=json", nil)
	srv.Handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusOK || atomic.LoadInt32(&cap.hits) != 1 {
		t.Fatalf("record request: status=%d hits=%d", rec.Code, cap.hits)
	}

	// An md5-only client now authenticates with the same PAT.
	cap.hits = 0
	cap.identityHeader = ""
	rec = httptest.NewRecorder()
	req = httptest.NewRequest(http.MethodGet, "/rest/ping.view?u="+url.QueryEscape(user)+"&t="+md5Hex("pat-123"+salt)+"&s="+salt+"&f=json", nil)
	srv.Handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("md5 status = %d, want 200 (body %q)", rec.Code, rec.Body.String())
	}
	if atomic.LoadInt32(&cap.hits) != 1 {
		t.Fatalf("upstream hits = %d, want 1", cap.hits)
	}
	if cap.identityHeader != user {
		t.Fatalf("upstream identity = %q, want %q", cap.identityHeader, user)
	}
	if cap.authorization != "" || cap.ndAuthorization != "" {
		t.Fatalf("upstream saw a client credential: Authorization=%q", cap.authorization)
	}
}

func TestMD5WrongReturnsCode41(t *testing.T) {
	const user = "dummy-DO-NOT-USE@example.invalid"
	var kcCalls int32
	kc := fakeKeycloak(t, user, "pat-123", &kcCalls)
	defer kc.Close()
	cap := &upstreamCapture{}
	up := fakeUpstream(t, cap)
	defer up.Close()

	store := testStore(t)
	if err := store.Record(user, "pat-123"); err != nil {
		t.Fatal(err)
	}
	srv := newTestServerWithStore(t, kc.URL, up.URL, time.Minute, store)

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/rest/ping.view?u="+url.QueryEscape(user)+"&t="+md5Hex("wrong-pat"+"salt")+"&s=salt&f=json", nil)
	srv.Handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	if got := subsonicErrorCode(t, rec.Body.Bytes()); got != subsonicErrorTokenUnsupported {
		t.Fatalf("error code = %d, want %d", got, subsonicErrorTokenUnsupported)
	}
	if atomic.LoadInt32(&cap.hits) != 0 {
		t.Fatal("upstream was called for an unmatched md5")
	}
}

func TestMD5RevokedAfterRevalidation(t *testing.T) {
	const user = "dummy-DO-NOT-USE@example.invalid"
	const pat = "dummy-DO-NOT-USE-pat-revoked"
	const salt = "cafebabe"

	var accept atomic.Bool
	accept.Store(true)
	kc := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		u, p, ok := r.BasicAuth()
		if !ok || u != user || p != pat || !accept.Load() {
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

	store := testStore(t)
	srv := newTestServerWithStore(t, kc.URL, up.URL, time.Minute, store)

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/rest/ping.view?u="+url.QueryEscape(user)+"&p="+pat+"&f=json", nil)
	srv.Handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("record request status = %d (body %q)", rec.Code, rec.Body.String())
	}

	md5Request := func() *httptest.ResponseRecorder {
		r := httptest.NewRecorder()
		q := httptest.NewRequest(http.MethodGet, "/rest/ping.view?u="+url.QueryEscape(user)+"&t="+md5Hex(pat+salt)+"&s="+salt+"&f=json", nil)
		srv.Handler().ServeHTTP(r, q)
		return r
	}

	cap.hits = 0
	if rec := md5Request(); rec.Code != http.StatusOK || atomic.LoadInt32(&cap.hits) != 1 {
		t.Fatalf("md5 before revoke: status=%d hits=%d", rec.Code, cap.hits)
	}

	accept.Store(false)
	store.revalidate(context.Background(), srv.validator)

	cap.hits = 0
	rec = md5Request()
	if got := subsonicErrorCode(t, rec.Body.Bytes()); got != subsonicErrorTokenUnsupported {
		t.Fatalf("revoked md5 code = %d, want %d", got, subsonicErrorTokenUnsupported)
	}
	if atomic.LoadInt32(&cap.hits) != 0 {
		t.Fatal("upstream was called for a revoked PAT")
	}
}

// --- configuration ----------------------------------------------------------

func TestParseStoreKey(t *testing.T) {
	raw := bytes.Repeat([]byte("k"), patKeyLen)
	for name, enc := range map[string]string{
		"std":       base64.StdEncoding.EncodeToString(raw),
		"raw-std":   base64.RawStdEncoding.EncodeToString(raw),
		"url":       base64.URLEncoding.EncodeToString(raw),
		"raw-url":   base64.RawURLEncoding.EncodeToString(raw),
		"raw-bytes": string(raw),
	} {
		t.Run(name, func(t *testing.T) {
			got, err := parseStoreKey(enc)
			if err != nil {
				t.Fatalf("parseStoreKey(%q): %v", enc, err)
			}
			if len(got) != patKeyLen {
				t.Fatalf("key is %d bytes, want %d", len(got), patKeyLen)
			}
		})
	}
	if _, err := parseStoreKey("tooshort"); err == nil {
		t.Fatal("accepted a short store key")
	}
}

func TestLoadConfigPATStore(t *testing.T) {
	t.Setenv("SUBSONIC_TOKEN_KEY", "dummy-DO-NOT-USE-token-signing-key-0123456789abcdef")
	t.Setenv("KEYCLOAK_REALM", "example-realm")

	// A missing key leaves the store disabled (nil key) without failing.
	t.Setenv("SUBSONIC_PAT_KEY", "")
	t.Setenv("PAT_STORE_DIR", "")
	t.Setenv("PAT_TRANSIENT_GRACE", "")
	cfg, err := loadConfig()
	if err != nil {
		t.Fatalf("loadConfig without a store key: %v", err)
	}
	if cfg.patStoreKey != nil {
		t.Fatalf("patStoreKey = %v, want nil (disabled)", cfg.patStoreKey)
	}
	if cfg.patStoreDir != "/var/lib/subsonic-auth" {
		t.Fatalf("patStoreDir = %q, want the default", cfg.patStoreDir)
	}
	if cfg.patTransientGrace != 15*time.Minute {
		t.Fatalf("patTransientGrace = %s, want the 15m default", cfg.patTransientGrace)
	}

	t.Setenv("SUBSONIC_PAT_KEY", base64.StdEncoding.EncodeToString(bytes.Repeat([]byte("p"), patKeyLen)))
	t.Setenv("PAT_STORE_DIR", "/tmp/example-subsonic")
	t.Setenv("PAT_REVALIDATE_INTERVAL", "30m")
	t.Setenv("PAT_TRANSIENT_GRACE", "45s")
	cfg, err = loadConfig()
	if err != nil {
		t.Fatalf("loadConfig with a store key: %v", err)
	}
	if len(cfg.patStoreKey) != patKeyLen {
		t.Fatalf("patStoreKey is %d bytes, want %d", len(cfg.patStoreKey), patKeyLen)
	}
	if cfg.patStoreDir != "/tmp/example-subsonic" {
		t.Fatalf("patStoreDir = %q", cfg.patStoreDir)
	}
	if cfg.patRevalidateInterval != 30*time.Minute {
		t.Fatalf("patRevalidateInterval = %s, want 30m", cfg.patRevalidateInterval)
	}
	if cfg.patTransientGrace != 45*time.Second {
		t.Fatalf("patTransientGrace = %s, want 45s", cfg.patTransientGrace)
	}

	t.Setenv("PAT_TRANSIENT_GRACE", "0")
	cfg, err = loadConfig()
	if err != nil {
		t.Fatalf("loadConfig with a zero grace: %v", err)
	}
	if cfg.patTransientGrace != 15*time.Minute {
		t.Fatalf("patTransientGrace = %s, want the 15m default for a non-positive value", cfg.patTransientGrace)
	}

	t.Setenv("SUBSONIC_PAT_KEY", "tooshort")
	if _, err := loadConfig(); err == nil {
		t.Fatal("loadConfig accepted a malformed store key")
	}
}

// --- PAT-bound session store ------------------------------------------------

func newTestValidator(t *testing.T, keycloakURL string) *validator {
	t.Helper()
	v, err := newValidator(keycloakURL, "dummy-DO-NOT-USE-realm", "", &http.Client{Timeout: time.Second})
	if err != nil {
		t.Fatalf("validator: %v", err)
	}
	return v
}

func TestPATStoreLookup(t *testing.T) {
	const (
		user = "dummy-DO-NOT-USE@example.invalid"
		pat  = "dummy-DO-NOT-USE-pat-lookup-0123456789"
	)
	store := testStore(t)
	if err := store.Record(user, pat); err != nil {
		t.Fatalf("Record: %v", err)
	}

	// A second store over the same directory sees the persisted PAT and stamp.
	reopened := newPATStore(store.dir, store.key, store.grace)
	if !reopened.Lookup(user, PATHash(pat)) {
		t.Fatal("Lookup refused a recorded, just-validated PAT")
	}

	for name, tc := range map[string]struct{ identity, hash string }{
		"other PAT":                {user, PATHash("dummy-DO-NOT-USE-pat-other")},
		"unknown user":             {"dummy-DO-NOT-USE-other@example.invalid", PATHash(pat)},
		"plaintext passed as hash": {user, pat},
		"empty hash":               {user, ""},
		"empty identity":           {"", PATHash(pat)},
	} {
		t.Run(name, func(t *testing.T) {
			if reopened.Lookup(tc.identity, tc.hash) {
				t.Fatal("Lookup accepted a non-matching PAT hash")
			}
		})
	}
}

func TestRecordStampsLastValidated(t *testing.T) {
	const (
		user = "dummy-DO-NOT-USE@example.invalid"
		pat  = "dummy-DO-NOT-USE-pat-stamped"
	)
	now := time.Unix(1_700_000_000, 0)
	store := newPATStore(t.TempDir(), bytes.Repeat([]byte("s"), patKeyLen), 15*time.Minute)
	store.now = func() time.Time { return now }

	if err := store.Record(user, pat); err != nil {
		t.Fatalf("Record: %v", err)
	}
	set, err := store.loadLocked(user)
	if err != nil || set == nil {
		t.Fatalf("loadLocked = (%v,%v), want a stored set", set, err)
	}
	got, ok := set.LastValidated[PATHash(pat)]
	if !ok || got != now.Unix() {
		t.Fatalf("LastValidated[ph] = (%d,%v), want (%d,true)", got, ok, now.Unix())
	}
}

func TestDuplicateRecordRefreshesLastValidated(t *testing.T) {
	const (
		user = "dummy-DO-NOT-USE@example.invalid"
		pat  = "dummy-DO-NOT-USE-pat-duplicate"
	)
	now := time.Unix(1_700_000_000, 0)
	store := newPATStore(t.TempDir(), bytes.Repeat([]byte("s"), patKeyLen), 15*time.Minute)
	store.now = func() time.Time { return now }

	if err := store.Record(user, pat); err != nil {
		t.Fatalf("Record: %v", err)
	}
	now = now.Add(5 * time.Minute)
	if err := store.Record(user, pat); err != nil {
		t.Fatalf("Record (duplicate): %v", err)
	}

	reopened := newPATStore(store.dir, store.key, store.grace)
	reopened.now = func() time.Time { return now }
	set, err := reopened.loadLocked(user)
	if err != nil || set == nil {
		t.Fatalf("loadLocked = (%v,%v), want a stored set", set, err)
	}
	if len(set.PATs) != 1 {
		t.Fatalf("stored %d PATs, want the duplicate deduplicated", len(set.PATs))
	}
	if got := set.LastValidated[PATHash(pat)]; got != now.Unix() {
		t.Fatalf("LastValidated[ph] = %d, want the duplicate's refresh at %d", got, now.Unix())
	}
}

func TestLookupRefusesNeverValidated(t *testing.T) {
	const (
		user = "dummy-DO-NOT-USE@example.invalid"
		pat  = "dummy-DO-NOT-USE-pat-never-validated"
	)
	store := newPATStore(t.TempDir(), bytes.Repeat([]byte("s"), patKeyLen), 15*time.Minute)

	// The pre-LastValidated on-disk format: a PAT with no timestamp at all.
	if err := store.saveLocked(&patSet{Identity: user, PATs: []string{pat}}); err != nil {
		t.Fatalf("saveLocked: %v", err)
	}
	if store.Lookup(user, PATHash(pat)) {
		t.Fatal("Lookup accepted a PAT that was never successfully validated")
	}

	// A stamp for some other hash does not vouch for this PAT either.
	if err := store.saveLocked(&patSet{
		Identity:      user,
		PATs:          []string{pat},
		LastValidated: map[string]int64{PATHash("dummy-DO-NOT-USE-pat-other"): store.now().Unix()},
	}); err != nil {
		t.Fatalf("saveLocked: %v", err)
	}
	if store.Lookup(user, PATHash(pat)) {
		t.Fatal("Lookup accepted a PAT with no matching validation stamp")
	}
}

func TestRevalidateKeepsOnTransient(t *testing.T) {
	const (
		user = "dummy-DO-NOT-USE@example.invalid"
		pat  = "dummy-DO-NOT-USE-pat-transient"
	)
	now := time.Unix(1_700_000_000, 0)
	store := newPATStore(t.TempDir(), bytes.Repeat([]byte("s"), patKeyLen), 15*time.Minute)
	store.now = func() time.Time { return now }
	if err := store.Record(user, pat); err != nil {
		t.Fatalf("Record: %v", err)
	}
	before, err := store.loadLocked(user)
	if err != nil || before == nil {
		t.Fatalf("loadLocked = (%v,%v), want a stored set", before, err)
	}

	kc := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusServiceUnavailable)
	}))
	defer kc.Close()
	store.revalidate(context.Background(), newTestValidator(t, kc.URL))

	after, err := store.loadLocked(user)
	if err != nil || after == nil {
		t.Fatalf("after a transient pass: loadLocked = (%v,%v), want the PAT kept", after, err)
	}
	if !store.Lookup(user, PATHash(pat)) {
		t.Fatal("a transient validation failure dropped the PAT")
	}
	if got := after.LastValidated[PATHash(pat)]; got != before.LastValidated[PATHash(pat)] {
		t.Fatalf("a transient pass advanced LastValidated: %d -> %d", before.LastValidated[PATHash(pat)], got)
	}
	const salt = "f00d"
	if _, ok := store.Match(user, md5Hex(pat+salt), salt); !ok {
		t.Fatal("a transient validation failure broke md5 matching")
	}
}

func TestRevalidateDropsOnDenied(t *testing.T) {
	const (
		user    = "dummy-DO-NOT-USE@example.invalid"
		good    = "dummy-DO-NOT-USE-pat-good"
		revoked = "dummy-DO-NOT-USE-pat-revoked"
	)
	store := testStore(t)
	for _, pat := range []string{good, revoked} {
		if err := store.Record(user, pat); err != nil {
			t.Fatalf("Record: %v", err)
		}
	}

	kc := fakeKeycloak(t, user, good, new(int32))
	defer kc.Close()
	store.revalidate(context.Background(), newTestValidator(t, kc.URL))

	if !store.Lookup(user, PATHash(good)) {
		t.Fatal("a still-valid PAT was dropped by revalidation")
	}
	if store.Lookup(user, PATHash(revoked)) {
		t.Fatal("a denied PAT survived revalidation")
	}
	if _, ok := store.Match(user, md5Hex(revoked+"salt"), "salt"); ok {
		t.Fatal("a denied PAT still matched on the md5 path")
	}

	set, err := store.loadLocked(user)
	if err != nil || set == nil {
		t.Fatalf("loadLocked = (%v,%v), want the kept PAT", set, err)
	}
	if _, ok := set.LastValidated[PATHash(revoked)]; ok {
		t.Fatal("the dropped PAT's timestamp was not deleted")
	}
	if _, ok := set.LastValidated[PATHash(good)]; !ok {
		t.Fatal("the kept PAT lost its validation timestamp")
	}
}

func TestTransientGrace(t *testing.T) {
	const (
		user = "dummy-DO-NOT-USE@example.invalid"
		pat  = "dummy-DO-NOT-USE-pat-grace"
	)
	now := time.Unix(1_700_000_000, 0)
	store := newPATStore(t.TempDir(), bytes.Repeat([]byte("s"), patKeyLen), time.Minute)
	store.now = func() time.Time { return now }
	if err := store.Record(user, pat); err != nil {
		t.Fatalf("Record: %v", err)
	}

	transient := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusServiceUnavailable)
	}))
	defer transient.Close()

	// A transient outage longer than the grace keeps the PAT in the store but
	// refuses it for both session acceptance and md5 matching.
	now = now.Add(2 * time.Minute)
	store.revalidate(context.Background(), newTestValidator(t, transient.URL))
	if store.Lookup(user, PATHash(pat)) {
		t.Fatal("Lookup accepted a PAT past the transient grace")
	}
	if _, ok := store.Match(user, md5Hex(pat+"salt"), "salt"); ok {
		t.Fatal("md5 matching accepted a PAT past the transient grace")
	}

	// A later successful validation clears the stale state.
	good := fakeKeycloak(t, user, pat, new(int32))
	defer good.Close()
	now = now.Add(time.Second)
	store.revalidate(context.Background(), newTestValidator(t, good.URL))
	if !store.Lookup(user, PATHash(pat)) {
		t.Fatal("a successful validation did not clear the stale state")
	}
}

func TestMD5MatchRefusesAfterGrace(t *testing.T) {
	const (
		user = "dummy-DO-NOT-USE@example.invalid"
		pat  = "dummy-DO-NOT-USE-pat-md5-grace"
		salt = "c0ffee"
	)
	now := time.Unix(1_700_000_000, 0)
	store := newPATStore(t.TempDir(), bytes.Repeat([]byte("s"), patKeyLen), time.Minute)
	store.now = func() time.Time { return now }
	if err := store.Record(user, pat); err != nil {
		t.Fatalf("Record: %v", err)
	}

	if _, ok := store.Match(user, md5Hex(pat+salt), salt); !ok {
		t.Fatal("a just-recorded PAT did not match before the grace")
	}
	now = now.Add(2 * time.Minute)
	if _, ok := store.Match(user, md5Hex(pat+salt), salt); ok {
		t.Fatal("md5 matching accepted a PAT past the transient grace without a successful pass")
	}
}

func TestRevalidationMergeKeepsConcurrentRecord(t *testing.T) {
	const (
		user       = "dummy-DO-NOT-USE@example.invalid"
		existing   = "dummy-DO-NOT-USE-pat-existing"
		concurrent = "dummy-DO-NOT-USE-pat-concurrent"
	)
	t0 := time.Unix(1_700_000_000, 0)
	now := t0
	store := newPATStore(t.TempDir(), bytes.Repeat([]byte("s"), patKeyLen), 15*time.Minute)
	store.now = func() time.Time { return now }
	if err := store.Record(user, existing); err != nil {
		t.Fatalf("Record: %v", err)
	}

	started := make(chan struct{})
	release := make(chan struct{})
	kc := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		u, p, _ := r.BasicAuth()
		if u != user || p != existing {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		close(started)
		<-release
		w.Header().Set("X-User", u)
		w.WriteHeader(http.StatusOK)
	}))
	defer kc.Close()

	v := newTestValidator(t, kc.URL)
	done := make(chan struct{})
	go func() {
		store.revalidate(context.Background(), v)
		close(done)
	}()
	<-started

	// A PAT recorded while the SPI call is in flight must survive the merge.
	now = t0.Add(time.Minute)
	if err := store.Record(user, concurrent); err != nil {
		t.Fatalf("concurrent Record: %v", err)
	}
	now = t0.Add(2 * time.Minute)
	close(release)
	<-done

	if !store.Lookup(user, PATHash(existing)) {
		t.Fatal("the validated PAT was dropped")
	}
	if !store.Lookup(user, PATHash(concurrent)) {
		t.Fatal("revalidation dropped a PAT recorded during its network calls")
	}
	set, err := store.loadLocked(user)
	if err != nil || set == nil {
		t.Fatalf("loadLocked = (%v,%v), want both PATs", set, err)
	}
	if len(set.PATs) != 2 {
		t.Fatalf("stored %d PATs, want 2", len(set.PATs))
	}
	if got := set.LastValidated[PATHash(existing)]; got != t0.Add(2*time.Minute).Unix() {
		t.Fatalf("validated PAT stamp = %d, want %d", got, t0.Add(2*time.Minute).Unix())
	}
	if got := set.LastValidated[PATHash(concurrent)]; got != t0.Add(time.Minute).Unix() {
		t.Fatalf("concurrent Record's stamp = %d, want %d", got, t0.Add(time.Minute).Unix())
	}
}

func TestCacheHitDoesNotRerecord(t *testing.T) {
	const (
		user = "dummy-DO-NOT-USE@example.invalid"
		pat  = "dummy-DO-NOT-USE-pat-cached"
	)
	var accept atomic.Bool
	accept.Store(true)
	var calls int32
	kc := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&calls, 1)
		u, p, ok := r.BasicAuth()
		if !ok || u != user || p != pat || !accept.Load() {
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

	store := testStore(t)
	// A long positive-cache TTL makes the second request a cache hit.
	srv := newTestServerWithStore(t, kc.URL, up.URL, time.Hour, store)

	request := func() *httptest.ResponseRecorder {
		rec := httptest.NewRecorder()
		req := httptest.NewRequest(http.MethodGet, "/rest/ping.view?u="+url.QueryEscape(user)+"&p="+pat+"&f=json", nil)
		srv.Handler().ServeHTTP(rec, req)
		return rec
	}

	if rec := request(); rec.Code != http.StatusOK {
		t.Fatalf("first request status = %d (body %q)", rec.Code, rec.Body.String())
	}
	if !store.Lookup(user, PATHash(pat)) {
		t.Fatal("the freshly validated PAT was not recorded")
	}

	accept.Store(false)
	store.revalidate(context.Background(), srv.validator)
	if store.Lookup(user, PATHash(pat)) {
		t.Fatal("revalidation did not drop the denied PAT")
	}

	before := atomic.LoadInt32(&calls)
	if rec := request(); rec.Code != http.StatusOK {
		t.Fatalf("cache-hit request status = %d (body %q)", rec.Code, rec.Body.String())
	}
	if got := atomic.LoadInt32(&calls); got != before {
		t.Fatalf("a cache hit re-validated against Keycloak: calls %d -> %d", before, got)
	}
	if store.Lookup(user, PATHash(pat)) {
		t.Fatal("a positive cache hit re-recorded a PAT that revalidation dropped")
	}
	if _, ok := store.Match(user, md5Hex(pat+"salt"), "salt"); ok {
		t.Fatal("a positive cache hit re-recorded the PAT for md5 matching")
	}
}
