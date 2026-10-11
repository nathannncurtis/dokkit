package main

import (
	"math"
	"os"
	"testing"
)

const vmStatReal = `Mach Virtual Memory Statistics: (page size of 16384 bytes)
Pages free:                                  2293866.
Pages active:                                 679382.
Pages inactive:                               976883.
Pages speculative:                             21940.
Pages throttled:                                   0.
Pages wired down:                             157966.
Pages purgeable:                               22500.
"Translation faults":                      643188111.
File-backed pages:                           1146407.
Anonymous pages:                              531798.
Pages stored in compressor:                    57560.
Pages occupied by compressor:                  30681.
Decompressions:                             24895409.
`

const topReal = `Processes: 785 total, 2 running, 783 sleeping, 3291 threads
Load Avg: 1.49, 1.60, 1.51
CPU usage: 1.16% user, 5.23% sys, 93.60% idle
PhysMem: 28G used (2469M wired, 479M compressor), 35G unused.


Processes: 785 total, 2 running, 783 sleeping, 3294 threads
Load Avg: 1.49, 1.60, 1.51
CPU usage: 0.12% user, 0.41% sys, 99.45% idle
PhysMem: 28G used (2469M wired, 479M compressor), 35G unused.
`

func TestMemoryFromVMStatLeavesOutTheFileCache(t *testing.T) {
	used, ok := memoryFromVMStat(vmStatReal, 68719476736)
	if !ok || math.Abs(used-16.64) > 0.01 {
		t.Fatalf("want 16.64, got %v %v", used, ok)
	}
	if _, ok := memoryFromVMStat("nothing", 68719476736); ok {
		t.Fatal("output that is not vm_stat gives no reading")
	}
	if _, ok := memoryFromVMStat(vmStatReal, 0); ok {
		t.Fatal("no memory size gives no reading")
	}
}

func TestIdleFromTopTakesTheLastSample(t *testing.T) {
	idle, ok := idleFromTop(topReal)
	if !ok || idle != 99.45 {
		t.Fatalf("want 99.45, got %v %v", idle, ok)
	}
	if _, ok := idleFromTop("CPU usage: broken"); ok {
		t.Fatal("a line with no idle figure gives no reading")
	}
}

func TestMacProcessorReadingsDifferToTheSampleBusyShare(t *testing.T) {
	was := runCmd
	defer func() { runCmd = was }()
	runCmd = func(string, ...string) ([]byte, error) { return []byte(topReal), nil }
	i1, t1, ok1 := macCPUTimes()
	i2, t2, ok2 := macCPUTimes()
	if !ok1 || !ok2 {
		t.Fatal("no reading")
	}
	if busy := 100 * (1 - float64(i2-i1)/float64(t2-t1)); math.Abs(busy-0.55) > 0.001 {
		t.Fatalf("want 0.55, got %v", busy)
	}
}

func TestPrintReadingsOnThisMachine(t *testing.T) {
	if os.Getenv("DOKKIT_PRINT_READINGS") == "" {
		t.Skip("set DOKKIT_PRINT_READINGS to print this machine's readings")
	}
	vitals()
	for _, l := range vitals() {
		t.Log(l)
	}
}
