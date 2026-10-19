// Command names hands out <name>.dokkit.dev to Dokkit servers and is the only writer of those DNS records.
package main

import (
	"log"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"
)

func env(key, fallback string) string {
	if v := strings.TrimSpace(os.Getenv(key)); v != "" {
		return v
	}
	return fallback
}

func main() {
	for _, k := range []string{"AZURE_TENANT", "AZURE_CLIENT_ID", "AZURE_CLIENT_SECRET", "AZURE_SUBSCRIPTION", "AZURE_DNS_GROUP"} {
		if os.Getenv(k) == "" {
			log.Fatalf("%s is not set", k)
		}
	}
	signins, err := configuredProviders()
	if err != nil {
		log.Fatal(err)
	}
	store, err := OpenStore(env("NAMES_STATE", "names.json"))
	if err != nil {
		log.Fatalf("state: %v", err)
	}
	max, err := strconv.Atoi(env("NAMES_MAX", "1000"))
	if err != nil || max < 1 {
		log.Fatalf("NAMES_MAX must be a whole number above 0")
	}
	svc := &Service{
		Store: store,
		DNS: &Azure{API: env("AZURE_API", "https://management.azure.com"), Login: env("AZURE_LOGIN", "https://login.microsoftonline.com"),
			Tenant: os.Getenv("AZURE_TENANT"), ClientID: os.Getenv("AZURE_CLIENT_ID"), Secret: os.Getenv("AZURE_CLIENT_SECRET"),
			Subscription: os.Getenv("AZURE_SUBSCRIPTION"), Group: os.Getenv("AZURE_DNS_GROUP"), Zone: env("NAMES_ZONE", "dokkit.dev")},
		Zone:     env("NAMES_ZONE", "dokkit.dev"),
		Max:      max,
		Reserved: map[string]bool{},
		Now:      time.Now,
	}
	for _, w := range append(reserved, strings.Fields(strings.ToLower(strings.ReplaceAll(os.Getenv("NAMES_RESERVED"), ",", " ")))...) {
		svc.Reserved[w] = true
	}
	app := &App{
		Svc:     svc,
		Base:    strings.TrimRight(env("NAMES_BASE_URL", "https://names.dokkit.dev"), "/"),
		Signins: signins,
		Abuse:   env("NAMES_ABUSE_EMAIL", "abuse@dokkit.dev"),
		Secret:  []byte(store.s.Secret),
	}
	go func() {
		for {
			svc.Sweep()
			time.Sleep(time.Hour)
		}
	}()
	srv := &http.Server{
		Addr:              env("NAMES_ADDR", "127.0.0.1:8080"),
		Handler:           app.Routes(),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       60 * time.Second,
		MaxHeaderBytes:    8 << 10,
	}
	log.Printf("listening on %s", srv.Addr)
	log.Fatal(srv.ListenAndServe())
}
