//go:build windows

package main

import (
	"unsafe"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/registry"
)

// winServiceFacts reads the service's ImagePath and, below Parameters, the NSSM application or the DLL a service host loads. Both keys are readable without administrator rights.
func winServiceFacts(name string) (image, real string) {
	k, err := registry.OpenKey(registry.LOCAL_MACHINE, `SYSTEM\CurrentControlSet\Services\`+name, registry.QUERY_VALUE)
	if err != nil {
		return "", ""
	}
	defer k.Close()
	image, _, _ = k.GetStringValue("ImagePath")
	if p, err := registry.OpenKey(k, "Parameters", registry.QUERY_VALUE); err == nil {
		defer p.Close()
		if real, _, _ = p.GetStringValue("Application"); real == "" {
			real, _, _ = p.GetStringValue("ServiceDll")
		}
	}
	return image, real
}

// processPath is the program file of a process, read without opening it so other accounts' processes have one too.
func processPath(pid uint32) string {
	d := &driveMap{build: queryDrives}
	d.refresh()
	return d.dos(imagePath(pid))
}

func parentPids() map[uint32]uint32 {
	parents := map[uint32]uint32{}
	snap, err := windows.CreateToolhelp32Snapshot(windows.TH32CS_SNAPPROCESS, 0)
	if err != nil {
		return parents
	}
	defer windows.CloseHandle(snap)
	var e windows.ProcessEntry32
	e.Size = uint32(unsafe.Sizeof(e))
	for err := windows.Process32First(snap, &e); err == nil; err = windows.Process32Next(snap, &e) {
		parents[e.ProcessID] = e.ParentProcessID
	}
	return parents
}
