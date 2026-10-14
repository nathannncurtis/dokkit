package main

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func writeList(t *testing.T, at time.Time) string {
	file := filepath.Join(t.TempDir(), taskListFile)
	csv := lines(t, "testdata/schtasks.csv")
	if err := publishTaskList(file, at, func() ([]string, error) { return csv, nil }); err != nil {
		t.Fatal(err)
	}
	return file
}

func TestAFreshListIsMergedByPathAndTheUpdaterWins(t *testing.T) {
	at := time.Date(2026, 10, 12, 20, 0, 0, 0, time.UTC)
	file := writeList(t, at)
	csv := parseSchtasks(lines(t, "testdata/schtasks.csv"), -240)
	both := found{"name": csv[0]["name"], "unit": csv[0]["unit"], "last_result": "from the live listing"}
	only := found{"name": "Only live", "unit": `\Only live`}
	jobs, note := tasksFromFile(file, []found{both, only}, -240, at.Add(119*time.Minute))
	if len(jobs) != len(csv)+1 {
		t.Fatalf("%d jobs", len(jobs))
	}
	if j := byName(jobs, csv[0]["name"]); j["last_result"] == "from the live listing" || j["schedule"] != csv[0]["schedule"] {
		t.Fatalf("the live entry won: %v", j)
	}
	if byName(jobs, "Only live") == nil {
		t.Fatal("a task only the live listing has was dropped")
	}
	if !strings.Contains(note, "2026-10-12T20:00:00Z") || !strings.Contains(note, "updater") {
		t.Fatal(note)
	}
}

func TestAListOlderThanTwoHoursIsIgnoredAndSaidSo(t *testing.T) {
	at := time.Date(2026, 10, 12, 20, 0, 0, 0, time.UTC)
	file := writeList(t, at)
	live := []found{{"name": "Only live", "unit": `\Only live`}}
	jobs, note := tasksFromFile(file, live, 0, at.Add(121*time.Minute))
	if len(jobs) != 1 || jobs[0]["name"] != "Only live" {
		t.Fatalf("%v", jobs)
	}
	if !strings.Contains(note, "2026-10-12T20:00:00Z") || !strings.Contains(note, "could not be read") {
		t.Fatal(note)
	}
}

func TestAMissingOrBrokenListLeavesTheLiveListingAndSaysSo(t *testing.T) {
	dir := t.TempDir()
	live := []found{{"name": "Only live", "unit": `\Only live`}}
	for _, content := range []string{"", "not json", "{}"} {
		file := filepath.Join(dir, taskListFile)
		os.Remove(file)
		if content != "" {
			os.WriteFile(file, []byte(content), 0o600)
		}
		jobs, note := tasksFromFile(file, live, 0, time.Now())
		if len(jobs) != 1 || note != noteTasksNoList {
			t.Fatalf("%q: %v %q", content, jobs, note)
		}
	}
}

func TestTheListIsWrittenAtMostHourlyAndOnlyWhenItChanged(t *testing.T) {
	file := filepath.Join(t.TempDir(), taskListFile)
	calls, current := 0, []string{"a"}
	list := func() ([]string, error) { calls++; return current, nil }
	t0 := time.Date(2026, 10, 12, 20, 0, 0, 0, time.UTC)
	step := func(at time.Time) {
		if err := publishTaskList(file, at, list); err != nil {
			t.Fatal(err)
		}
	}
	read := func() taskList { l, _ := readTaskList(file); return l }

	step(t0)
	if calls != 1 || read().At != "2026-10-12T20:00:00Z" {
		t.Fatalf("first: %d %v", calls, read())
	}
	current = []string{"b"}
	step(t0.Add(59 * time.Minute))
	if calls != 1 || read().Schtasks[0] != "a" {
		t.Fatalf("inside the hour it listed or wrote: %d %v", calls, read())
	}
	step(t0.Add(61 * time.Minute))
	if calls != 2 || read().Schtasks[0] != "b" || read().At != "2026-10-12T21:01:00Z" {
		t.Fatalf("changed after an hour: %d %v", calls, read())
	}
	step(t0.Add(3 * time.Hour))
	if calls != 3 || read().At != "2026-10-12T21:01:00Z" {
		t.Fatalf("unchanged list was written again: %d %v", calls, read())
	}
}

func TestAFailedListingLeavesTheOldFileAlone(t *testing.T) {
	file := filepath.Join(t.TempDir(), taskListFile)
	t0 := time.Date(2026, 10, 12, 20, 0, 0, 0, time.UTC)
	publishTaskList(file, t0, func() ([]string, error) { return []string{"a"}, nil })
	err := publishTaskList(file, t0.Add(2*time.Hour), func() ([]string, error) { return []string{""}, errors.New("no") })
	if err == nil {
		t.Fatal("no error")
	}
	if l, _ := readTaskList(file); l.Schtasks[0] != "a" {
		t.Fatal(l)
	}
}
