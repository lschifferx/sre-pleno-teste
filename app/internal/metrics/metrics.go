package metrics

import (
	"runtime"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
)

var (
	RequestsTotal = promauto.NewCounterVec(
		prometheus.CounterOpts{
			Name: "http_requests_total",
			Help: "Total number of HTTP requests",
		},
		[]string{"method", "endpoint", "status"},
	)

	RequestDuration = promauto.NewHistogramVec(
		prometheus.HistogramOpts{
			Name:    "http_request_duration_seconds",
			Help:    "HTTP request duration in seconds",
			Buckets: prometheus.DefBuckets,
		},
		[]string{"method", "endpoint"},
	)

	ErrorRate = promauto.NewGaugeVec(
		prometheus.GaugeOpts{
			Name: "http_error_rate",
			Help: "Rate of HTTP errors per endpoint",
		},
		[]string{"endpoint"},
	)

	CPUUsage = promauto.NewGauge(
		prometheus.GaugeOpts{
			Name: "app_cpu_goroutines",
			Help: "Number of goroutines (proxy for CPU pressure)",
		},
	)

	MemoryUsage = promauto.NewGauge(
		prometheus.GaugeOpts{
			Name: "app_memory_alloc_bytes",
			Help: "Current memory allocation in bytes",
		},
	)

	Uptime = promauto.NewCounter(
		prometheus.CounterOpts{
			Name: "app_uptime_seconds_total",
			Help: "Total uptime in seconds",
		},
	)
)

// Init registers background collectors.
// Uses a 15-second ticker to avoid a busy-loop that would peg CPU
// and distort the very metrics being scraped.
func Init() {
	go func() {
		ticker := time.NewTicker(15 * time.Second)
		defer ticker.Stop()
		var ms runtime.MemStats
		// Collect once immediately so the first scrape is not empty.
		runtime.ReadMemStats(&ms)
		MemoryUsage.Set(float64(ms.Alloc))
		CPUUsage.Set(float64(runtime.NumGoroutine()))
		for range ticker.C {
			runtime.ReadMemStats(&ms)
			MemoryUsage.Set(float64(ms.Alloc))
			CPUUsage.Set(float64(runtime.NumGoroutine()))
		}
	}()
}
