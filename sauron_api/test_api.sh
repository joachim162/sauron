#!/bin/bash
# API Test Commands for Sauron REST API
# Usage: source this file or copy individual commands
#
# Run the API first:
#   cd sauron_api && perl script/sauron_api daemon
#
# Default: http://localhost:3000/api/v1

BASE="http://sulis33.zcu.cz:8080/api/v1"

# Server endpoints
# --------------------------------------------------

# List all servers
curl -s "$BASE/servers" | jq .

# Get server by name
curl -s "$BASE/servers/middle-earth" | jq .

# Zone endpoints
# --------------------------------------------------

# Create a zone
curl -s -X POST "$BASE/servers/middle-earth/zones" \
  -H "Content-Type: application/json" \
  -d '{"name": "test.example.com", "type": "Master", "reverse": false}' | jq .

# Delete a zone
curl -s -X DELETE "$BASE/servers/middle-earth/zones/test.example.com" | jq .

# Host endpoints
# --------------------------------------------------

# Get host by FQDN
curl -s "$BASE/hosts/ws1.middle.earth" | jq .

# Create a host
curl -s -X POST "$BASE/hosts/ws1.middle.earth" \
  -H "Content-Type: application/json" \
  -d '{"type": 1, "comment": "Test host"}' | jq .

# Update a host (scalar fields only)
curl -s -X PUT "$BASE/hosts/ws1.middle.earth" \
  -H "Content-Type: application/json" \
  -d '{
    "ttl": 3600,
    "class": "IN",
    "hinfo_hw": "x86_64",
    "hinfo_sw": "Linux",
    "location": "Building A, Room 101",
    "info": "Updated via API"
  }' | jq .

# Update a host (add SSHFP records)
curl -s -X PUT "$BASE/hosts/ws1.middle.earth" \
  -H "Content-Type: application/json" \
  -d '{
    "sshfp_l": [
      {
        "algorithm": 1,
        "hashtype": 1,
        "fingerprint": "494ec8a2e29172d45f8f60b205410c3a2f8b3e47",
        "comment": "RSA/SHA1 key"
      },
      {
        "algorithm": 4,
        "hashtype": 2,
        "fingerprint": "6b4b341a7c56e3a21f5e7b8d9c0a1e2f3b4c5d6e",
        "comment": "Ed25519/SHA256 key"
      }
    ]
  }' | jq .

# Update a host (add NS records)
curl -s -X PUT "$BASE/hosts/ws1.middle.earth" \
  -H "Content-Type: application/json" \
  -d '{
    "ns_l": [
      {"ns": "ns1.test.example.com", "comment": "Primary NS"},
      {"ns": "ns2.test.example.com"}
    ]
  }' | jq .

# Update a host (add MX records)
curl -s -X PUT "$BASE/hosts/ws1.middle.earth" \
  -H "Content-Type: application/json" \
  -d '{
    "mx_l": [
      {"pri": 10, "mx": "mail.test.example.com", "comment": "Primary MX"},
      {"pri": 20, "mx": "mail2.test.example.com"}
    ]
  }' | jq .

# Update a host (add SRV records)
curl -s -X PUT "$BASE/hosts/ws1.middle.earth" \
  -H "Content-Type: application/json" \
  -d '{
    "srv_l": [
      {"pri": 10, "weight": 60, "port": 5060, "target": "sip.test.example.com", "comment": "SIP"}
    ]
  }' | jq .

# Update a host (add TXT records)
curl -s -X PUT "$BASE/hosts/ws1.middle.earth" \
  -H "Content-Type: application/json" \
  -d '{
    "txt_l": [
      {"txt": "v=spf1 include:test.example.com ~all", "comment": "SPF record"}
    ]
  }' | jq .

# Update a host (add DS records)
curl -s -X PUT "$BASE/hosts/ws1.middle.earth" \
  -H "Content-Type: application/json" \
  -d '{
    "ds_l": [
      {"key_tag": 12345, "algorithm": 8, "digest_type": 2, "digest": "a1b2c3d4e5f6", "comment": "DNSSEC delegation"}
    ]
  }' | jq .

# Update a host (add WKS records)
curl -s -X PUT "$BASE/hosts/ws1.middle.earth" \
  -H "Content-Type: application/json" \
  -d '{
    "wks_l": [
      {"proto": "tcp", "services": "80 443", "comment": "HTTP/HTTPS"}
    ]
  }' | jq .

# Update a host (add TLSA records)
curl -s -X PUT "$BASE/hosts/ws1.middle.earth" \
  -H "Content-Type: application/json" \
  -d '{
    "tlsa_l": [
      {"usage": 3, "selector": 1, "matching_type": 1, "association_data": "abcdef123456", "comment": "DANE TLSA"}
    ]
  }' | jq .

# Update a host (add DHCP reservations)
curl -s -X PUT "$BASE/hosts/ws1.middle.earth" \
  -H "Content-Type: application/json" \
  -d '{
    "dhcp_l": [
      {"dhcp": "00:11:22:33:44:55", "comment": "Wired NIC"}
    ]
  }' | jq .

