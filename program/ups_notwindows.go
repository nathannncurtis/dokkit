//go:build !windows

package main

import (
	"os"
	"os/signal"
	"regexp"
	"strconv"
	"syscall"
	"time"
)

func batteryUPS(*hwFound) {}

var bootSec = regexp.MustCompile(`sec = (\d+)`)

func uptime() (time.Duration, bool) {
	if b, err := os.ReadFile("/proc/uptime"); err == nil {
		v, ok := firstNum(b)
		return time.Duration(v * float64(time.Second)), ok
	}
	out, err := runCmd("sysctl", "-n", "kern.boottime")
	if err != nil {
		return 0, false
	}
	m := bootSec.FindSubmatch(out)
	if m == nil {
		return 0, false
	}
	sec, _ := strconv.ParseInt(string(m[1]), 10, 64)
	return hwNow().Sub(time.Unix(sec, 0)), sec > 0
}

// stopCleanly marks a stop asked for by the system or a person, so the next boot is not taken for a power cut.
func stopCleanly(spool string) {
	ch := make(chan os.Signal, 1)
	signal.Notify(ch, syscall.SIGTERM, os.Interrupt)
	go func() {
		<-ch
		markClean(spool)
		os.Exit(0)
	}()
}
