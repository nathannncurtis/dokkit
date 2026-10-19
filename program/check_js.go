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
	b, _ := json.Marshal(checkResult(text))
	return string(b)
}
