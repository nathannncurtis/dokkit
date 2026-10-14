package main

import (
	"encoding/json"
	"fmt"
	"os"
	"slices"
	"time"
)

const (
	taskListFile  = "tasks.json"
	taskListEvery = time.Hour
	taskListFresh = 2 * time.Hour
)

const (
	noteTasksFromUpdater = "This account may read only some of the machine's scheduled tasks, so they are the list the updater wrote at %s, plus any this account reads that the list lacks. The updater runs as the system account and writes it at most once an hour, so the last run times and results may be that old."
	noteTasksStale       = "Scheduled tasks are only those this account may read: the updater's list, written at %s, is more than two hours old and was not used. The full list could not be read; check that the updater is running."
	noteTasksNoList      = "Scheduled tasks are only those this account may read. The full list could not be read: no list from the updater could be found (the updater, which runs as the system account and writes one for this program, is not installed or has not written it yet). Install the updater, or run the scan from an administrator prompt."
)

// taskList is the file the updater leaves in the program's data folder: the output of
// schtasks /query /fo csv /v as the system account sees it.
type taskList struct {
	At       string   `json:"at"`
	Schtasks []string `json:"schtasks"`
}

func readTaskList(file string) (l taskList, err error) {
	b, err := os.ReadFile(file)
	if err == nil {
		err = json.Unmarshal(b, &l)
	}
	return l, err
}

// publishTaskList writes the list when the file is missing or older than an hour and the list differs from it.
func publishTaskList(file string, at time.Time, list func() ([]string, error)) error {
	old, _ := readTaskList(file)
	if t, err := time.Parse(time.RFC3339, old.At); err == nil && at.Sub(t) < taskListEvery {
		return nil
	}
	lines, err := list()
	if err != nil || len(lines) == 0 {
		return fmt.Errorf("the list of scheduled tasks could not be read: %v", err)
	}
	if slices.Equal(lines, old.Schtasks) {
		return nil
	}
	b, _ := json.Marshal(taskList{At: at.UTC().Format(time.RFC3339), Schtasks: lines})
	return writeFile(file, b)
}

// tasksFromFile merges the updater's list, when it is fresh, with what this account listed itself.
// The updater's entry wins for a task in both.
func tasksFromFile(file string, live []found, offset int, now time.Time) ([]found, string) {
	l, err := readTaskList(file)
	if err != nil || l.At == "" {
		return live, noteTasksNoList
	}
	at, err := time.Parse(time.RFC3339, l.At)
	if err != nil || now.Sub(at) > taskListFresh {
		return live, fmt.Sprintf(noteTasksStale, l.At)
	}
	jobs := parseSchtasks(l.Schtasks, offset)
	seen := map[string]bool{}
	for _, j := range jobs {
		seen[j["unit"]] = true
	}
	for _, j := range live {
		if !seen[j["unit"]] {
			jobs = append(jobs, j)
		}
	}
	return jobs, fmt.Sprintf(noteTasksFromUpdater, l.At)
}
