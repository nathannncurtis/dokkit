package main

import (
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
)

var (
	batteryClass   = windows.GUID{Data1: 0x72631e54, Data2: 0x78a4, Data3: 0x11d0, Data4: [8]byte{0xbc, 0xf7, 0x00, 0xaa, 0x00, 0xb7, 0xb3, 0x2a}}
	getTickCount64 = windows.NewLazySystemDLL("kernel32.dll").NewProc("GetTickCount64")
)

const (
	ioctlBatteryQueryTag    = 0x294040
	ioctlBatteryQueryInfo   = 0x294044
	ioctlBatteryQueryStatus = 0x29404c
	batteryInformation      = 0
	batteryEstimatedTime    = 3
)

type batteryQueryInfo struct {
	tag   uint32
	level int32
	rate  int32
}

type batteryInfo struct {
	caps         uint32
	technology   uint8
	_            [3]uint8
	chemistry    [4]uint8
	designed     uint32
	full         uint32
	alert1       uint32
	alert2       uint32
	criticalBias uint32
	cycles       uint32
}

type batteryWaitStatus struct{ tag, timeout, state, low, high uint32 }

type batteryStatus struct {
	state, capacity, voltage uint32
	rate                     int32
}

// batteryUPS reads every battery Windows has a battery-class device for; a USB UPS is one.
func batteryUPS(f *hwFound) {
	paths, err := windows.CM_Get_Device_Interface_List("", &batteryClass, windows.CM_GET_DEVICE_INTERFACE_LIST_PRESENT)
	if err != nil {
		f.say("UPS: battery class: %v", err)
		return
	}
	var all []winBattery
	for _, p := range paths {
		if p == "" {
			continue
		}
		if b, ok := readBattery(p); ok {
			all = append(all, b)
		}
	}
	upsFromBatteries(all, f)
}

func readBattery(path string) (winBattery, bool) {
	name, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return winBattery{}, false
	}
	h, err := windows.CreateFile(name, windows.GENERIC_READ, windows.FILE_SHARE_READ|windows.FILE_SHARE_WRITE, nil, windows.OPEN_EXISTING, windows.FILE_ATTRIBUTE_NORMAL, 0)
	if err != nil {
		return winBattery{}, false
	}
	defer windows.CloseHandle(h)
	ioctl := func(code uint32, in unsafe.Pointer, inSize uintptr, out unsafe.Pointer, outSize uintptr) bool {
		var n uint32
		return windows.DeviceIoControl(h, code, (*byte)(in), uint32(inSize), (*byte)(out), uint32(outSize), &n, nil) == nil
	}
	var wait, tag uint32
	if !ioctl(ioctlBatteryQueryTag, unsafe.Pointer(&wait), 4, unsafe.Pointer(&tag), 4) || tag == 0 {
		return winBattery{}, false
	}
	q := batteryQueryInfo{tag: tag, level: batteryInformation}
	var info batteryInfo
	if !ioctl(ioctlBatteryQueryInfo, unsafe.Pointer(&q), unsafe.Sizeof(q), unsafe.Pointer(&info), unsafe.Sizeof(info)) {
		return winBattery{}, false
	}
	ws := batteryWaitStatus{tag: tag}
	var st batteryStatus
	if !ioctl(ioctlBatteryQueryStatus, unsafe.Pointer(&ws), unsafe.Sizeof(ws), unsafe.Pointer(&st), unsafe.Sizeof(st)) {
		return winBattery{}, false
	}
	seconds := uint32(batteryUnknown)
	q.level = batteryEstimatedTime
	if !ioctl(ioctlBatteryQueryInfo, unsafe.Pointer(&q), unsafe.Sizeof(q), unsafe.Pointer(&seconds), 4) {
		seconds = batteryUnknown
	}
	return winBattery{caps: info.caps, state: st.state, capacity: st.capacity, full: info.full, seconds: seconds}, true
}

// uptime counts sleep too, so a machine that slept is not taken for one that restarted.
func uptime() (time.Duration, bool) {
	ms, _, _ := getTickCount64.Call()
	return time.Duration(ms) * time.Millisecond, ms > 0
}

func stopCleanly(string) {}
