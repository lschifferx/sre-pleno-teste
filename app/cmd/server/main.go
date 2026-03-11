package main

import (
	"context"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/sre-pleno-teste/internal/handlers"
	"github.com/sre-pleno-teste/internal/metrics"
	"github.com/sre-pleno-teste/internal/middleware"
)

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	appEnv := os.Getenv("APP_ENV")
	if appEnv == "" {
		appEnv = "development"
	}

	log.Printf("Starting SRE Demo App | env=%s port=%s", appEnv, port)

	metrics.Init()

	mux := http.NewServeMux()

	mux.HandleFunc("/health",  handlers.HealthHandler)
	mux.HandleFunc("/ready",   handlers.ReadyHandler)
	mux.HandleFunc("/metrics", handlers.MetricsHandler)
	mux.HandleFunc("/api/v1/ping",   handlers.PingHandler)
	mux.HandleFunc("/api/v1/status", handlers.StatusHandler)
	mux.HandleFunc("/api/v1/simulate/error",   handlers.SimulateErrorHandler)
	mux.HandleFunc("/api/v1/simulate/latency", handlers.SimulateLatencyHandler)

	logged := middleware.Logging(middleware.Recovery(mux))

	srv := &http.Server{
		Addr:         ":" + port,
		Handler:      logged,
		ReadTimeout:  10 * time.Second,
		WriteTimeout: 30 * time.Second,
		IdleTimeout:  60 * time.Second,
	}

	go func() {
		log.Printf("Server listening on :%s", port)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("Server error: %v", err)
		}
	}()

	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit

	log.Println("Shutting down server...")
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	if err := srv.Shutdown(ctx); err != nil {
		log.Fatalf("Forced shutdown: %v", err)
	}
	log.Println("Server exited cleanly")
}
