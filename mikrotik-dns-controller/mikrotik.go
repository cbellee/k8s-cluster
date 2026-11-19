package main

import (
	"context"
	"fmt"
	"time"

	"github.com/go-routeros/routeros/v3"
)

// MikroTikClient uses RouterOS's binary API, not HTTP.
type MikroTikClient struct {
	conn *routeros.Client
}

func NewMikroTikClient(host, username, password string, insecure bool) (*MikroTikClient, error) {
	conn, err := routeros.DialTimeout(host+":8728", username, password, 30*time.Second)
	if err != nil {
		return nil, fmt.Errorf("failed to connect to MikroTik: %w", err)
	}
	return &MikroTikClient{conn: conn}, nil
}

func (m *MikroTikClient) ListDNSEntries(ctx context.Context) ([]dnsEntry, error) {
	reply, err := m.conn.RunContext(ctx, "/ip/dns/static/print")
	if err != nil {
		return nil, fmt.Errorf("failed to list DNS entries: %w", err)
	}
	var entries []dnsEntry
	for _, row := range reply.Re {
		entry := dnsEntry{Type: "A"}
		for _, pair := range row.List {
			switch pair.Key {
			case ".id":
				entry.ID = pair.Value
			case "name":
				entry.Name = pair.Value
			case "address":
				entry.Address = pair.Value
			case "comment":
				entry.Comment = pair.Value
			case "type":
				entry.Type = pair.Value
			}
		}
		entries = append(entries, entry)
	}
	return entries, nil
}

func (m *MikroTikClient) SetDNSEntry(ctx context.Context, entry dnsEntry) error {
	command := []string{"/ip/dns/static/add", "=name=" + entry.Name}
	if entry.ID != "" {
		command = []string{"/ip/dns/static/set", "=.id=" + entry.ID}
	}
	command = append(command, "=address="+entry.Address, "=comment="+entry.Comment, "=type="+entry.Type)
	if _, err := m.conn.RunContext(ctx, command...); err != nil {
		return fmt.Errorf("failed to write DNS entry: %w", err)
	}
	return nil
}

func (m *MikroTikClient) DeleteDNSEntry(ctx context.Context, id string) error {
	if id == "" {
		return fmt.Errorf("cannot delete DNS entry without its RouterOS ID")
	}
	if _, err := m.conn.RunContext(ctx, "/ip/dns/static/remove", "=.id="+id); err != nil {
		return fmt.Errorf("failed to remove DNS entry: %w", err)
	}
	return nil
}
