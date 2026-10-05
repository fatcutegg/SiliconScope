//
//  File:      compress.go
//  Created:   2026-10-05
//  Updated:   2026-10-05
//  Developer: Kennt Kim / Calida Lab
//  Overview:  gzip for the /metrics response. A viewer polls every 3 s for as long as its window
//             is open, and the MachineMetrics JSON compresses several-fold (#71). The viewer's
//             URLSession asks for gzip and decodes it transparently; a client that doesn't ask
//             gets plain JSON, so nothing older breaks.
//  Notes:     acceptsGzip honours an explicit "gzip;q=0" refusal. Vary: Accept-Encoding is set on
//             every /metrics response so no cache in between can serve one form for the other.
//
package main

import (
	"compress/gzip"
	"encoding/json"
	"net/http"
	"strings"
)

// acceptsGzip reports whether an Accept-Encoding header allows a gzip response.
func acceptsGzip(header string) bool {
	for _, part := range strings.Split(strings.ToLower(header), ",") {
		fields := strings.Split(part, ";")
		coding := strings.TrimSpace(fields[0])
		if coding != "gzip" && coding != "*" {
			continue
		}
		for _, p := range fields[1:] {
			if strings.ReplaceAll(strings.TrimSpace(p), " ", "") == "q=0" {
				return false
			}
		}
		return true
	}
	return false
}

// writeJSON encodes v as the response body, gzipped when the request accepts it.
func writeJSON(w http.ResponseWriter, r *http.Request, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Add("Vary", "Accept-Encoding")
	if !acceptsGzip(r.Header.Get("Accept-Encoding")) {
		_ = json.NewEncoder(w).Encode(v)
		return
	}
	w.Header().Set("Content-Encoding", "gzip")
	gz := gzip.NewWriter(w)
	_ = json.NewEncoder(gz).Encode(v)
	_ = gz.Close()
}
