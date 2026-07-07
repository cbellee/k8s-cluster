package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"os/signal"
	"syscall"
	"time"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/watch"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
)

const (
	// Annotation to enable DNS management for a service
	annotationEnabled = "dns.mikrotik/enabled"
	// Annotation to specify the DNS hostname
	annotationHostname = "dns.mikrotik/hostname"
	// Annotation for DNS entry comment
	annotationComment = "dns.mikrotik/comment"
	// Default comment if not specified
	defaultComment = "Managed by Kubernetes MikroTik DNS Controller"
)

// ServiceReconciler handles reconciliation of Kubernetes services with MikroTik DNS
type ServiceReconciler struct {
	kubeClient *kubernetes.Clientset
	mtClient   *MikroTikClient
}

// NewServiceReconciler creates a new service reconciler
func NewServiceReconciler(kubeClient *kubernetes.Clientset, mtClient *MikroTikClient) *ServiceReconciler {
	return &ServiceReconciler{
		kubeClient: kubeClient,
		mtClient:   mtClient,
	}
}

// Start begins watching services and reconciling them
func (sr *ServiceReconciler) Start(ctx context.Context) error {
	log.Println("Starting service watcher...")

	// Watch all services in all namespaces
	watcher, err := sr.kubeClient.CoreV1().Services("").Watch(ctx, metav1.ListOptions{})
	if err != nil {
		return fmt.Errorf("failed to create service watcher: %w", err)
	}
	defer watcher.Stop()

	// Process watch events
	for {
		select {
		case <-ctx.Done():
			log.Println("Stopping service watcher...")
			return nil

		case event, ok := <-watcher.ResultChan():
			if !ok {
				log.Println("Watcher channel closed, restarting...")
				// Restart watcher
				watcher.Stop()
				watcher, err = sr.kubeClient.CoreV1().Services("").Watch(ctx, metav1.ListOptions{})
				if err != nil {
					return fmt.Errorf("failed to recreate watcher: %w", err)
				}
				continue
			}

			service, ok := event.Object.(*corev1.Service)
			if !ok {
				continue
			}

			// Handle the event based on type
			switch event.Type {
			case watch.Added, watch.Modified:
				if err := sr.reconcileService(ctx, service); err != nil {
					log.Printf("Error reconciling service %s/%s: %v\n", service.Namespace, service.Name, err)
				}
			case watch.Deleted:
				if err := sr.deleteService(ctx, service); err != nil {
					log.Printf("Error deleting service %s/%s: %v\n", service.Namespace, service.Name, err)
				}
			}
		}
	}
}

// reconcileService processes a service and updates MikroTik DNS if needed
func (sr *ServiceReconciler) reconcileService(ctx context.Context, svc *corev1.Service) error {
	// Check if DNS management is enabled for this service
	annotations := svc.GetAnnotations()
	if annotations == nil {
		return nil
	}

	enabled, exists := annotations[annotationEnabled]
	if !exists || (enabled != "true" && enabled != "yes") {
		return nil
	}

	// Get hostname from annotation
	hostname, ok := annotations[annotationHostname]
	if !ok || hostname == "" {
		log.Printf("Service %s/%s has %s=true but no %s annotation, skipping\n",
			svc.Namespace, svc.Name, annotationEnabled, annotationHostname)
		return nil
	}

	// Only process LoadBalancer services
	if svc.Spec.Type != corev1.ServiceTypeLoadBalancer {
		log.Printf("Service %s/%s is not a LoadBalancer, skipping\n", svc.Namespace, svc.Name)
		return nil
	}

	// Get external IP
	externalIP := sr.getExternalIP(svc)
	if externalIP == "" {
		log.Printf("Service %s/%s has no external IP yet, skipping\n", svc.Namespace, svc.Name)
		return nil
	}

	// Get comment from annotation or use default
	comment := annotations[annotationComment]
	if comment == "" {
		comment = fmt.Sprintf("%s (K8s: %s/%s)", defaultComment, svc.Namespace, svc.Name)
	}

	// Add or update DNS entry in MikroTik
	log.Printf("Adding/updating DNS entry: %s -> %s\n", hostname, externalIP)
	_, err := sr.mtClient.AddDNSEntry(ctx, hostname, externalIP, comment)
	if err != nil {
		return fmt.Errorf("failed to add DNS entry: %w", err)
	}

	log.Printf("Successfully synced service %s/%s to MikroTik DNS\n", svc.Namespace, svc.Name)
	return nil
}

