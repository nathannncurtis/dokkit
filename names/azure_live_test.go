package main

import (
	"os"
	"testing"
)

// Runs against the real zone only with NAMES_AZURE_LIVE=1 and the AZURE_* settings the service uses.
func TestAzureLive(t *testing.T) {
	if os.Getenv("NAMES_AZURE_LIVE") != "1" {
		t.Skip("NAMES_AZURE_LIVE is not 1")
	}
	az := &Azure{API: "https://management.azure.com", Login: "https://login.microsoftonline.com",
		Tenant: os.Getenv("AZURE_TENANT"), ClientID: os.Getenv("AZURE_CLIENT_ID"), Secret: os.Getenv("AZURE_CLIENT_SECRET"),
		Subscription: os.Getenv("AZURE_SUBSCRIPTION"), Group: os.Getenv("AZURE_DNS_GROUP"), Zone: "dokkit.dev"}
	name := "names-selftest.dokkit.dev"
	a, err := az.Put("", "A", name, "192.0.2.10")
	if err != nil {
		t.Fatal(err)
	}
	if ok, err := az.Exists(name); err != nil || !ok {
		t.Fatalf("exists after put: %v %v", ok, err)
	}
	t1, err := az.Put("", "TXT", "_acme-challenge."+name, "first")
	if err != nil {
		t.Fatal(err)
	}
	t2, _ := az.Put("", "TXT", "_acme-challenge."+name, "second")
	if got, _ := az.get("TXT", "_acme-challenge.names-selftest"); len(got) != 2 {
		t.Fatalf("two challenge values expected, got %v", got)
	}
	for _, id := range []string{t1, t2, a} {
		if err := az.Delete(id); err != nil {
			t.Fatal(err)
		}
	}
	if ok, _ := az.Exists(name); ok {
		t.Fatal("still there after delete")
	}
}
