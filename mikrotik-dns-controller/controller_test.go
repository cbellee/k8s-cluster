package main

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/cache"
)

func pilot(t *testing.T) (gateway, httpRoute) {
	t.Helper()
	var gw gateway
	var route httpRoute
	for _, item := range []struct {
		value interface{}
		json  string
	}{
		{&gw, `{
			"metadata":{"name":"shared","namespace":"default","generation":2},
			"spec":{"listeners":[{"name":"https","hostname":"*.gateway","port":443,"protocol":"HTTPS"}]},
			"status":{
				"addresses":[{"type":"IPAddress","value":"172.16.0.2"}],
				"conditions":[
					{"type":"Accepted","status":"True","observedGeneration":2},
					{"type":"Programmed","status":"True","observedGeneration":2}
				],
				"listeners":[{"name":"https","conditions":[
					{"type":"Accepted","status":"True","observedGeneration":2},
					{"type":"Programmed","status":"True","observedGeneration":2}
				]}]
			}
		}`},
		{&route, `{
			"metadata":{"name":"blue","namespace":"default","generation":3,
				"annotations":{"dns.mikrotik/enabled":"true","dns.mikrotik/comment":"pilot"}},
			"spec":{"hostnames":["blue.gateway"],"parentRefs":[{"name":"shared","sectionName":"https"}]},
			"status":{"parents":[{
				"parentRef":{"name":"shared","sectionName":"https"},
				"controllerName":"io.cilium/gateway-controller",
				"conditions":[
					{"type":"Accepted","status":"True","observedGeneration":3},
					{"type":"ResolvedRefs","status":"True","observedGeneration":3}
				]
			}]}
		}`},
	} {
		if err := json.Unmarshal([]byte(item.json), item.value); err != nil {
			t.Fatal(err)
		}
	}
	return gw, route
}

func TestRouteDiscovery(t *testing.T) {
	for _, test := range []struct {
		name   string
		mutate func(*gateway, *httpRoute)
		want   int
	}{
		{"accepted wildcard listener", func(*gateway, *httpRoute) {}, 1},
		{"not opted in", func(_ *gateway, r *httpRoute) { r.Annotations = nil }, 0},
		{"rejected", func(_ *gateway, r *httpRoute) { r.Status.Parents[0].Conditions[0].Status = metav1.ConditionFalse }, 0},
		{"unresolved backend", func(_ *gateway, r *httpRoute) { r.Status.Parents[0].Conditions[1].Status = metav1.ConditionFalse }, 0},
		{"stale route status", func(_ *gateway, r *httpRoute) { r.Generation++ }, 0},
		{"stale gateway status", func(g *gateway, _ *httpRoute) { g.Generation++ }, 0},
		{"unprogrammed gateway", func(g *gateway, _ *httpRoute) { g.Status.Conditions[1].Status = metav1.ConditionFalse }, 0},
		{"unprogrammed listener", func(g *gateway, _ *httpRoute) { g.Status.Listeners[0].Conditions[1].Status = metav1.ConditionFalse }, 0},
		{"wrong listener hostname", func(g *gateway, _ *httpRoute) { g.Spec.Listeners[0].Hostname = stringPointer("other.gateway") }, 0},
		{"wildcard route skipped", func(_ *gateway, r *httpRoute) { r.Spec.Hostnames = []string{"*.gateway"} }, 0},
		{"no route hostname", func(_ *gateway, r *httpRoute) { r.Spec.Hostnames = nil }, 0},
		{"missing parent", func(_ *gateway, r *httpRoute) { r.Spec.ParentRefs[0].Name = "missing" }, 0},
		{"wrong parent status", func(_ *gateway, r *httpRoute) { r.Status.Parents[0].ParentRef.SectionName = stringPointer("http") }, 0},
		{"non gateway parent", func(_ *gateway, r *httpRoute) { r.Spec.ParentRefs[0].Kind = stringPointer("Service") }, 0},
		{"wrong parent port", func(_ *gateway, r *httpRoute) {
			port := int32(80)
			r.Spec.ParentRefs[0].Port = &port
			r.Status.Parents[0].ParentRef.Port = &port
		}, 0},
		{"hostname address skipped", func(g *gateway, _ *httpRoute) { g.Status.Addresses[0].Type = "Hostname" }, 0},
		{"IPv6 skipped", func(g *gateway, _ *httpRoute) { g.Status.Addresses[0].Value = "2001:db8::1" }, 0},
		{"deleting gateway", func(g *gateway, _ *httpRoute) { now := metav1.Now(); g.DeletionTimestamp = &now }, 0},
		{"deleting route", func(_ *gateway, r *httpRoute) { now := metav1.Now(); r.DeletionTimestamp = &now }, 0},
	} {
		t.Run(test.name, func(t *testing.T) {
			gw, route := pilot(t)
			test.mutate(&gw, &route)
			claims := discoverRecords(nil, []gateway{gw}, []httpRoute{route}, nil)
			if len(claims) != test.want {
				t.Fatalf("got %#v, want %d hostnames", claims, test.want)
			}
			if test.want == 1 && claims["blue.gateway"][0].address != "172.16.0.2" {
				t.Fatalf("unexpected address: %#v", claims)
			}
		})
	}
}

