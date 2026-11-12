package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"syscall"
)

// errDenied is a definitive rejection: the credential is bad or lacks the role.
var errDenied = errors.New("invalid or expired credential")

// errTransient means Keycloak could not render a verdict, so the credential
// must not be treated as revoked.
var errTransient = errors.New("temporary validation failure")

// validator calls the Keycloak Personal Access Token SPI endpoint.
type validator struct {
	endpoint     string
	requiredRole string
	client       *http.Client
}

func newValidator(keycloakURL, realm, requiredRole string, client *http.Client) (*validator, error) {
	base, err := url.Parse(keycloakURL)
	if err != nil {
		return nil, err
	}
	endpoint := base.JoinPath("realms", realm, "personal-access-token", "auth").String()
	return &validator{endpoint: endpoint, requiredRole: requiredRole, client: client}, nil
}

// validate sends `Authorization: Basic base64(user:token)` to the PAT endpoint.
// A 200 means the token is valid; the identity comes from the `X-User` response
// header. When `requiredRole` is set it rides along as `X-Required-Role`, so the
// PAT must be scoped to this service and a token minted for another app is
// refused (403).
func (v *validator) validate(ctx context.Context, user, token string) (string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, v.endpoint, nil)
	if err != nil {
		return "", err
	}
	req.SetBasicAuth(user, token)
	if v.requiredRole != "" {
		req.Header.Set("X-Required-Role", v.requiredRole)
	}
	resp, err := v.client.Do(req)
	if err != nil {
		if isTransientTransportError(err) {
			return "", fmt.Errorf("%w: %v", errTransient, err)
		}
		return "", err
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 4096))
	if resp.StatusCode != http.StatusOK {
		return "", statusError(resp.StatusCode)
	}
	identity := resp.Header.Get("X-User")
	if identity == "" {
		return "", errDenied
	}
	return identity, nil
}

func statusError(code int) error {
	switch {
	case code == http.StatusTooManyRequests, code >= 500 && code <= 599:
		return fmt.Errorf("%w: status %d", errTransient, code)
	default:
		return fmt.Errorf("%w: status %d", errDenied, code)
	}
}

func isTransientTransportError(err error) bool {
	var netErr net.Error
	return errors.As(err, &netErr) || errors.Is(err, syscall.ECONNREFUSED)
}