# Update a host (DHCPv6 reservations)
curl -s -X PUT "$BASE/hosts/ws1.middle.earth" \
  -H "Content-Type: application/json" \
  -d '{
    "dhcp_l6": [
      {"dhcp": "fe80::1", "comment": "Link-local"}
    ]
  }' | jq .

# Update a host (add printer records)
curl -s -X PUT "$BASE/hosts/ws1.middle.earth" \
  -H "Content-Type: application/json" \
  -d '{
    "printer_l": [
      {"printer": "LaserJet-4000", "comment": "Room 101"}
    ]
  }' | jq .

# Update a host (add subgroups)
curl -s -X PUT "$BASE/hosts/ws1.middle.earth" \
  -H "Content-Type: application/json" \
  -d '{
    "subgroups": [
      {"grp": 1}
    ]
  }' | jq .

# Update a host (combined scalar + array fields)
curl -s -X PUT "$BASE/hosts/ws1.middle.earth" \
  -H "Content-Type: application/json" \
  -d '{
    "ttl": 7200,
    "hinfo_hw": "x86_64",
    "hinfo_sw": "Debian 12",
    "location": "Data Center A",
    "sshfp_l": [
      {"algorithm": 1, "hashtype": 1, "fingerprint": "aabbccdd11223344", "comment": "RSA key"},
      {"algorithm": 4, "hashtype": 2, "fingerprint": "11223344aabbccdd", "comment": "Ed25519 key"}
    ],
    "txt_l": [
      {"txt": "v=spf1 mx -all", "comment": "SPF"}
    ]
  }' | jq .

# Delete a host
curl -s -X DELETE "$BASE/hosts/ws1.middle.earth" | jq .

# Error cases
# --------------------------------------------------

# Get non-existent host
curl -s "$BASE/hosts/nonexistent.test.example.com" | jq .

# Invalid FQDN
curl -s "$BASE/hosts/notanfqdn" | jq .

# Create duplicate host
curl -s -X POST "$BASE/hosts/ws1.middle.earth" \
  -H "Content-Type: application/json" \
  -d '{"type": 1}' | jq .
curl -s -X POST "$BASE/hosts/ws1.middle.earth" \
  -H "Content-Type: application/json" \
  -d '{"type": 1}' | jq .

# Update non-existent host
curl -s -X PUT "$BASE/hosts/gone.test.example.com" \
  -H "Content-Type: application/json" \
  -d '{"ttl": 600}' | jq .

# Type validation
# --------------------------------------------------

# Create a printer type (type=5) - should reject sshfp_l
curl -s -X POST "$BASE/hosts/printer1.test.example.com" \
  -H "Content-Type: application/json" \
  -d '{"type": 5, "sshfp_l": [{"algorithm": 1, "hashtype": 1, "fingerprint": "aabb"}]}' | jq .

# Create a host type (type=1) with sshfp - should succeed
curl -s -X POST "$BASE/hosts/ssh-host.test.example.com" \
  -H "Content-Type: application/json" \
  -d '{"type": 1, "sshfp_l": [{"algorithm": 4, "hashtype": 2, "fingerprint": "aabb"}]}' | jq .

# Update a host type with invalid printer_l - should fail (type=1 doesn't allow printer_l)
curl -s -X PUT "$BASE/hosts/ssh-host.test.example.com" \
  -H "Content-Type: application/json" \
  -d '{"printer_l": [{"printer": "HP"}]}' | jq .

# Create a delegation type (type=2) with ns - should succeed
curl -s -X POST "$BASE/hosts/delegation.test.example.com" \
  -H "Content-Type: application/json" \
  -d '{"type": 2, "ns_l": [{"ns": "ns1.example.com"}]}' | jq .

# Update delegation with invalid sshfp_l - should fail (type=2 doesn't allow sshfp_l)
curl -s -X PUT "$BASE/hosts/delegation.test.example.com" \
  -H "Content-Type: application/json" \
  -d '{"sshfp_l": [{"algorithm": 1, "hashtype": 1, "fingerprint": "aabb"}]}' | jq .

# Create an SRV type (type=8) - should succeed
curl -s -X POST "$BASE/hosts/_sip._tcp.test.example.com" \
  -H "Content-Type: application/json" \
  -d '{"type": 8, "srv_l": [{"pri": 10, "weight": 60, "port": 5060, "target": "sip.example.com"}]}' | jq .

# Create a TXT type (type=13) - should succeed
curl -s -X POST "$BASE/hosts/txtrec.test.example.com" \
  -H "Content-Type: application/json" \
  -d '{"type": 13, "txt_l": [{"txt": "v=spf1 mx -all"}]}' | jq .

# Cleanup
# --------------------------------------------------
# Delete test host and zone:
# curl -s -X DELETE "$BASE/hosts/ws1.middle.earth"
# curl -s -X DELETE "$BASE/servers/middle-earth/zones/test.example.com"