func stringPointer(value string) *string { return &value }

func TestSharedGatewayNamespacesAndHostnames(t *testing.T) {
	gw, route := pilot(t)
	route.Namespace = "apps"
	route.Spec.ParentRefs[0].Namespace = stringPointer("default")
	route.Status.Parents[0].ParentRef.Namespace = stringPointer("default")
	route.Spec.Hostnames = []string{"blue.gateway", "api.blue.gateway", "not-example.org"}
	if claims := discoverRecords(nil, []gateway{gw}, []httpRoute{route}, nil); len(claims) != 0 {
		t.Fatalf("Same namespace default must reject cross-namespace route: %#v", claims)
	}
	allowed := &allowedRoutes{}
	if err := json.Unmarshal([]byte(`{"namespaces":{"from":"Selector","selector":{"matchLabels":{"gateway-access":"yes"}}}}`), allowed); err != nil {
		t.Fatal(err)
	}
	gw.Spec.Listeners[0].AllowedRoutes = allowed
	ns := corev1.Namespace{ObjectMeta: metav1.ObjectMeta{Name: "apps", Labels: map[string]string{"gateway-access": "yes"}}}
	claims := discoverRecords(nil, []gateway{gw}, []httpRoute{route}, []corev1.Namespace{ns})
	if len(claims) != 2 || claims["blue.gateway"] == nil || claims["api.blue.gateway"] == nil {
		t.Fatalf("expected only concrete hostnames intersecting the listener: %#v", claims)
	}
	ns.Labels["gateway-access"] = "no"
	if got := discoverRecords(nil, []gateway{gw}, []httpRoute{route}, []corev1.Namespace{ns}); len(got) != 0 {
		t.Fatalf("namespace label change must withdraw discovery: %#v", got)
	}
	gw.Spec.Listeners[0].AllowedRoutes.Namespaces.From = "All"
	if got := discoverRecords(nil, []gateway{gw}, []httpRoute{route}, nil); len(got) != 2 {
		t.Fatalf("All namespaces must allow route: %#v", got)
	}
}

type fakeDNS struct {
	entries   []dnsEntry
	writes    []dnsEntry
	deletes   []string
	listErr   error
	writeErr  error
	deleteErr error
}

func (f *fakeDNS) ListDNSEntries(context.Context) ([]dnsEntry, error) { return f.entries, f.listErr }
func (f *fakeDNS) SetDNSEntry(_ context.Context, entry dnsEntry) error {
	f.writes = append(f.writes, entry)
	return f.writeErr
}
func (f *fakeDNS) DeleteDNSEntry(_ context.Context, id string) error {
	f.deletes = append(f.deletes, id)
	return f.deleteErr
}

