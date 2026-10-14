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

// writeSubsonicError renders a rejection in the format the client requested via
// `f`. The HTTP status is always 200: Subsonic carries the failure in the
// envelope, and a client that gates on the status before reading the body
// (Subtracks throws on any non-2xx) would otherwise never see the code — in
// particular 41, the signal to retry with a plaintext password.
func (s *server) writeSubsonicError(w http.ResponseWriter, r *http.Request, form url.Values, code int, message string) {
	switch param(r, form, "f") {
	case "json":
		s.writeJSON(w, http.StatusOK, subsonicErrorBody(code, message))
	case "jsonp":
		callback := param(r, form, "callback")
		if !validJSONPCallback(callback) {
			s.writeJSON(w, http.StatusOK, subsonicErrorBody(code, message))
			return
		}
		b, err := json.Marshal(subsonicErrorBody(code, message))
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
		resp := subsonicErrorXML{XMLNS: "http://subsonic.org/restapi", Status: "failed", Version: subsonicVersion}
		resp.Error.Code = code
		resp.Error.Message = message
		b, err := xml.Marshal(resp)
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
