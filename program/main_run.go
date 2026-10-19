//go:build !js

package main

import "os"

func main() {
	if !asService() {
		os.Exit(cli(os.Args[1:]))
	}
}
