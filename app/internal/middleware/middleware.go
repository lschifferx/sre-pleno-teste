package middleware

import (
	"log"
	"net/http"
	"strconv"
	"time"

	"github.com/sre-pleno-teste/internal/metrics"
)

// responseWriter wraps http.ResponseWriter to capture status code
type responseWriter struct {
	http.ResponseWriter
	status int
	size   int
}

func newResponseWriter(w http.ResponseWriter) *responseWriter {
	return &responseWriter{ResponseWriter: w, status: http.StatusOK}
}

func (rw *responseWriter) WriteHeader(code int) {
	rw.status = code
	rw.ResponseWriter.WriteHeader(code)
}

func (rw *responseWriter) Write(b []byte) (int, error) {
	n, err := rw.ResponseWriter.Write(b)
	rw.size += n
	return n, err
}

// Logging middleware records structured logs and Prometheus metrics
func Logging(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rw := newResponseWriter(w)

		next.ServeHTTP(rw, r)

		duration := time.Since(start)
		statusStr := strconv.Itoa(rw.status)

		// Prometheus
		metrics.RequestsTotal.WithLabelValues(r.Method, r.URL.Path, statusStr).Inc()
		metrics.RequestDuration.WithLabelValues(r.Method, r.URL.Path).Observe(duration.Seconds())

		// Determine structured log level from HTTP status
		var level string
		switch {
		case rw.status >= 500:
			level = "ERROR"
			metrics.ErrorRate.WithLabelValues(r.URL.Path).Inc()
		case rw.status >= 400:
			level = "WARN"
		default:
			level = "INFO"
		}

		// Structured log — key=value format parsed by Filebeat dissect processor
		log.Printf("timestamp=%s level=%s endpoint=%s method=%s status=%d latency=%dms size=%d",
			time.Now().UTC().Format(time.RFC3339),
			level,
			r.URL.Path,
			r.Method,
			rw.status,
			duration.Milliseconds(),
			rw.size,
		)
	})
}

// Recovery middleware catches panics and returns 500
func Recovery(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer func() {
			if err := recover(); err != nil {
				log.Printf("timestamp=%s level=ERROR endpoint=%s panic=%v",
					time.Now().UTC().Format(time.RFC3339),
					r.URL.Path,
					err,
				)
				http.Error(w, "Internal Server Error", http.StatusInternalServerError)
			}
		}()
		next.ServeHTTP(w, r)
	})
}
