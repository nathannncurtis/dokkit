//go:build !windows && !linux

package main

import "testing"

const psCapture = `    1     0  12000  1-02:03:04 root             /sbin/launchd
  412     1   5200     0:01.25 nathan           /Applications/Some App.app/Contents/MacOS/Some App
  500   412    300    12:34.56 _windowserver    kernel_task
`

func TestPsOutputIsRead(t *testing.T) {
	rows := parsePs(psCapture)
	if len(rows) != 3 {
		t.Fatalf("%d rows", len(rows))
	}
	if r := rows[0]; r.pid != 1 || r.memory != 12000<<10 || r.cpu != (86400+2*3600+3*60+4)*100 || r.user != "root" || r.name != "launchd" || r.path != "/sbin/launchd" {
		t.Fatalf("%+v", rows[0])
	}
	if r := rows[1]; r.name != "Some App" || r.path != "/Applications/Some App.app/Contents/MacOS/Some App" || r.cpu != 125 || r.ppid != 1 {
		t.Fatalf("%+v", r)
	}
	if r := rows[2]; r.path != "" || r.cpu != (12*60+34)*100+56 {
		t.Fatalf("%+v", r)
	}
}
