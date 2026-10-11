package main

import (
	"unsafe"

	"golang.org/x/sys/windows"
)

const systemProcessIdInformation = 0x58

type systemProcessID struct {
	ProcessID uintptr
	ImageName windows.NTUnicodeString
}

// listProcesses gives each process's image path in NT form (\Device\HarddiskVolumeN\...). A process whose path the system will not give has none.
func listProcesses() ([]proc, error) {
	var out []proc
	err := eachProcess(func(pid uint32, name string) { out = append(out, proc{name, imagePath(pid)}) })
	return out, err
}

func eachProcess(f func(pid uint32, name string)) error {
	snap, err := windows.CreateToolhelp32Snapshot(windows.TH32CS_SNAPPROCESS, 0)
	if err != nil {
		return err
	}
	defer windows.CloseHandle(snap)
	e := windows.ProcessEntry32{Size: uint32(unsafe.Sizeof(windows.ProcessEntry32{}))}
	for err = windows.Process32First(snap, &e); err == nil; err = windows.Process32Next(snap, &e) {
		f(e.ProcessID, windows.UTF16ToString(e.ExeFile[:]))
	}
	return nil
}

// imagePath asks the system for the path by process number, which needs no handle to the process and so works for other accounts' processes.
func imagePath(pid uint32) string {
	buf := make([]uint16, 512)
	for range 4 {
		info := systemProcessID{ProcessID: uintptr(pid)}
		info.ImageName.Buffer = &buf[0]
		info.ImageName.MaximumLength = uint16(len(buf) * 2)
		err := windows.NtQuerySystemInformation(systemProcessIdInformation, unsafe.Pointer(&info), uint32(unsafe.Sizeof(info)), nil)
		if err == nil {
			return info.ImageName.String()
		}
		if err != windows.STATUS_INFO_LENGTH_MISMATCH || int(info.ImageName.MaximumLength)/2 <= len(buf) {
			return ""
		}
		buf = make([]uint16, int(info.ImageName.MaximumLength)/2)
	}
	return ""
}

// handleImagePath is the call that is refused for other accounts' processes, kept to show the difference.
func handleImagePath(pid uint32) string {
	h, err := windows.OpenProcess(windows.PROCESS_QUERY_LIMITED_INFORMATION, false, pid)
	if err != nil {
		return ""
	}
	defer windows.CloseHandle(h)
	buf := make([]uint16, 32768)
	n := uint32(len(buf))
	if windows.QueryFullProcessImageName(h, 0, &buf[0], &n) != nil {
		return ""
	}
	return windows.UTF16ToString(buf[:n])
}
