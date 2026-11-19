package main

import (
	"context"
	"fmt"
	"log"
	"net"
	"sort"
	"strings"
	"time"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/util/validation"
	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/dynamic/dynamicinformer"
	"k8s.io/client-go/tools/cache"
	"k8s.io/client-go/util/workqueue"
)

const managedPrefix = "[k8s-mikrotik-dns] "

var (
	serviceResource   = schema.GroupVersionResource{Version: "v1", Resource: "services"}
	namespaceResource = schema.GroupVersionResource{Version: "v1", Resource: "namespaces"}
	gatewayResource   = schema.GroupVersionResource{Group: "gateway.networking.k8s.io", Version: "v1", Resource: "gateways"}
	routeResource     = schema.GroupVersionResource{Group: "gateway.networking.k8s.io", Version: "v1", Resource: "httproutes"}
)

type dnsEntry struct {
	ID, Name, Address, Comment, Type string
}

type dnsStore interface {
	ListDNSEntries(context.Context) ([]dnsEntry, error)
	SetDNSEntry(context.Context, dnsEntry) error
	DeleteDNSEntry(context.Context, string) error
}

type dnsController struct {
	client     dynamic.Interface
	factory    dynamicinformer.DynamicSharedInformerFactory
	services   cache.SharedIndexInformer
	gateways   cache.SharedIndexInformer
	routes     cache.SharedIndexInformer
	namespaces cache.SharedIndexInformer
	queue      workqueue.RateLimitingInterface
	dns        dnsStore
}

func newDNSController(client dynamic.Interface, dns dnsStore) *dnsController {
	factory := dynamicinformer.NewDynamicSharedInformerFactory(client, 0)
	return &dnsController{
		client:   client,
		factory:  factory,
		services: factory.ForResource(serviceResource).Informer(),
		queue:    workqueue.NewRateLimitingQueue(workqueue.DefaultControllerRateLimiter()),
		dns:      dns,
	}
}

func (c *dnsController) Start(ctx context.Context) error {
	defer c.queue.ShutDown()
	discoveryCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
	_, gatewayErr := c.client.Resource(gatewayResource).List(discoveryCtx, metav1.ListOptions{Limit: 1})
	_, routeErr := c.client.Resource(routeResource).List(discoveryCtx, metav1.ListOptions{Limit: 1})
	cancel()
	informers := []cache.SharedIndexInformer{c.services}
	if apierrors.IsNotFound(gatewayErr) && apierrors.IsNotFound(routeErr) {
		log.Println("Gateway API CRDs absent; watching Services only. Restart after installing Gateway API to enable HTTPRoute discovery.")
	} else if gatewayErr != nil || routeErr != nil {
		return fmt.Errorf("discover Gateway API resources: gateways: %v; httproutes: %v", gatewayErr, routeErr)
	} else {
		c.gateways = c.factory.ForResource(gatewayResource).Informer()
		c.routes = c.factory.ForResource(routeResource).Informer()
		c.namespaces = c.factory.ForResource(namespaceResource).Informer()
		informers = append(informers, c.gateways, c.routes, c.namespaces)
	}
	synced := make([]cache.InformerSynced, 0, len(informers))
	for _, informer := range informers {
		synced = append(synced, informer.HasSynced)
		if _, err := informer.AddEventHandler(cache.ResourceEventHandlerFuncs{
			AddFunc:    func(interface{}) { c.queue.Add("sync") },
			UpdateFunc: func(interface{}, interface{}) { c.queue.Add("sync") },
			DeleteFunc: func(interface{}) { c.queue.Add("sync") },
		}); err != nil {
			return fmt.Errorf("register event handler: %w", err)
		}
	}
	c.factory.Start(ctx.Done())
	syncCtx, cancel := context.WithTimeout(ctx, time.Minute)
	defer cancel()
	if !cache.WaitForCacheSync(syncCtx.Done(), synced...) {
		if ctx.Err() != nil {
			return nil
		}
		return fmt.Errorf("could not sync Service/Gateway/HTTPRoute/Namespace caches; check CRDs and RBAC")
	}
	log.Println("DNS inventory caches synced; starting reconciliation")
	go func() {
		<-ctx.Done()
		c.queue.ShutDown()
	}()
	c.queue.Add("sync")
	for {
		key, shutdown := c.queue.Get()
		if shutdown {
			return nil
		}
		syncCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
		err := c.reconcile(syncCtx)
		cancel()
		if err != nil {
			log.Printf("DNS reconciliation failed: %v", err)
			c.queue.AddRateLimited(key)
		} else {
			c.queue.Forget(key)
			c.queue.AddAfter(key, time.Minute)
		}
		c.queue.Done(key)
	}
}

