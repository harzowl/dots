package main

import (
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/md5"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"log"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// patKeyLen is the exact key length the store's AES-256-GCM cipher needs.
const patKeyLen = 32

// patSet is one user's recorded personal access tokens, encrypted on disk. The
// identity travels with the tokens so revalidation can name the user when it
// re-checks each PAT (the file name is only its hash).
type patSet struct {
	Identity string   `json:"identity"`
	PATs     []string `json:"pats"`
}

// patStore keeps a reversible, AES-256-GCM-encrypted, per-user set of Keycloak
// personal access tokens. Keycloak stores PATs hashed, so an md5-only client's
// `t = md5(password + salt)` can only be checked here, against the plaintext
// PAT. A missing key disables the store: nothing is recorded and an md5 client
// keeps getting code 41.
type patStore struct {
	dir string
	key []byte
	mu  sync.RWMutex
}

func newPATStore(dir string, key []byte) *patStore {
	return &patStore{dir: dir, key: key}
}

// Enabled reports whether the store will record and verify PATs.
func (st *patStore) Enabled() bool {
	return st != nil && len(st.key) == patKeyLen && st.dir != ""
}

// path is a user's store file: the hex sha256 of the username, so no personal
// identifier is written into a file name.
func (st *patStore) path(user string) string {
	sum := sha256.Sum256([]byte(user))
	return filepath.Join(st.dir, hex.EncodeToString(sum[:]))
}

// Record persists pat for identity. It is best-effort: callers log the error
// and carry on.
func (st *patStore) Record(identity, pat string) error {
	if !st.Enabled() || identity == "" || pat == "" {
		return nil
	}
	st.mu.Lock()
	defer st.mu.Unlock()
	set, err := st.loadLocked(identity)
	if err != nil {
		// An unreadable or undecryptable file is unusable; replace it rather
		// than let it wedge every future record (e.g. after a key rotation).
		set = nil
	}
	if set == nil {
		set = &patSet{Identity: identity}
	}
	for _, p := range set.PATs {
		if p == pat {
			return nil
		}
	}
	set.PATs = append(set.PATs, pat)
	return st.saveLocked(set)
}

// Match reports whether token is md5hex(pat+salt) for one of user's stored
// PATs, returning the identity to authenticate as. The comparison is
// case-insensitive (Subsonic md5 is lowercase hex) and constant-time per
// candidate.
func (st *patStore) Match(user, token, salt string) (string, bool) {
	if !st.Enabled() || user == "" || token == "" || salt == "" {
		return "", false
	}
	st.mu.RLock()
	defer st.mu.RUnlock()
	set, err := st.loadLocked(user)
	if err != nil || set == nil {
		return "", false
	}
	want := []byte(strings.ToLower(token))
	for _, pat := range set.PATs {
		got := []byte(md5Hex(pat + salt))
		if subtle.ConstantTimeCompare(got, want) == 1 {
			return set.Identity, true
		}
	}
	return "", false
}

func md5Hex(s string) string {
	sum := md5.Sum([]byte(s))
	return hex.EncodeToString(sum[:])
}

// runRevalidation periodically re-checks every stored PAT against the Keycloak
// PAT SPI and drops any that is no longer valid, so revoking a PAT in Keycloak
// eventually stops it authenticating md5 clients. It returns when ctx is done.
func (st *patStore) runRevalidation(ctx context.Context, v *validator, interval time.Duration) {
	if !st.Enabled() || interval <= 0 {
		return
	}
	t := time.NewTicker(interval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			st.revalidate(ctx, v)
		}
	}
}

func (st *patStore) revalidate(ctx context.Context, v *validator) {
	if !st.Enabled() {
		return
	}
	entries, err := os.ReadDir(st.dir)
	if err != nil {
		if !errors.Is(err, os.ErrNotExist) {
			log.Printf("subsonic-auth: PAT store revalidate: %v", err)
		}
		return
	}
	for _, e := range entries {
		if e.IsDir() || strings.HasPrefix(e.Name(), ".") {
			continue
		}
		st.revalidateOne(ctx, v, e.Name())
	}
}

func (st *patStore) revalidateOne(ctx context.Context, v *validator, name string) {
	st.mu.RLock()
	set, err := st.loadFileLocked(name)
	st.mu.RUnlock()
	if err != nil || set == nil {
		return
	}

	// Drop only what this pass actually confirmed revoked; a PAT recorded
	// while the SPI calls were in flight is kept.
	revoked := make(map[string]bool)
	for _, pat := range set.PATs {
		if _, err := v.validate(ctx, set.Identity, pat); err != nil {
			revoked[pat] = true
		}
	}
	if len(revoked) == 0 {
		return
	}

	st.mu.Lock()
	defer st.mu.Unlock()
	current, err := st.loadFileLocked(name)
	if err != nil || current == nil {
		return
	}
	kept := current.PATs[:0]
	for _, p := range current.PATs {
		if !revoked[p] {
			kept = append(kept, p)
		}
	}
	current.PATs = kept
	if err := st.saveLocked(current); err != nil {
		log.Printf("subsonic-auth: PAT store revalidate save: %v", err)
	}
}

func (st *patStore) loadLocked(user string) (*patSet, error) {
	sum := sha256.Sum256([]byte(user))
	return st.loadFileLocked(hex.EncodeToString(sum[:]))
}

func (st *patStore) loadFileLocked(name string) (*patSet, error) {
	blob, err := os.ReadFile(filepath.Join(st.dir, name))
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	plain, err := decryptPATSet(st.key, blob)
	if err != nil {
		return nil, err
	}
	var set patSet
	if err := json.Unmarshal(plain, &set); err != nil {
		return nil, err
	}
	if set.Identity == "" {
		return nil, errors.New("pat store: file has no identity")
	}
	return &set, nil
}

func (st *patStore) saveLocked(set *patSet) error {
	if len(set.PATs) == 0 {
		err := os.Remove(st.path(set.Identity))
		if err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
		return nil
	}
	plain, err := json.Marshal(set)
	if err != nil {
		return err
	}
	blob, err := encryptPATSet(st.key, plain)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(st.dir, 0o700); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(st.dir, ".tmp-")
	if err != nil {
		return err
	}
	name := tmp.Name()
	defer os.Remove(name)
	if err := tmp.Chmod(0o600); err != nil {
		tmp.Close()
		return err
	}
	if _, err := tmp.Write(blob); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(name, st.path(set.Identity))
}

func encryptPATSet(key, plaintext []byte) ([]byte, error) {
	gcm, err := newGCM(key)
	if err != nil {
		return nil, err
	}
	nonce := make([]byte, gcm.NonceSize())
	if _, err := io.ReadFull(rand.Reader, nonce); err != nil {
		return nil, err
	}
	return gcm.Seal(nonce, nonce, plaintext, nil), nil
}

func decryptPATSet(key, blob []byte) ([]byte, error) {
	gcm, err := newGCM(key)
	if err != nil {
		return nil, err
	}
	ns := gcm.NonceSize()
	if len(blob) < ns {
		return nil, errors.New("pat store: ciphertext too short")
	}
	return gcm.Open(nil, blob[:ns], blob[ns:], nil)
}

func newGCM(key []byte) (cipher.AEAD, error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	return cipher.NewGCM(block)
}
