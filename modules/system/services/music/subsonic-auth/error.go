package main

import (
	"encoding/json"
	"encoding/xml"
	"net/http"
	"net/url"
)

// subsonicVersion is the API version the shim's own error envelopes advertise.
const subsonicVersion = "1.16.1"

// subsonicErrorBody is the `f=json` envelope, shaped as a map so it matches
// Navidrome's own JSON output.
func subsonicErrorBody(code int, message string) map[string]any {
	return map[string]any{
		"subsonic-response": map[string]any{
			"status":  "failed",
			"version": subsonicVersion,
			"error":   map[string]any{"code": code, "message": message},
		},
	}
}

// subsonicErrorXML is the same envelope for the XML transport (the Subsonic
// default, so a client that sends no `f` — Subtracks does — can parse it).
type subsonicErrorXML struct {
	XMLName xml.Name `xml:"subsonic-response"`
	XMLNS   string   `xml:"xmlns,attr"`
	Status  string   `xml:"status,attr"`
	Version string   `xml:"version,attr"`
	Error   struct {
		Code    int    `xml:"code,attr"`
		Message string `xml:"message,attr"`
	} `xml:"error"`
}

// subsonicUnavailableBody is the JSON `f=json` shape of a transient failure:
// status ok / code 0 plus a message, so the client retries.
func subsonicUnavailableBody() map[string]any {
	return map[string]any{
		"subsonic-response": map[string]any{
			"status":  "ok",
			"version": subsonicVersion,
			"message": "temporarily unavailable",
		},
	}
}

// subsonicUnavailableXML is the same envelope for the XML transport.
type subsonicUnavailableXML struct {
	XMLName xml.Name `xml:"subsonic-response"`
	XMLNS   string   `xml:"xmlns,attr"`
	Status  string   `xml:"status,attr"`
	Version string   `xml:"version,attr"`
	Message string   `xml:"message"`
}

// writeSubsonicError renders a rejection in the format the client requested via
// `f`. It is always HTTP 200: a client that gates on the status before reading
// the body (Subtracks throws on any non-2xx) would otherwise never see the
// code — in particular 41, the signal to retry with a plaintext password.
func (s *server) writeSubsonicError(w http.ResponseWriter, r *http.Request, form url.Values, code int, message string) {
	resp := subsonicErrorXML{XMLNS: "http://subsonic.org/restapi", Status: "failed", Version: subsonicVersion}
	resp.Error.Code = code
	resp.Error.Message = message
	s.writeSubsonicResult(w, r, form, subsonicErrorBody(code, message), resp)
}

// writeSubsonicUnavailable renders a transient failure as a successful Subsonic
// envelope (code 0) with a retry message, so a client neither clears its
// credential nor reports a fatal error.
func (s *server) writeSubsonicUnavailable(w http.ResponseWriter, r *http.Request, form url.Values) {
	resp := subsonicUnavailableXML{
		XMLNS:   "http://subsonic.org/restapi",
		Status:  "ok",
		Version: subsonicVersion,
		Message: "temporarily unavailable",
	}
	s.writeSubsonicResult(w, r, form, subsonicUnavailableBody(), resp)
}

// writeSubsonicResult renders an envelope in the format the client requested via
// `f`. The HTTP status is always 200: Subsonic carries its outcome in the body.
func (s *server) writeSubsonicResult(w http.ResponseWriter, r *http.Request, form url.Values, body map[string]any, xmlBody any) {
	switch param(r, form, "f") {
	case "json":
		s.writeJSON(w, http.StatusOK, body)
	case "jsonp":
		callback := param(r, form, "callback")
		if !validJSONPCallback(callback) {
			s.writeJSON(w, http.StatusOK, body)
			return
		}
		b, err := json.Marshal(body)
		if err != nil {
			http.Error(w, "internal error", http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", "application/javascript; charset=utf-8")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(callback + "("))
		_, _ = w.Write(b)
		_, _ = w.Write([]byte(")"))
	default:
		b, err := xml.Marshal(xmlBody)
		if err != nil {
			http.Error(w, "internal error", http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", "application/xml; charset=utf-8")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(xml.Header))
		_, _ = w.Write(b)
	}
}

// validJSONPCallback accepts only a JavaScript identifier path, so a reflected
// callback cannot break out of the wrapper.
func validJSONPCallback(cb string) bool {
	if cb == "" || len(cb) > 64 {
		return false
	}
	for _, c := range cb {
		switch {
		case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z', c >= '0' && c <= '9', c == '_', c == '$', c == '.':
		default:
			return false
		}
	}
	return true
}