func cachedObjects[T any](informer cache.SharedIndexInformer) ([]T, error) {
	var result []T
	if informer == nil {
		return result, nil
	}
	for _, item := range informer.GetStore().List() {
		object, ok := item.(*unstructured.Unstructured)
		if !ok {
			return nil, fmt.Errorf("unexpected cached object %T", item)
		}
		var value T
		if err := runtime.DefaultUnstructuredConverter.FromUnstructured(object.Object, &value); err != nil {
			return nil, fmt.Errorf("decode %s/%s: %w", object.GetNamespace(), object.GetName(), err)
		}
		result = append(result, value)
	}
	return result, nil
}

func (c *dnsController) reconcile(ctx context.Context) error {
	services, err := cachedObjects[corev1.Service](c.services)
	if err != nil {
		return err
	}
	gateways, err := cachedObjects[gateway](c.gateways)
	if err != nil {
		return err
	}
	routes, err := cachedObjects[httpRoute](c.routes)
	if err != nil {
		return err
	}
	namespaces, err := cachedObjects[corev1.Namespace](c.namespaces)
	if err != nil {
		return err
	}
	desired := discoverRecords(services, gateways, routes, namespaces)
	return syncRecords(ctx, c.dns, desired)
}

type recordClaim struct {
	address string
	comment string
	owner   string
}

type recordClaims map[string][]recordClaim

func enabled(meta metav1.ObjectMeta) bool {
	return meta.Annotations[annotationEnabled] == "true" || meta.Annotations[annotationEnabled] == "yes"
}

func hostname(value string) (string, error) {
	name := strings.TrimSuffix(strings.ToLower(value), ".")
	if errors := validation.IsDNS1123Subdomain(name); len(errors) != 0 {
		return "", fmt.Errorf("invalid concrete DNS hostname %q: %s", value, strings.Join(errors, ", "))
	}
	return name, nil
}

func comment(meta metav1.ObjectMeta) string {
	if value := meta.Annotations[annotationComment]; value != "" {
		return value
	}
	return fmt.Sprintf("%s (K8s: %s/%s)", defaultComment, meta.Namespace, meta.Name)
}

