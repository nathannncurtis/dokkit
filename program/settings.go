package main

import (
	"sync/atomic"
	"time"
)

// setting is a duration the server may change while other goroutines read it.
type setting struct{ n atomic.Int64 }

func newSetting(d time.Duration) *setting { s := &setting{}; s.n.Store(int64(d)); return s }
func (s *setting) get() time.Duration     { return time.Duration(s.n.Load()) }
func (s *setting) set(d time.Duration)    { s.n.Store(int64(d)) }

var (
	checkEvery   = newSetting(30 * time.Second)
	checkTimeout = newSetting(5 * time.Second)
	restartGap   = newSetting(10 * time.Minute)
	expiryWarn   = newSetting(30 * 24 * time.Hour)
)

// serverSettings is the settings block of GET /api/v1/checks; a missing or zero value keeps what is in use.
type serverSettings struct {
	ReportSeconds       int64 `json:"report_seconds"`
	ScanFirstSeconds    int64 `json:"scan_first_seconds"`
	ScanEverySeconds    int64 `json:"scan_every_seconds"`
	CheckEverySeconds   int64 `json:"check_every_seconds"`
	CheckTimeoutSeconds int64 `json:"check_timeout_seconds"`
	ExpiryDays          int64 `json:"expiry_days"`
	RestartGapSeconds   int64 `json:"restart_gap_seconds"`
}

func (s serverSettings) apply() {
	for _, p := range []struct {
		n    int64
		unit time.Duration
		to   []*setting
	}{
		{s.ReportSeconds, time.Second, []*setting{beatEvery, recordEvery}},
		{s.ScanFirstSeconds, time.Second, []*setting{scanFirst}},
		{s.ScanEverySeconds, time.Second, []*setting{scanEvery}},
		{s.CheckEverySeconds, time.Second, []*setting{checkEvery}},
		{s.CheckTimeoutSeconds, time.Second, []*setting{checkTimeout}},
		{s.ExpiryDays, 24 * time.Hour, []*setting{expiryWarn}},
		{s.RestartGapSeconds, time.Second, []*setting{restartGap}},
	} {
		if p.n > 0 {
			for _, to := range p.to {
				to.set(time.Duration(p.n) * p.unit)
			}
		}
	}
}
