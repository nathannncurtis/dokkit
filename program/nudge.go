package main

import (
	"encoding/json"
	"errors"
)

const nudgeWork = "dokkit:nudge"

var errNoNudge = errors.New("this machine has no way to start its updater early, so it updates on its next scheduled check")

// pokeUpdater asks the machine's updater to check now. It starts nothing itself and needs no
// rights: it only touches what the updater's own schedule watches. Tests replace it.
var pokeUpdater = realPoke

// nudge is a built-in run. It takes no parameters and installs nothing.
func (c *client) nudge(run string) {
	said, err := pokeUpdater()
	if err != nil && !errors.Is(err, errNoNudge) {
		body, _ := json.Marshal(map[string]string{"refused": "Could not ask the updater to check: " + err.Error()})
		c.postResult("/api/v1/work/"+run+"/result", body)
		return
	}
	if err != nil {
		said = err.Error() + "\n"
	}
	c.call("POST", "/api/v1/work/"+run+"/output", "text/plain", []byte(said), nil)
	c.postResult("/api/v1/work/"+run+"/result", []byte(`{"exit_code":0,"duration_ms":0}`))
}
