//go:build darwin

package main

import (
	"fmt"
	"os"
	"testing"
)

func TestRealMacPorts(t *testing.T) {
	if os.Getenv("DOKKIT_REAL_PORTS") == "" {
		t.Skip("set DOKKIT_REAL_PORTS to run")
	}
	all := findPorts()
	fmt.Println("ports found:", len(all), "note:", portsNote)
	for i, f := range all {
		if i == 5 {
			break
		}
		fmt.Println(f)
	}
	if len(all) == 0 {
		t.Fatal("no ports found")
	}
}
