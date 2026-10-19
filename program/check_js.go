package main

import (
	"encoding/json"
	"syscall/js"
)

// In a browser the program is only `dokkit check` without running the checks: dokkitCheck(text) answers JSON.
// GOOS=js GOARCH=wasm go build -trimpath -ldflags "-s -w" -o ../gallery/brand/check.wasm .
func main() {
	js.Global().Set("dokkitCheck", js.FuncOf(func(_ js.Value, args []js.Value) any {
		return checkText(args[0].String())
	}))
	select {}
}

func checkText(text string) string {
	out := map[string]any{"ok": false}
	d, err := parseDeclaration("dokkit.toml", text)
	if err == nil {
		err = d.misplaced()
	}
	if err != nil {
		out["error"] = err.Error()
		b, _ := json.Marshal(out)
		return string(b)
	}
	checks := []map[string]any{}
	for i := range d.Check {
		c := &d.Check[i]
		runs, _ := c.problem()
		checks = append(checks, map[string]any{"name": c.name, "type": c.Type, "target": c.target(), "runs": runs, "every": c.every().String()})
	}
	jobs := []string{}
	for _, j := range d.Job {
		jobs = append(jobs, j.ID)
	}
	out["ok"], out["service"], out["checks"], out["jobs"], out["logs"], out["sends"] = true, d.Service.ID, checks, jobs, d.Logs.Path, d.raw
	b, _ := json.Marshal(out)
	return string(b)
}