// deleteService removes the DNS entry when a service is deleted
func (sr *ServiceReconciler) deleteService(ctx context.Context, svc *corev1.Service) error {
	annotations := svc.GetAnnotations()
	if annotations == nil {
		return nil
	}

	enabled, exists := annotations[annotationEnabled]
	if !exists || (enabled != "true" && enabled != "yes") {
		return nil
	}

	hostname, ok := annotations[annotationHostname]
	if !ok || hostname == "" {
		return nil
	}

	log.Printf("Removing DNS entry: %s\n", hostname)
	err := sr.mtClient.RemoveDNSEntry(ctx, hostname)
	if err != nil {
		return fmt.Errorf("failed to remove DNS entry: %w", err)
	}

	log.Printf("Successfully removed service %s/%s from MikroTik DNS\n", svc.Namespace, svc.Name)
	return nil
}

// getExternalIP extracts the external IP from a LoadBalancer service
func (sr *ServiceReconciler) getExternalIP(svc *corev1.Service) string {
	// Check LoadBalancer ingress status
	if len(svc.Status.LoadBalancer.Ingress) > 0 {
		if svc.Status.LoadBalancer.Ingress[0].IP != "" {
			return svc.Status.LoadBalancer.Ingress[0].IP
		}
		if svc.Status.LoadBalancer.Ingress[0].Hostname != "" {
			return svc.Status.LoadBalancer.Ingress[0].Hostname
		}
	}
	return ""
}

func main() {
	// Read configuration from environment
	mtHost := os.Getenv("MIKROTIK_HOST")
	if mtHost == "" {
		log.Fatal("MIKROTIK_HOST environment variable not set")
	}

	mtUser := os.Getenv("MIKROTIK_USERNAME")
	if mtUser == "" {
		log.Fatal("MIKROTIK_USERNAME environment variable not set")
	}

	mtPassword := os.Getenv("MIKROTIK_PASSWORD")
	if mtPassword == "" {
		log.Fatal("MIKROTIK_PASSWORD environment variable not set")
	}

	mtInsecure := os.Getenv("MIKROTIK_INSECURE") == "true"

	log.Printf("Connecting to MikroTik at %s...\n", mtHost)

	// Create MikroTik client
	mtClient, err := NewMikroTikClient(mtHost, mtUser, mtPassword, mtInsecure)
	if err != nil {
		log.Fatalf("Failed to create MikroTik client: %v\n", err)
	}
	log.Println("Connected to MikroTik successfully")

	// Create Kubernetes client
	config, err := rest.InClusterConfig()
	if err != nil {
		log.Fatalf("Failed to load in-cluster config: %v\n", err)
	}

	clientset, err := kubernetes.NewForConfig(config)
	if err != nil {
		log.Fatalf("Failed to create Kubernetes client: %v\n", err)
	}
	log.Println("Connected to Kubernetes successfully")

	// Create service reconciler
	reconciler := NewServiceReconciler(clientset, mtClient)

	// Setup context with cancellation
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// Handle graceful shutdown
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)

	go func() {
		sig := <-sigChan
		log.Printf("Received signal: %v, shutting down...\n", sig)
		cancel()
	}()

	// Start reconciliation loop with retry
	for {
		if err := reconciler.Start(ctx); err != nil && err != context.Canceled {
			log.Printf("Reconciliation error: %v, retrying in 10 seconds...\n", err)
			time.Sleep(10 * time.Second)
			continue
		}
		break
	}

	log.Println("Controller stopped")
}
