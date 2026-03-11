package handlers

import (
	"encoding/json"
	"math/rand"
	"net/http"
	"os"
	"runtime"
	"time"

	"github.com/prometheus/client_golang/prometheus/promhttp"
)

type response struct {
	Status    string      `json:"status"`
	Message   string      `json:"message,omitempty"`
	Data      interface{} `json:"data,omitempty"`
	Timestamp time.Time   `json:"timestamp"`
}

func writeJSON(w http.ResponseWriter, status int, payload interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(payload)
}

// HealthHandler — liveness probe
func HealthHandler(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, response{
		Status:    "healthy",
		Timestamp: time.Now().UTC(),
	})
}

// ReadyHandler — readiness probe
func ReadyHandler(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, response{
		Status:    "ready",
		Timestamp: time.Now().UTC(),
	})
}

// MetricsHandler — Prometheus scrape endpoint
func MetricsHandler(w http.ResponseWriter, r *http.Request) {
	promhttp.Handler().ServeHTTP(w, r)
}

// PingHandler — simple ping/pong
func PingHandler(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, response{
		Status:  "ok",
		Message: "pong",
		Timestamp: time.Now().UTC(),
	})
}

// StatusHandler — app info
func StatusHandler(w http.ResponseWriter, r *http.Request) {
	var ms runtime.MemStats
	runtime.ReadMemStats(&ms)

	writeJSON(w, http.StatusOK, response{
		Status: "ok",
		Data: map[string]interface{}{
			"app_env":    os.Getenv("APP_ENV"),
			"go_version": runtime.Version(),
			"goroutines": runtime.NumGoroutine(),
			"memory_mb":  float64(ms.Alloc) / 1024 / 1024,
		},
		Timestamp: time.Now().UTC(),
	})
}

// SimulateErrorHandler — forces a 500 for testing
func SimulateErrorHandler(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusInternalServerError, response{
		Status:    "error",
		Message:   "simulated error for observability testing",
		Timestamp: time.Now().UTC(),
	})
}

// SimulateLatencyHandler — adds artificial latency for histogram testing
func SimulateLatencyHandler(w http.ResponseWriter, r *http.Request) {
	delay := time.Duration(rand.Intn(2000)) * time.Millisecond
	time.Sleep(delay)
	writeJSON(w, http.StatusOK, response{
		Status:  "ok",
		Message: "delayed response",
		Data:    map[string]interface{}{"delay_ms": delay.Milliseconds()},
		Timestamp: time.Now().UTC(),
	})
}
