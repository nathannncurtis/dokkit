package main

import (
	"reflect"
	"strings"
	"testing"
)

const lsofSample = `p101
cnginx
Lroot
n*:443
n[::]:443
p202
cpostgres
Lpostgres
n127.0.0.1:5432
p303
ccontrolcenter
Lnathan
n10.0.0.5:8443
n127.0.0.1:8443
p404
cnode
Lnathan
n10.0.0.5:3000
n10.0.0.6:3000
p505
cbun
Lnathan
n*:3000
p606
ccupsd
Lroot
n[::1]:631
nbroken line
n*:notaport
`

func TestLsofPortsAreReadLikeLinuxOnes(t *testing.T) {
	var all []found
	seen := map[string]int{}
	add := func(local, program string, owner func() (string, string)) {
		address, port := listenAddress(local)
		if i, ok := seen[port+program]; ok {
			if addressRank(address) < addressRank(all[i]["address"]) {
				all[i]["address"] = address
			}
			return
		}
		seen[port+program] = len(all)
		all = append(all, found{"port": port, "program": program, "address": address})
	}
	lsofPorts(strings.Split(lsofSample, "\n"), add)
	var got [][3]string
	for _, f := range all {
		got = append(got, [3]string{f["port"], f["program"], f["address"]})
	}
	want := [][3]string{
		{"443", "nginx", "*"},
		{"5432", "postgres", "127.0.0.1"},
		{"8443", "controlcenter", "127.0.0.1"},
		{"3000", "node", "10.0.0.5"},
		{"3000", "bun", "*"},
		{"631", "cupsd", "::1"},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("%v", got)
	}
}

func TestLsofPortsKeepSpecificAddress(t *testing.T) {
	var got []string
	lsofPorts([]string{"p1", "cweb", "n10.0.0.5:8443"}, func(local, program string, owner func() (string, string)) {
		a, p := listenAddress(local)
		got = append(got, a+"|"+p+"|"+program)
	})
	if !reflect.DeepEqual(got, []string{"10.0.0.5|8443|web"}) {
		t.Fatalf("%v", got)
	}
}