func TestDNSOwnership(t *testing.T) {
	claim := recordClaim{"172.16.0.2", "pilot", "HTTPRoute/default/blue"}
	for _, test := range []struct {
		name            string
		entries         []dnsEntry
		claims          recordClaims
		writes, deletes int
	}{
		{"create", nil, recordClaims{"blue.gateway": {claim}}, 1, 0},
		{"adopt matching legacy record", []dnsEntry{{ID: "old", Name: "blue.gateway", Address: "172.16.0.2", Comment: "pilot", Type: "A"}}, recordClaims{"blue.gateway": {claim}}, 1, 0},
		{"preserve manual record", []dnsEntry{{ID: "manual", Name: "blue.gateway", Address: "172.16.0.9", Comment: "manual", Type: "A"}}, recordClaims{"blue.gateway": {claim}}, 0, 0},
		{"delete orphan after restart", []dnsEntry{{ID: "owned", Name: "blue.gateway", Comment: managedPrefix + "pilot"}}, nil, 0, 1},
		{"preserve orphan manual record", []dnsEntry{{ID: "manual", Name: "manual.gateway", Comment: "manual"}}, nil, 0, 0},
		{"conflicting owners preserve existing", []dnsEntry{{ID: "owned", Name: "blue.gateway", Comment: managedPrefix + "pilot"}}, recordClaims{"blue.gateway": {claim, {"172.16.0.3", "other", "Service/default/other"}}}, 0, 0},
		{"shared hostname coalesces", nil, recordClaims{"blue.gateway": {claim, {"172.16.0.2", "other", "Service/default/other"}}}, 1, 0},
		{"duplicate router records untouched", []dnsEntry{{ID: "one", Name: "blue.gateway", Comment: managedPrefix + "pilot"}, {ID: "two", Name: "blue.gateway", Comment: "manual"}}, recordClaims{"blue.gateway": {claim}}, 0, 0},
		{"unchanged record no API write", []dnsEntry{{ID: "owned", Name: "blue.gateway", Address: "172.16.0.2", Comment: managedPrefix + "pilot", Type: "A"}}, recordClaims{"blue.gateway": {claim}}, 0, 0},
	} {
		t.Run(test.name, func(t *testing.T) {
			dns := &fakeDNS{entries: test.entries}
			if err := syncRecords(context.Background(), dns, test.claims); err != nil {
				t.Fatal(err)
			}
			if len(dns.writes) != test.writes || len(dns.deletes) != test.deletes {
				t.Fatalf("writes=%#v deletes=%#v", dns.writes, dns.deletes)
			}
		})
	}
}

func TestServiceCompatibilityAndRouteDeletion(t *testing.T) {
	gw, route := pilot(t)
	svc := corev1.Service{
		ObjectMeta: metav1.ObjectMeta{Name: "blue", Namespace: "default", Annotations: map[string]string{
			annotationEnabled: "yes", annotationHostname: "blue.gateway", annotationComment: "pilot",
		}},
		Spec:   corev1.ServiceSpec{Type: corev1.ServiceTypeLoadBalancer},
		Status: corev1.ServiceStatus{LoadBalancer: corev1.LoadBalancerStatus{Ingress: []corev1.LoadBalancerIngress{{IP: "172.16.0.2"}}}},
	}
	claims := discoverRecords([]corev1.Service{svc}, []gateway{gw}, []httpRoute{route}, nil)
	if len(claims["blue.gateway"]) != 2 {
		t.Fatalf("expected both owners: %#v", claims)
	}
	claims = discoverRecords([]corev1.Service{svc}, []gateway{gw}, nil, nil)
	dns := &fakeDNS{entries: []dnsEntry{{ID: "owned", Name: "blue.gateway", Address: "172.16.0.2", Comment: managedPrefix + "pilot", Type: "A"}}}
	if err := syncRecords(context.Background(), dns, claims); err != nil {
		t.Fatal(err)
	}
	if len(dns.deletes) != 0 {
		t.Fatal("deleting route must not remove Service's record")
	}
	svc.Annotations[annotationHostname] = "renamed.gateway"
	dns = &fakeDNS{entries: dns.entries}
	if err := syncRecords(context.Background(), dns, discoverRecords([]corev1.Service{svc}, nil, nil, nil)); err != nil {
		t.Fatal(err)
	}
	if len(dns.writes) != 1 || dns.writes[0].Name != "renamed.gateway" || !reflect.DeepEqual(dns.deletes, []string{"owned"}) {
		t.Fatalf("rename not reconciled: %#v", dns)
	}
}

