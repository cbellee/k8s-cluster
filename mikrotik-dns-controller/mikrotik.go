package main

import (
	"context"
	"fmt"
	"time"

	"github.com/go-routeros/routeros/v3"
)

// MikroTikClient handles communication with MikroTik RouterOS via binary protocol.
//
// This client communicates using MikroTik's proprietary binary API protocol (not HTTP REST).
// The go-routeros library abstracts away the protocol details and provides a clean interface
// for executing API commands and parsing responses.
//
// Protocol Details:
// - Encoding: Length-prefixed words with key=value pairs (binary format)
// - Port: 8728 (unencrypted) or 8729 (TLS encrypted)
// - Commands: Executed using sentences like "/ip/dns/static/add" with attribute words
// - Responses: Parsed from proto.Sentence objects containing List ([]proto.Pair) fields
//
// Example API call:
//
//	reply, err := m.conn.RunContext(ctx,
//	  "/ip/dns/static/add",
//	  "=name=example.com",
//	  "=address=192.168.1.1",
//	  "=comment=My DNS entry",
//	)
type MikroTikClient struct {
	conn *routeros.Client
}

// NewMikroTikClient creates a new MikroTik API client using the binary protocol.
// Connects to RouterOS device on port 8728 (unencrypted) with 30-second timeout.
func NewMikroTikClient(host, username, password string, insecure bool) (*MikroTikClient, error) {
	// Connect to RouterOS device on port 8728 (MikroTik binary API port)
	// go-routeros handles the binary protocol internally
	conn, err := routeros.DialTimeout(host+":8728", username, password, 30*time.Second)
	if err != nil {
		return nil, fmt.Errorf("failed to connect to MikroTik: %w", err)
	}

	return &MikroTikClient{
		conn: conn,
	}, nil
}

// AddDNSEntry adds or updates a static DNS entry in MikroTik via binary API.
// Uses the /ip/dns/static/add and /ip/dns/static/set commands.
// Returns the DNS entry ID (.id) for future updates.
//
// Binary Protocol Flow:
// 1. First calls findDNSEntry() to check if entry exists
// 2. If exists: runs "/ip/dns/static/set" command with =.id=, =address=, =comment= attributes
// 3. If not exists: runs "/ip/dns/static/add" command with =name=, =address=, =comment= attributes
// 4. Parses proto.Sentence.List (slice of proto.Pair) to extract .id from response
func (m *MikroTikClient) AddDNSEntry(ctx context.Context, name, address, comment string) (string, error) {
	// First, check if entry already exists
	id, err := m.findDNSEntry(ctx, name)
	if err != nil {
		// If error, assume entry doesn't exist
		id = ""
	}

	if id != "" {
		// Update existing entry
		reply, err := m.conn.RunContext(ctx,
			"/ip/dns/static/set",
			fmt.Sprintf("=.id=%s", id),
			fmt.Sprintf("=address=%s", address),
			fmt.Sprintf("=comment=%s", comment),
		)
		if err != nil {
			return "", fmt.Errorf("failed to update DNS entry: %w", err)
		}
		if reply.Done == nil {
			return "", fmt.Errorf("unexpected reply format")
		}
		return id, nil
	}

	// Create new entry
	reply, err := m.conn.RunContext(ctx,
		"/ip/dns/static/add",
		fmt.Sprintf("=name=%s", name),
		fmt.Sprintf("=address=%s", address),
		fmt.Sprintf("=comment=%s", comment),
	)
	if err != nil {
		return "", fmt.Errorf("failed to add DNS entry: %w", err)
	}

	// Extract ID from reply if available
	if reply.Done != nil && len(reply.Done.List) > 0 {
		for _, pair := range reply.Done.List {
			if pair.Key == ".id" {
				return pair.Value, nil
			}
		}
	}

	return "", nil
}

// RemoveDNSEntry removes a static DNS entry from MikroTik via binary API.
// Uses the /ip/dns/static/remove command.
//
// Binary Protocol Flow:
// 1. Calls findDNSEntry() to get entry ID by name
// 2. Runs "/ip/dns/static/remove" command with =.id= attribute
// 3. Returns nil if entry doesn't exist (no error for idempotency)
func (m *MikroTikClient) RemoveDNSEntry(ctx context.Context, name string) error {
	// Find the entry ID by name
	id, err := m.findDNSEntry(ctx, name)
	if err != nil {
		return fmt.Errorf("failed to find DNS entry: %w", err)
	}

	if id == "" {
		// Entry doesn't exist, no error
		return nil
	}

	// Delete the entry
	_, err = m.conn.RunContext(ctx,
		"/ip/dns/static/remove",
		fmt.Sprintf("=.id=%s", id),
	)
	if err != nil {
		return fmt.Errorf("failed to remove DNS entry: %w", err)
	}

	return nil
}

// findDNSEntry searches for a DNS entry by name and returns its ID via binary API.
// Uses the /ip/dns/static/print command to list all entries.
//
// Binary Protocol Flow:
// 1. Runs "/ip/dns/static/print" command with no parameters
// 2. MikroTik returns proto.Sentence.Re slice (returned entries)
// 3. Each entry is a proto.Sentence with List ([]proto.Pair) containing key-value pairs
// 4. Iterates through List to find pair.Key=="name" matching the search term
// 5. Returns corresponding pair.Key==".id" value (the entry's unique identifier)
// 6. Returns empty string if not found (no error for idempotency)
func (m *MikroTikClient) findDNSEntry(ctx context.Context, name string) (string, error) {
	reply, err := m.conn.RunContext(ctx, "/ip/dns/static/print")
	if err != nil {
		return "", fmt.Errorf("failed to list DNS entries: %w", err)
	}

	// Search through all returned entries for matching name
	for _, re := range reply.Re {
		nameValue := ""
		idValue := ""

		for _, pair := range re.List {
			if pair.Key == "name" {
				nameValue = pair.Value
			}
			if pair.Key == ".id" {
				idValue = pair.Value
			}
		}

		if nameValue == name && idValue != "" {
			return idValue, nil
		}
	}

	return "", nil
}
