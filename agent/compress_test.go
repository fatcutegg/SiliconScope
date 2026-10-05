//
//  File:      compress_test.go
//  Created:   2026-10-05
//  Updated:   2026-10-05
//  Developer: Kennt Kim / Calida Lab
//  Overview:  #71: /metrics is gzipped only for a client that asks, and what is sent decodes back
//             to the same JSON; a client that doesn't ask still gets plain JSON.
//
package main

import (
	"compress/gzip"
	"encoding/json"
	"io"
	"net/http/httptest"
	"testing"
)

func TestAcceptsGzip(t *testing.T) {
	cases := map[string]bool{
		"":                      false,
		"gzip":                  true,
		"gzip, deflate, br":     true,
		"br;q=1.0, gzip;q=0.8":  true,
		"deflate":               false,
		"gzip;q=0":              false,
		"gzip; q=0, deflate":    false,
		"*":                     true,
		"identity, GZIP":        true,
	}
	for header, want := range cases {
		if got := acceptsGzip(header); got != want {
			t.Errorf("acceptsGzip(%q) = %v, want %v", header, got, want)
		}
	}
}

func TestWriteJSONGzipsOnlyWhenAsked(t *testing.T) {
	payload := map[string]any{"hostname": "box", "cpu": map[string]any{"usagePercent": 12.5}}

	req := httptest.NewRequest("GET", "/metrics", nil)
	req.Header.Set("Accept-Encoding", "gzip, deflate")
	rec := httptest.NewRecorder()
	writeJSON(rec, req, payload)
	if rec.Header().Get("Content-Encoding") != "gzip" {
		t.Fatalf("Content-Encoding = %q, want gzip", rec.Header().Get("Content-Encoding"))
	}
	zr, err := gzip.NewReader(rec.Body)
	if err != nil {
		t.Fatalf("not a gzip stream: %v", err)
	}
	raw, _ := io.ReadAll(zr)
	var got map[string]any
	if err := json.Unmarshal(raw, &got); err != nil || got["hostname"] != "box" {
		t.Fatalf("decoded %q (err %v), want the payload back", raw, err)
	}

	plain := httptest.NewRecorder()
	writeJSON(plain, httptest.NewRequest("GET", "/metrics", nil), payload)
	if plain.Header().Get("Content-Encoding") != "" {
		t.Fatalf("plain request got Content-Encoding %q", plain.Header().Get("Content-Encoding"))
	}
	if err := json.Unmarshal(plain.Body.Bytes(), &got); err != nil {
		t.Fatalf("plain body is not JSON: %v", err)
	}
	if plain.Header().Get("Vary") != "Accept-Encoding" {
		t.Fatalf("Vary = %q, want Accept-Encoding", plain.Header().Get("Vary"))
	}
}
