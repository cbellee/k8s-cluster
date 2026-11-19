package main

import (
	"context"
	"log"
	"os"
	"os/signal"
	"syscall"

	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/rest"
)

const (
	annotationEnabled  = "dns.mikrotik/enabled"
	annotationHostname = "dns.mikrotik/hostname"
	annotationComment  = "dns.mikrotik/comment"
	defaultComment     = "Managed by Kubernetes MikroTik DNS Controller"
)

func main() {
	mtHost := os.Getenv("MIKROTIK_HOST")
	mtUser := os.Getenv("MIKROTIK_USERNAME")
	mtPassword := os.Getenv("MIKROTIK_PASSWORD")
	if mtHost == "" || mtUser == "" || mtPassword == "" {
		log.Fatal("MIKROTIK_HOST, MIKROTIK_USERNAME and MIKROTIK_PASSWORD must be set")
	}

	mtClient, err := NewMikroTikClient(mtHost, mtUser, mtPassword, os.Getenv("MIKROTIK_INSECURE") == "true")
	if err != nil {
		log.Fatalf("Failed to create MikroTik client: %v", err)
	}
	defer mtClient.conn.Close()

	config, err := rest.InClusterConfig()
	if err != nil {
		log.Fatalf("Failed to load in-cluster config: %v", err)
	}
	client, err := dynamic.NewForConfig(config)
	if err != nil {
		log.Fatalf("Failed to create Kubernetes client: %v", err)
	}

	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()
	if err := newDNSController(client, mtClient).Start(ctx); err != nil {
		log.Fatalf("DNS controller stopped: %v", err)
	}
}