func TestReconciliationErrorsAreReturned(t *testing.T) {
	failure := errors.New("router unavailable")
	for _, dns := range []*fakeDNS{
		{listErr: failure},
		{writeErr: failure},
		{entries: []dnsEntry{{ID: "owned", Name: "orphan.gateway", Comment: managedPrefix + "pilot"}}, deleteErr: failure},
	} {
		err := syncRecords(context.Background(), dns, recordClaims{"blue.gateway": {{"172.16.0.2", "pilot", "HTTPRoute/default/blue"}}})
		if !errors.Is(err, failure) {
			t.Fatalf("expected router failure, got %v", err)
		}
	}
}

func TestGatewayAddressChangeAndMultipleParents(t *testing.T) {
	gw, route := pilot(t)
	other := gw
	other.Name = "other"
	other.Status.Addresses = append(other.Status.Addresses[:0:0], gw.Status.Addresses...)
	other.Status.Addresses[0].Value = "172.16.0.3"
	parent := route.Spec.ParentRefs[0]
	parent.Name = "other"
	route.Spec.ParentRefs = append(route.Spec.ParentRefs, parent)
	status := route.Status.Parents[0]
	status.ParentRef = parent
	route.Status.Parents = append(route.Status.Parents, status)
	claims := discoverRecords(nil, []gateway{gw, other}, []httpRoute{route}, nil)
	dns := &fakeDNS{}
	if err := syncRecords(context.Background(), dns, claims); err != nil {
		t.Fatal(err)
	}
	if len(dns.writes) != 0 {
		t.Fatal("different accepted parent addresses must not choose an arbitrary address")
	}
	route.Spec.ParentRefs = route.Spec.ParentRefs[:1]
	claims = discoverRecords(nil, []gateway{gw}, []httpRoute{route}, nil)
	dns = &fakeDNS{entries: []dnsEntry{{ID: "owned", Name: "blue.gateway", Address: "172.16.0.1", Comment: managedPrefix + "pilot", Type: "A"}}}
	if err := syncRecords(context.Background(), dns, claims); err != nil {
		t.Fatal(err)
	}
	if len(dns.writes) != 1 || dns.writes[0].Address != "172.16.0.2" || dns.writes[0].ID != "owned" {
		t.Fatalf("address change not reconciled: %#v", dns.writes)
	}
}

func TestCacheDecoding(t *testing.T) {
	gw, _ := pilot(t)
	object, err := runtime.DefaultUnstructuredConverter.ToUnstructured(&gw)
	if err != nil {
		t.Fatal(err)
	}
	informer := cache.NewSharedIndexInformer(&cache.ListWatch{}, &unstructured.Unstructured{}, 0, cache.Indexers{})
	if err := informer.GetStore().Add(&unstructured.Unstructured{Object: object}); err != nil {
		t.Fatal(err)
	}
	values, err := cachedObjects[gateway](informer)
	if err != nil || len(values) != 1 || values[0].Name != "shared" || len(values[0].Status.Conditions) != 2 {
		t.Fatalf("cache decode failed: %#v %v", values, err)
	}
}

