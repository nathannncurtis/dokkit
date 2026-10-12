package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"
)

// quiet tells the server this machine is going down on purpose, or that the wait is over.
// The spool goes first, so the server's last view of the machine is current.
func (c *client) quiet(args []string) int {
	body := map[string]string{"for": "0"}
	if !(len(args) == 1 && args[0] == "end") {
		if len(args) == 0 {
			fmt.Fprintln(os.Stderr, "dokkit: quiet needs a length, such as 15m, or end.")
			return 2
		}
		body = map[string]string{"for": args[0], "reason": strings.Join(args[1:], " ")}
	}
	c.flush(15 * time.Second)
	b, _ := json.Marshal(body)
	c.http.Timeout = 15 * time.Second
	req, _ := http.NewRequest("POST", c.url+"/api/v1/quiet", bytes.NewReader(b))
	req.Header.Set("Authorization", "Bearer "+c.key)
	req.Header.Set("Content-Type", "application/json")
	res, err := c.http.Do(req)
	if err != nil {
		what, todo := explainReach(err, c.url)
		fmt.Fprintln(os.Stderr, "dokkit: the server was not told. "+what+" To fix: "+todo)
		return 1
	}
	defer res.Body.Close()
	answer, _ := io.ReadAll(io.LimitReader(res.Body, 1<<16))
	if res.StatusCode != 200 {
		var e struct{ Error struct{ Message string } }
		json.Unmarshal(answer, &e)
		if e.Error.Message == "" {
			what, _ := explainStatus(res.StatusCode)
			e.Error.Message = what
		}
		fmt.Fprintf(os.Stderr, "dokkit: the server did not accept it (%d): %s\n", res.StatusCode, e.Error.Message)
		return 1
	}
	var a struct{ Until *time.Time }
	json.Unmarshal(answer, &a)
	if a.Until == nil {
		fmt.Println("Told the server this machine's planned downtime is over.")
	} else {
		fmt.Printf("Told the server this machine is down on purpose until %s UTC.\n", a.Until.UTC().Format("15:04"))
	}
	return 0
}
