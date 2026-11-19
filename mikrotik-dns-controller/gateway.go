package main

import (
	"log"
	"net"
	"sort"
	"strings"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/labels"
)

type parentReference struct {
	Group       *string `json:"group,omitempty"`
	Kind        *string `json:"kind,omitempty"`
	Namespace   *string `json:"namespace,omitempty"`
	Name        string  `json:"name"`
	SectionName *string `json:"sectionName,omitempty"`
	Port        *int32  `json:"port,omitempty"`
}

type httpRoute struct {
	metav1.ObjectMeta `json:"metadata"`
	Spec              struct {
		Hostnames  []string          `json:"hostnames"`
		ParentRefs []parentReference `json:"parentRefs"`
	} `json:"spec"`
	Status struct {
		Parents []struct {
			ParentRef      parentReference    `json:"parentRef"`
			ControllerName string             `json:"controllerName"`
			Conditions     []metav1.Condition `json:"conditions"`
		} `json:"parents"`
	} `json:"status"`
}

type gateway struct {
	metav1.ObjectMeta `json:"metadata"`
	Spec              struct {
		Listeners []struct {
			Name          string         `json:"name"`
			Hostname      *string        `json:"hostname,omitempty"`
			Port          int32          `json:"port"`
			Protocol      string         `json:"protocol"`
			AllowedRoutes *allowedRoutes `json:"allowedRoutes,omitempty"`
		} `json:"listeners"`
	} `json:"spec"`
	Status struct {
		Addresses []struct {
			Type  string `json:"type"`
			Value string `json:"value"`
		} `json:"addresses"`
		Conditions []metav1.Condition `json:"conditions"`
		Listeners  []struct {
			Name       string             `json:"name"`
			Conditions []metav1.Condition `json:"conditions"`
		} `json:"listeners"`
	} `json:"status"`
}

type allowedRoutes struct {
	Namespaces *struct {
		From     string                `json:"from"`
		Selector *metav1.LabelSelector `json:"selector,omitempty"`
	} `json:"namespaces,omitempty"`
	Kinds []struct {
		Group *string `json:"group,omitempty"`
		Kind  string  `json:"kind"`
	} `json:"kinds,omitempty"`
}

func routeAllowed(allowed *allowedRoutes, routeNamespace, gatewayNamespace string, namespaces map[string]map[string]string) bool {
	if allowed == nil {
		return routeNamespace == gatewayNamespace
	}
	if len(allowed.Kinds) > 0 {
		matches := false
		for _, kind := range allowed.Kinds {
			if defaultString(kind.Group, gatewayResource.Group) == gatewayResource.Group && kind.Kind == "HTTPRoute" {
				matches = true
			}
		}
		if !matches {
			return false
		}
	}
	if allowed.Namespaces == nil {
		return routeNamespace == gatewayNamespace
	}
	switch allowed.Namespaces.From {
	case "All":
		return true
	case "", "Same":
		return routeNamespace == gatewayNamespace
	case "Selector":
		if allowed.Namespaces.Selector == nil {
			log.Printf("Gateway in namespace %s has allowedRoutes Selector without a selector", gatewayNamespace)
			return false
		}
		selector, err := metav1.LabelSelectorAsSelector(allowed.Namespaces.Selector)
		if err != nil {
			log.Printf("Gateway in namespace %s has invalid namespace selector: %v", gatewayNamespace, err)
			return false
		}
		values, exists := namespaces[routeNamespace]
		return exists && selector.Matches(labels.Set(values))
	default:
		log.Printf("Gateway in namespace %s has unsupported allowedRoutes namespace mode %q", gatewayNamespace, allowed.Namespaces.From)
		return false
	}
}

func currentCondition(conditions []metav1.Condition, name string, generation int64) bool {
	for _, condition := range conditions {
		if condition.Type == name {
			return condition.Status == metav1.ConditionTrue && condition.ObservedGeneration == generation
		}
	}
	return false
}

func defaultString(value *string, fallback string) string {
	if value != nil {
		return *value
	}
	return fallback
}

func sameParent(a, b parentReference, namespace string) bool {
	return a.Name == b.Name &&
		defaultString(a.Group, gatewayResource.Group) == defaultString(b.Group, gatewayResource.Group) &&
		defaultString(a.Kind, "Gateway") == defaultString(b.Kind, "Gateway") &&
		defaultString(a.Namespace, namespace) == defaultString(b.Namespace, namespace) &&
		defaultString(a.SectionName, "") == defaultString(b.SectionName, "") &&
		((a.Port == nil && b.Port == nil) || (a.Port != nil && b.Port != nil && *a.Port == *b.Port))
}

func listenerMatches(pattern *string, name string) bool {
	if pattern == nil {
		return true
	}
	host := strings.ToLower(*pattern)
	if strings.HasPrefix(host, "*.") {
		return strings.HasSuffix(name, host[1:])
	}
	return host == name
}

func routeAddresses(route httpRoute, hostname string, gateways map[string]gateway, namespaces map[string]map[string]string) []string {
	addresses := map[string]bool{}
	for _, parent := range route.Spec.ParentRefs {
		if defaultString(parent.Group, gatewayResource.Group) != gatewayResource.Group || defaultString(parent.Kind, "Gateway") != "Gateway" {
			continue
		}
		accepted := false
		for _, status := range route.Status.Parents {
			if status.ControllerName != "" && sameParent(parent, status.ParentRef, route.Namespace) &&
				currentCondition(status.Conditions, "Accepted", route.Generation) &&
				currentCondition(status.Conditions, "ResolvedRefs", route.Generation) {
				accepted = true
			}
		}
		gw, exists := gateways[defaultString(parent.Namespace, route.Namespace)+"/"+parent.Name]
		if !accepted || !exists || gw.DeletionTimestamp != nil ||
			!currentCondition(gw.Status.Conditions, "Accepted", gw.Generation) ||
			!currentCondition(gw.Status.Conditions, "Programmed", gw.Generation) {
			continue
		}
		matchingListener := false
		for _, listener := range gw.Spec.Listeners {
			if parent.SectionName != nil && *parent.SectionName != listener.Name {
				continue
			}
			if parent.Port != nil && *parent.Port != listener.Port {
				continue
			}
			if (listener.Protocol != "HTTP" && listener.Protocol != "HTTPS") || !listenerMatches(listener.Hostname, hostname) ||
				!routeAllowed(listener.AllowedRoutes, route.Namespace, gw.Namespace, namespaces) {
				continue
			}
			for _, status := range gw.Status.Listeners {
				if status.Name == listener.Name &&
					currentCondition(status.Conditions, "Accepted", gw.Generation) &&
					currentCondition(status.Conditions, "Programmed", gw.Generation) {
					matchingListener = true
				}
			}
		}
		if !matchingListener {
			continue
		}
		for _, address := range gw.Status.Addresses {
			ip := net.ParseIP(address.Value)
			if address.Type != "IPAddress" || ip == nil || ip.To4() == nil {
				log.Printf("Gateway %s/%s: unsupported DNS address %s %q; only IPv4 addresses are supported", gw.Namespace, gw.Name, address.Type, address.Value)
				continue
			}
			addresses[ip.String()] = true
		}
	}
	result := make([]string, 0, len(addresses))
	for address := range addresses {
		result = append(result, address)
	}
	sort.Strings(result)
	return result
}
