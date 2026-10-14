package main

import (
	"fmt"
	"strings"
)

// realPoke starts the updater's scheduled task. The task's security descriptor lets Local
// Service start it and nothing more.
func realPoke() (string, error) {
	if out, err := runTool("schtasks.exe", "/run", "/tn", taskName); err != nil {
		return "", fmt.Errorf("schtasks: %v %s", err, strings.TrimSpace(out))
	}
	return "Asked the updater to check now.\n", nil
}
