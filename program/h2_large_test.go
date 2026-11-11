package main

import (
	"io"
	"net/http"
	"os"
	"strconv"
	"testing"
)

// The server's test suite starts a Bandit server and runs this against it.
func TestLargeFileOverHTTP2(t *testing.T) {
	url, pin := os.Getenv("DOKKIT_H2_URL"), os.Getenv("DOKKIT_H2_PIN")
	if url == "" {
		t.Skip("run from the server's tests")
	}
	size, _ := strconv.Atoi(os.Getenv("DOKKIT_H2_SIZE"))
	c := &http.Client{Transport: newLink(pinConfig(pin), defaultLinkLimits)}
	for i := 0; i < 10; i++ {
		res, err := c.Get(url)
		if err != nil {
			t.Fatal(err)
		}
		n, err := io.Copy(io.Discard, res.Body)
		res.Body.Close()
		if res.ProtoMajor != 2 || err != nil || int(n) != size {
			t.Fatalf("download %d: proto %s, %d of %d bytes, err %v", i, res.Proto, n, size, err)
		}
	}
}