func TestReconcileGatewayUpdateAndRouteOptOut(t *testing.T) {
	gw, route := pilot(t)
	client, err := dynamic.NewForConfig(&rest.Config{Host: "http://127.0.0.1"})
	if err != nil {
		t.Fatal(err)
	}
	dns := &fakeDNS{}
	controller := newDNSController(client, dns)
	defer controller.queue.ShutDown()
	controller.gateways = controller.factory.ForResource(gatewayResource).Informer()
	controller.routes = controller.factory.ForResource(routeResource).Informer()
	controller.namespaces = controller.factory.ForResource(namespaceResource).Informer()
	update := func(informer cache.SharedIndexInformer, object interface{}) {
		t.Helper()
		value, err := runtime.DefaultUnstructuredConverter.ToUnstructured(object)
		if err != nil {
			t.Fatal(err)
		}
		if err := informer.GetStore().Update(&unstructured.Unstructured{Object: value}); err != nil {
			t.Fatal(err)
		}
	}
	update(controller.gateways, &gw)
	update(controller.routes, &route)
	if err := controller.reconcile(context.Background()); err != nil {
		t.Fatal(err)
	}
	if len(dns.writes) != 1 || dns.writes[0].Address != "172.16.0.2" {
		t.Fatalf("initial inventory not reconciled: %#v", dns.writes)
	}
	dns.entries = []dnsEntry{dns.writes[0]}
	dns.entries[0].ID = "owned"
	gw.Status.Addresses[0].Value = "172.16.0.8"
	update(controller.gateways, &gw)
	if err := controller.reconcile(context.Background()); err != nil {
		t.Fatal(err)
	}
	if len(dns.writes) != 2 || dns.writes[1].Address != "172.16.0.8" {
		t.Fatalf("Gateway-only address change not reconciled: %#v", dns.writes)
	}
	route.Annotations[annotationEnabled] = "false"
	update(controller.routes, &route)
	if err := controller.reconcile(context.Background()); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(dns.deletes, []string{"owned"}) {
		t.Fatalf("opt-out did not withdraw owned record: %#v", dns.deletes)
	}
}

func TestConcreteHostnames(t *testing.T) {
	for _, value := range []string{"*.gateway", "", "invalid name"} {
		if _, err := hostname(value); err == nil {
			t.Fatalf("accepted invalid hostname %q", value)
		}
	}
	got, err := hostname("Blue.Gateway.")
	if err != nil || !strings.EqualFold(got, "blue.gateway") {
		t.Fatalf("normalization: %q %v", got, err)
	}
}

func TestStartupRejectsPartialInventory(t *testing.T) {
	for _, status := range []int{http.StatusForbidden, http.StatusNotFound} {
		t.Run(http.StatusText(status), func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Content-Type", "application/json")
				if strings.HasSuffix(r.URL.Path, "/gateways") {
					if status == http.StatusNotFound {
						w.WriteHeader(http.StatusOK)
						_, _ = w.Write([]byte(`{"apiVersion":"gateway.networking.k8s.io/v1","kind":"GatewayList","items":[]}`))
					} else {
						w.WriteHeader(status)
						_, _ = w.Write([]byte(`{"kind":"Status","apiVersion":"v1","status":"Failure","reason":"Forbidden","code":403}`))
					}
				} else {
					w.WriteHeader(http.StatusNotFound)
					_, _ = w.Write([]byte(`{"kind":"Status","apiVersion":"v1","status":"Failure","reason":"NotFound","code":404}`))
				}
			}))
			defer server.Close()
			client, err := dynamic.NewForConfig(&rest.Config{Host: server.URL})
			if err != nil {
				t.Fatal(err)
			}
			dns := &fakeDNS{entries: []dnsEntry{{ID: "owned", Name: "blue.gateway", Comment: managedPrefix + "pilot"}}}
			ctx, cancel := context.WithTimeout(context.Background(), time.Second)
			defer cancel()
			if err := newDNSController(client, dns).Start(ctx); err == nil {
				t.Fatal("expected discovery failure")
			}
			if len(dns.deletes) != 0 || len(dns.writes) != 0 {
				t.Fatal("partial discovery must never mutate DNS")
			}
		})
	}
}
