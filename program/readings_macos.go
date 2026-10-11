package main

import (
	"regexp"
	"strconv"
	"strings"
)

var (
	vmPageSize = regexp.MustCompile(`page size of (\d+) bytes`)
	topIdle    = regexp.MustCompile(`CPU usage:.*?([0-9.]+)% idle`)
)

// memoryFromVMStat is the percent of memory in use as Activity Monitor counts it: app memory
// (anonymous pages less purgeable ones), wired memory and the compressor. File cache is not used.
func memoryFromVMStat(out string, memsize float64) (float64, bool) {
	m := vmPageSize.FindStringSubmatch(out)
	if m == nil || memsize <= 0 {
		return 0, false
	}
	page, _ := strconv.ParseFloat(m[1], 64)
	pages := map[string]float64{}
	for _, l := range strings.Split(out, "\n") {
		if name, v, ok := strings.Cut(l, ":"); ok {
			pages[name], _ = strconv.ParseFloat(strings.TrimSuffix(strings.TrimSpace(v), "."), 64)
		}
	}
	for _, k := range []string{"Anonymous pages", "Pages purgeable", "Pages wired down", "Pages occupied by compressor"} {
		if _, ok := pages[k]; !ok {
			return 0, false
		}
	}
	used := pages["Anonymous pages"] - pages["Pages purgeable"] + pages["Pages wired down"] + pages["Pages occupied by compressor"]
	return 100 * used * page / memsize, true
}

// idleFromTop is the idle percent of the last sample in the output of top -l 2.
func idleFromTop(out string) (float64, bool) {
	all := topIdle.FindAllStringSubmatch(out, -1)
	if len(all) == 0 {
		return 0, false
	}
	idle, err := strconv.ParseFloat(all[len(all)-1][1], 64)
	return idle, err == nil && idle <= 100
}

// macIdle and macTotal count hundredths of a percent, one sample of 10000 for each reading, so
// the difference between two readings is the idle share of the sample.
var macIdle, macTotal uint64

func macMemoryUsed() (float64, bool) {
	size, err := runCmd("sysctl", "-n", "hw.memsize")
	if err != nil {
		return 0, false
	}
	total, _ := strconv.ParseFloat(strings.TrimSpace(string(size)), 64)
	out, err := runCmd("vm_stat")
	if err != nil {
		return 0, false
	}
	return memoryFromVMStat(string(out), total)
}

func macCPUTimes() (uint64, uint64, bool) {
	out, err := runCmd("top", "-l", "2", "-n", "0", "-s", "2")
	if err != nil {
		return 0, 0, false
	}
	idle, ok := idleFromTop(string(out))
	if !ok {
		return 0, 0, false
	}
	macIdle += uint64(idle*100 + 0.5)
	macTotal += 10000
	return macIdle, macTotal, true
}
