package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"
)

const nudgeWork = "dokkit:nudge"

var errNoNudge = errors.New("this machine has no way to start its updater early, so it updates on its next scheduled check")

// pokeUpdater asks the machine's updater to check now. It starts nothing itself and needs no
// rights: it only touches what the updater's own schedule watches. Tests replace it.
var pokeUpdater = realPoke

var nudgeLog = func(said string) {
	fmt.Println(time.Now().Format("15:04:05"), "", "update nudge:", strings.Join(strings.Fields(said), " "))
}

// nudge is a built-in run. It takes no parameters and installs nothing.
func (c *client) nudge(run string) {
	said, err := pokeUpdater()
	if err != nil && !errors.Is(err, errNoNudge) {
		why := "Could not ask the updater to check: " + err.Error()
		nudgeLog(why)
		body, _ := json.Marshal(map[string]string{"refused": why})
		c.postResult("/api/v1/work/"+run+"/result", body)
		return
	}
	if err != nil {
		said = err.Error() + "\n"
	}
	nudgeLog(said)
	c.call("POST", "/api/v1/work/"+run+"/output", "text/plain", []byte(said), nil)
	c.postResult("/api/v1/work/"+run+"/result", []byte(`{"exit_code":0,"duration_ms":0}`))
}
