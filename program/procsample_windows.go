package main

import (
	"encoding/binary"
	"errors"
	"strings"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
)

const systemProcessInformation = 5

// Offsets in SYSTEM_PROCESS_INFORMATION on 64-bit Windows.
const (
	spiNext       = 0
	spiPrivateWS  = 8
	spiUserTime   = 40
	spiKernelTime = 48
	spiCreateTime = 32
	spiImageName  = 56
	spiPid        = 80
	spiPpid       = 88
	spiSession    = 100
	spiWorkingSet = 144
	spiMinimum    = 152
)

var (
	querySystem = windows.NtQuerySystemInformation
	processBuf  = make([]byte, 1<<19)
)

// readProcesses asks the system once for its process list, the call Task Manager makes. No process is opened.
func readProcesses() (rows []procRow, machine, memory uint64, err error) {
	n, err := queryProcesses()
	if err != nil {
		return nil, 0, 0, err
	}
	drives.refresh()
	rows = parseProcesses(processBuf[:n])
	for i := range rows {
		if rows[i].pid != 0 {
			rows[i].path = drives.dos(imagePath(uint32(rows[i].pid)))
		}
	}
	_, machine, _ = cpuTimes()
	var m struct {
		length, load uint32
		rest         [7]uint64
	}
	m.length = uint32(unsafe.Sizeof(m))
	memoryCall.Call(uintptr(unsafe.Pointer(&m)))
	return rows, machine, m.rest[0], nil
}

// queryProcesses fills processBuf, doubling it while the system says it is too small, and keeps it for the next look.
func queryProcesses() (int, error) {
	for range 8 {
		var need uint32
		err := querySystem(systemProcessInformation, unsafe.Pointer(&processBuf[0]), uint32(len(processBuf)), &need)
		if err == nil {
			return min(int(need), len(processBuf)), nil
		}
		if err != windows.STATUS_INFO_LENGTH_MISMATCH {
			return 0, err
		}
		processBuf = make([]byte, max(2*len(processBuf), int(need)))
	}
	return 0, errors.New("the process list kept growing")
}

// parseProcesses walks the entries by NextEntryOffset. The image names are read from inside the buffer, which is where the system puts them.
func parseProcesses(b []byte) (rows []procRow) {
	base := uintptr(unsafe.Pointer(&b[0]))
	u32 := func(o int) uint32 { return binary.LittleEndian.Uint32(b[o:]) }
	u64 := func(o int) uint64 { return binary.LittleEndian.Uint64(b[o:]) }
	for o := 0; o+spiMinimum <= len(b); {
		r := procRow{
			pid:    int(u64(o + spiPid)),
			ppid:   int(u64(o + spiPpid)),
			memory: u64(o + spiPrivateWS),
			cpu:    u64(o+spiUserTime) + u64(o+spiKernelTime),
			start:  u64(o + spiCreateTime),
		}
		if r.memory == 0 {
			r.memory = u64(o + spiWorkingSet)
		}
		s := int(u32(o + spiSession))
		r.session = &s
		if n, p := int(binary.LittleEndian.Uint16(b[o+spiImageName:])), uintptr(u64(o+spiImageName+8)); n > 0 && p >= base && int(p-base)+n <= len(b) {
			from := b[int(p-base) : int(p-base)+n]
			u := make([]uint16, n/2)
			for i := range u {
				u[i] = binary.LittleEndian.Uint16(from[2*i:])
			}
			r.name = windows.UTF16ToString(u)
		}
		switch {
		case r.name != "":
		case r.pid == 0:
			r.name = "System Idle Process"
		case r.pid == 4:
			r.name = "System"
		default:
			r.name = "unknown"
		}
		rows = append(rows, r)
		next := int(u32(o + spiNext))
		if next == 0 {
			break
		}
		o += next
	}
	return
}

// driveMap turns NT device paths into drive-letter paths. It is rebuilt at most once a minute, and once more in a look when a path's device is not in it.
type driveMap struct {
	build   func() map[string]string
	devices map[string]string
	built   time.Time
	missed  bool
}

var drives = &driveMap{build: queryDrives}

// queryDrives asks for the device behind each drive letter; no process is opened.
func queryDrives() map[string]string {
	m := map[string]string{}
	mask, _ := windows.GetLogicalDrives()
	buf := make([]uint16, 1024)
	for i := range 26 {
		if mask&(1<<i) == 0 {
			continue
		}
		letter := string(rune('A'+i)) + ":"
		name, _ := windows.UTF16PtrFromString(letter)
		if n, err := windows.QueryDosDevice(name, &buf[0], uint32(len(buf))); err == nil && n > 0 {
			m[strings.ToLower(windows.UTF16ToString(buf))] = letter
		}
	}
	return m
}

func (d *driveMap) refresh() {
	d.missed = false
	if d.devices == nil || time.Since(d.built) >= time.Minute {
		d.devices, d.built = d.build(), time.Now()
	}
}

func (d *driveMap) dos(nt string) string {
	rest, ok := strings.CutPrefix(nt, `\Device\`)
	if !ok {
		return nt
	}
	dev, tail, _ := strings.Cut(rest, `\`)
	key := strings.ToLower(`\Device\` + dev)
	letter, found := d.devices[key]
	if !found && !d.missed {
		d.missed = true
		d.devices, d.built = d.build(), time.Now()
		letter, found = d.devices[key]
	}
	if !found {
		return nt
	}
	if tail == "" {
		return letter
	}
	return letter + `\` + tail
}