func discoverRecords(services []corev1.Service, gateways []gateway, routes []httpRoute, namespaces []corev1.Namespace) recordClaims {
	claims := recordClaims{}
	for _, service := range services {
		if !enabled(service.ObjectMeta) || service.Spec.Type != corev1.ServiceTypeLoadBalancer || service.DeletionTimestamp != nil {
			continue
		}
		name, err := hostname(service.Annotations[annotationHostname])
		if err != nil {
			log.Printf("Service %s/%s: %v", service.Namespace, service.Name, err)
			continue
		}
		address := ""
		if len(service.Status.LoadBalancer.Ingress) > 0 {
			address = service.Status.LoadBalancer.Ingress[0].IP
			if address == "" {
				address = service.Status.LoadBalancer.Ingress[0].Hostname
			}
		}
		if address != "" {
			claims[name] = append(claims[name], recordClaim{address, comment(service.ObjectMeta), "Service/" + service.Namespace + "/" + service.Name})
		}
	}
	gatewayByName := map[string]gateway{}
	for _, gateway := range gateways {
		gatewayByName[gateway.Namespace+"/"+gateway.Name] = gateway
	}
	namespaceLabels := map[string]map[string]string{}
	for _, namespace := range namespaces {
		namespaceLabels[namespace.Name] = namespace.Labels
	}
	for _, route := range routes {
		if !enabled(route.ObjectMeta) || route.DeletionTimestamp != nil {
			continue
		}
		if len(route.Spec.Hostnames) == 0 {
			log.Printf("HTTPRoute %s/%s: no explicit hostnames; DNS requires concrete spec.hostnames", route.Namespace, route.Name)
		}
		for _, raw := range route.Spec.Hostnames {
			name, err := hostname(raw)
			if err != nil {
				log.Printf("HTTPRoute %s/%s: %v", route.Namespace, route.Name, err)
				continue
			}
			addresses := routeAddresses(route, name, gatewayByName, namespaceLabels)
			if len(addresses) == 0 {
				log.Printf("HTTPRoute %s/%s: no current accepted and programmed Gateway listener/address for %s", route.Namespace, route.Name, name)
			}
			for _, address := range addresses {
				claims[name] = append(claims[name], recordClaim{address, comment(route.ObjectMeta), "HTTPRoute/" + route.Namespace + "/" + route.Name})
			}
		}
	}
	return claims
}

func syncRecords(ctx context.Context, dns dnsStore, claims recordClaims) error {
	entries, err := dns.ListDNSEntries(ctx)
	if err != nil {
		return err
	}
	existing := map[string][]dnsEntry{}
	for _, entry := range entries {
		existing[strings.TrimSuffix(strings.ToLower(entry.Name), ".")] = append(existing[strings.TrimSuffix(strings.ToLower(entry.Name), ".")], entry)
	}
	names := make([]string, 0, len(claims))
	for name := range claims {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		candidates := claims[name]
		sort.Slice(candidates, func(i, j int) bool { return candidates[i].owner < candidates[j].owner })
		chosen := candidates[0]
		conflict := false
		for _, candidate := range candidates {
			if candidate.address != chosen.address {
				conflict = true
			}
		}
		if conflict || len(existing[name]) > 1 {
			log.Printf("DNS hostname %s has conflicting claims or duplicate router records; leaving unchanged", name)
			continue
		}
		entry := dnsEntry{Name: name, Address: chosen.address, Comment: managedPrefix + chosen.comment, Type: "A"}
		if ip := net.ParseIP(chosen.address); ip != nil && ip.To4() == nil {
			entry.Type = "AAAA"
		}
		if len(existing[name]) == 1 {
			old := existing[name][0]
			// Adopt legacy records only when their original controller comment matches.
			legacy := false
			for _, candidate := range candidates {
				if old.Comment == candidate.comment {
					legacy = true
				}
			}
			if !strings.HasPrefix(old.Comment, managedPrefix) && !legacy {
				log.Printf("DNS hostname %s is owned outside this controller; leaving unchanged", name)
				continue
			}
			entry.ID = old.ID
			if old.Address == entry.Address && old.Comment == entry.Comment && old.Type == entry.Type {
				continue
			}
		}
		if err := dns.SetDNSEntry(ctx, entry); err != nil {
			return fmt.Errorf("sync DNS hostname %s: %w", name, err)
		}
		log.Printf("Synced DNS hostname %s -> %s (%s)", name, chosen.address, chosen.owner)
	}
	for _, entry := range entries {
		name := strings.TrimSuffix(strings.ToLower(entry.Name), ".")
		if _, wanted := claims[name]; wanted || !strings.HasPrefix(entry.Comment, managedPrefix) {
			continue
		}
		if err := dns.DeleteDNSEntry(ctx, entry.ID); err != nil {
			return fmt.Errorf("delete DNS hostname %s: %w", name, err)
		}
		log.Printf("Removed unclaimed DNS hostname %s", name)
	}
	return nil
}
