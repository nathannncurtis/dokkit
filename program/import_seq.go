package main

import (
	"bytes"
	"crypto/sha1"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

const (
	importBatch    = 1000
	importWindow   = time.Hour
	importMaxEmpty = 30 * 24 * time.Hour
	importHold     = 20000
	importPage     = 1000
)

// The server turns a line a year or more old into one stamped with its arrival.
var importLive = 364 * 24 * time.Hour

type seqEvent struct {
	ID         string
	Timestamp  string
	Level      string
	Rendered   string `json:"RenderedMessage"`
	Exception  string
	Properties []struct {
		Name  string
		Value any
	}
	Tokens []struct{ Text, RawText string } `json:"MessageTemplateTokens"`
	at     time.Time
}

type importTarget struct {
	Service string `json:"service"`
	Key     string `json:"key"`
}

type seqImport struct {
	from, seqKey, to, defKey, defService string
	props                                []string
	targets                              map[string]importTarget
	pattern                              *regexp.Regexp
	filter, state                        string
	since, until                         time.Time
	rate                                 float64
	dry                                  bool
	now                                  time.Time
	seq, dokkit                          *http.Client
	out                                  io.Writer
	sent, skipped, old, unmapped         int
	perService                           map[string]int
	perMonth                             map[string]int
	oldMonth                             map[string]int
	names                                map[string]int
}

type importState struct {
	From string `json:"from"`
	Time string `json:"time"`
	ID   string `json:"id"`
}

func importCommand(args []string) int {
	if len(args) == 0 || args[0] != "seq" {
		fmt.Fprintln(os.Stderr, "dokkit: import takes seq. dokkit help import says how.")
		return 2
	}
	im, err := parseSeqImport(args[1:], os.Stdout)
	if err != nil {
		fmt.Fprintln(os.Stderr, "dokkit:", err)
		return 2
	}
	if err := im.run(); err != nil {
		fmt.Fprintln(os.Stderr, "dokkit:", err)
		return 1
	}
	return 0
}

func parseSeqImport(args []string, out io.Writer) (*seqImport, error) {
	fs := flag.NewFlagSet("import seq", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	im := &seqImport{out: out, now: time.Now().UTC(), perService: map[string]int{}, perMonth: map[string]int{}, oldMonth: map[string]int{}, names: map[string]int{}}
	var props, mapFile, pattern, since, until string
	fs.StringVar(&im.from, "from", "", "")
	fs.StringVar(&im.seqKey, "seq-key", os.Getenv("SEQ_API_KEY"), "")
	fs.StringVar(&im.to, "to", os.Getenv("DOKKIT_URL"), "")
	fs.StringVar(&im.defKey, "key", os.Getenv("DOKKIT_KEY"), "")
	fs.StringVar(&im.defService, "default-service", "", "")
	fs.StringVar(&props, "service-property", "Application", "")
	fs.StringVar(&mapFile, "map", "", "")
	fs.StringVar(&pattern, "app-pattern", "", "")
	fs.StringVar(&im.filter, "filter", "", "")
	fs.StringVar(&im.state, "state", "", "")
	fs.StringVar(&since, "since", "2014-01-01T00:00:00Z", "")
	fs.StringVar(&until, "until", "", "")
	fs.Float64Var(&im.rate, "rate", 200, "")
	fs.BoolVar(&im.dry, "dry-run", false, "")
	if err := fs.Parse(args); err != nil {
		return nil, err
	}
	if im.from == "" {
		return nil, errors.New("import seq needs --from, the address of the Seq server")
	}
	im.from = strings.TrimRight(im.from, "/")
	im.to = strings.TrimRight(im.to, "/")
	if !im.dry && im.to == "" {
		return nil, errors.New("import seq needs --to or DOKKIT_URL, the address of the Dokkit server")
	}
	t, err := time.Parse(time.RFC3339, since)
	if err != nil {
		return nil, errors.New("--since must be an RFC 3339 time")
	}
	im.since = t.UTC()
	if until != "" {
		if t, err = time.Parse(time.RFC3339, until); err != nil {
			return nil, errors.New("--until must be an RFC 3339 time")
		}
		im.until = t.UTC()
	}
	im.props = strings.FieldsFunc(props, func(r rune) bool { return r == ',' || r == ' ' })
	if pattern != "" {
		if im.pattern, err = regexp.Compile(pattern); err != nil || im.pattern.NumSubexp() < 1 {
			return nil, errors.New("--app-pattern must be a regular expression with one group around the name")
		}
	}
	if mapFile != "" {
		raw, err := os.ReadFile(mapFile)
		if err == nil {
			err = json.Unmarshal(raw, &im.targets)
		}
		if err != nil {
			return nil, fmt.Errorf("--map: %v", err)
		}
		for k, v := range im.targets {
			im.targets[strings.ToLower(k)] = v
		}
	}
	if im.state == "" {
		im.state = "dokkit-import-seq-" + sanitize(im.from) + ".json"
	}
	im.seq = &http.Client{Timeout: 5 * time.Minute}
	im.dokkit = &http.Client{Timeout: time.Minute, Transport: toServer}
	return im, nil
}

func sanitize(s string) string {
	return strings.Trim(regexp.MustCompile(`[^A-Za-z0-9]+`).ReplaceAllString(s, "-"), "-")
}

func (im *seqImport) run() error {
	var last importState
	if raw, err := os.ReadFile(im.state); err == nil && !im.dry {
		if json.Unmarshal(raw, &last) != nil || last.From != im.from {
			return fmt.Errorf("%s was written for another source; use --state for a file of its own", im.state)
		}
	}
	start := im.since
	if t, err := time.Parse(time.RFC3339Nano, last.Time); err == nil && t.After(start) {
		start = t.Truncate(time.Hour)
	}
	window := importWindow
	stop := im.now
	if !im.until.IsZero() && im.until.Before(stop) {
		stop = im.until
	}
	for start.Before(stop) {
		end := start.Add(window)
		events, over, err := im.window(start, end)
		if err != nil {
			return err
		}
		if over && window > time.Minute {
			window /= 2
			continue
		}
		if err := im.handle(events, &last); err != nil {
			return err
		}
		start = end
		if len(events) == 0 {
			window = min(window*2, importMaxEmpty)
		} else {
			window = importWindow
		}
	}
	im.report()
	return nil
}

// window reads every event with a time in [from, to), newest first, and returns them oldest first.
func (im *seqImport) window(from, to time.Time) ([]seqEvent, bool, error) {
	var all []seqEvent
	seen := map[string]bool{}
	after := ""
	for {
		q := url.Values{"count": {strconv.Itoa(importPage)}, "render": {"true"},
			"fromDateUtc": {from.Format(time.RFC3339Nano)}, "toDateUtc": {to.Format(time.RFC3339Nano)}}
		if after != "" {
			q.Set("afterId", after)
		}
		if im.filter != "" {
			q.Set("filter", im.filter)
		}
		req, _ := http.NewRequest("GET", im.from+"/api/events?"+q.Encode(), nil)
		if im.seqKey != "" {
			req.Header.Set("X-Seq-ApiKey", im.seqKey)
		}
		res, err := im.seq.Do(req)
		if err != nil {
			return nil, false, err
		}
		body, _ := io.ReadAll(res.Body)
		res.Body.Close()
		if res.StatusCode != 200 {
			return nil, false, fmt.Errorf("Seq answered %d to the read; it needs a key that may read (--seq-key)", res.StatusCode)
		}
		var page []seqEvent
		if err := json.Unmarshal(body, &page); err != nil {
			return nil, false, fmt.Errorf("Seq's answer is not a list of events: %v", err)
		}
		fresh := 0
		for _, e := range page {
			if !seen[e.ID] {
				seen[e.ID] = true
				fresh++
				all = append(all, e)
			}
		}
		if fresh == 0 {
			break
		}
		after = page[len(page)-1].ID
		if len(all) > importHold && to.Sub(from) > time.Minute {
			return nil, true, nil
		}
	}
	for i := range all {
		t, err := time.Parse(time.RFC3339Nano, all[i].Timestamp)
		if err != nil {
			return nil, false, fmt.Errorf("event %s has no readable time", all[i].ID)
		}
		all[i].at = t.UTC()
	}
	sort.SliceStable(all, func(i, j int) bool {
		if !all[i].at.Equal(all[j].at) {
			return all[i].at.Before(all[j].at)
		}
		return all[i].ID < all[j].ID
	})
	return all, false, nil
}

func (im *seqImport) handle(events []seqEvent, last *importState) error {
	var lt time.Time
	if t, err := time.Parse(time.RFC3339Nano, last.Time); err == nil {
		lt = t
	}
	var todo []seqEvent
	for _, e := range events {
		if !lt.IsZero() && (e.at.Before(lt) || e.at.Equal(lt) && e.ID <= last.ID) {
			continue
		}
		todo = append(todo, e)
	}
	for len(todo) > 0 {
		n := min(len(todo), importBatch)
		chunk := todo[:n]
		todo = todo[n:]
		if err := im.send(chunk); err != nil {
			return err
		}
		tail := chunk[n-1]
		*last = importState{From: im.from, Time: tail.at.Format(time.RFC3339Nano), ID: tail.ID}
		if !im.dry {
			raw, _ := json.Marshal(last)
			if err := os.WriteFile(im.state, raw, 0o600); err != nil {
				return err
			}
		}
	}
	return nil
}

// route says which service an event belongs to and the value it was found under.
func (im *seqImport) route(e seqEvent) (name, found string) {
	for _, p := range im.props {
		for _, prop := range e.Properties {
			if prop.Name == p {
				if s, ok := prop.Value.(string); ok && s != "" {
					return s, s
				}
			}
		}
	}
	if im.pattern != nil {
		if m := im.pattern.FindStringSubmatch(e.message()); m != nil && m[1] != "" {
			return m[1], m[1]
		}
	}
	return "", ""
}

func (e seqEvent) message() string {
	if e.Rendered != "" {
		return e.Rendered
	}
	var b strings.Builder
	for _, t := range e.Tokens {
		if t.Text != "" {
			b.WriteString(t.Text)
		} else {
			b.WriteString(t.RawText)
		}
	}
	return b.String()
}

var seqLevels = func() map[string]string {
	m := map[string]string{"": "info"}
	for level, names := range map[string]string{
		"trace": "verbose vrb v silly trace trc", "debug": "debug dbg d", "info": "information info inf i",
		"warn": "warning warn wrn w", "error": "error err e", "fatal": "fatal ftl f critical crit",
	} {
		for _, n := range strings.Fields(names) {
			m[n] = level
		}
	}
	return m
}()

func (im *seqImport) line(e seqEvent, found string) map[string]any {
	fields := map[string]any{}
	for _, p := range e.Properties {
		fields[p.Name] = p.Value
	}
	if e.Exception != "" {
		fields["exception"] = e.Exception
	}
	if found != "" {
		fields["service_name"] = found
	}
	level := seqLevels[strings.ToLower(e.Level)]
	if level == "" {
		level = "info"
	}
	return map[string]any{"type": "log", "t": e.at.Format(time.RFC3339Nano), "level": level, "msg": e.message(), "fields": fields}
}

func (im *seqImport) send(events []seqEvent) error {
	groups := map[string][]map[string]any{}
	first := map[string]string{}
	order := []string{}
	for _, e := range events {
		month := e.at.Format("2006-01")
		name, found := im.route(e)
		target, ok := im.targets[strings.ToLower(name)]
		if !ok {
			target = importTarget{Service: im.defService, Key: im.defKey}
			if name != "" {
				im.names[name]++
			}
			if im.defService == "" && im.defKey == "" {
				im.unmapped++
				continue
			}
		}
		label := target.Service
		if label == "" {
			label = "(default)"
		}
		if im.now.Sub(e.at) > importLive {
			im.old++
			im.oldMonth[month]++
			continue
		}
		im.perService[label]++
		im.perMonth[month]++
		im.sent++
		if im.dry {
			continue
		}
		if target.Key == "" {
			return fmt.Errorf("no app key for %q; give one in --map or with --key", label)
		}
		if _, ok := groups[target.Key]; !ok {
			order = append(order, target.Key)
			first[target.Key] = e.ID
		}
		if name != "" && ok {
			found = ""
		}
		groups[target.Key] = append(groups[target.Key], im.line(e, found))
	}
	for _, key := range order {
		if err := im.post(key, first[key], groups[key]); err != nil {
			return err
		}
	}
	return nil
}

func (im *seqImport) post(key, firstID string, lines []map[string]any) error {
	var body bytes.Buffer
	for _, l := range lines {
		raw, _ := json.Marshal(l)
		body.Write(raw)
		body.WriteByte('\n')
	}
	started := time.Now()
	for attempt := 0; ; attempt++ {
		req, _ := http.NewRequest("POST", im.to+"/api/v1/report", bytes.NewReader(body.Bytes()))
		req.Header.Set("Authorization", "Bearer "+key)
		req.Header.Set("Dokkit-Batch", batchID(im.from, key, firstID, len(lines)))
		res, err := im.dokkit.Do(req)
		if err != nil {
			if attempt >= 5 {
				return err
			}
			time.Sleep(time.Duration(attempt+1) * 2 * time.Second)
			continue
		}
		answer, _ := io.ReadAll(res.Body)
		res.Body.Close()
		switch {
		case res.StatusCode == 429:
			wait, _ := strconv.Atoi(res.Header.Get("Retry-After"))
			time.Sleep(time.Duration(max(wait, 1)) * time.Second)
			continue
		case res.StatusCode >= 500 && attempt < 5:
			time.Sleep(time.Duration(attempt+1) * 2 * time.Second)
			continue
		case res.StatusCode != 200:
			return fmt.Errorf("the Dokkit server answered %d: %s", res.StatusCode, strings.TrimSpace(string(answer)))
		}
		var a struct {
			Refused []struct{ Message string } `json:"refused"`
		}
		json.Unmarshal(answer, &a)
		im.skipped += len(a.Refused)
		break
	}
	if im.rate > 0 {
		pause := time.Duration(float64(len(lines))/im.rate*float64(time.Second)) - time.Since(started)
		if pause > 0 {
			time.Sleep(pause)
		}
	}
	return nil
}

func batchID(from, key, first string, n int) string {
	h := sha1.Sum([]byte(from + "\x00" + key + "\x00" + first + "\x00" + strconv.Itoa(n)))
	h[6] = h[6]&0x0f | 0x50
	h[8] = h[8]&0x3f | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", h[0:4], h[4:6], h[6:8], h[8:10], h[10:16])
}

func (im *seqImport) report() {
	verb := "Imported"
	if im.dry {
		verb = "Would import"
	}
	fmt.Fprintf(im.out, "%s %d events.\n", verb, im.sent)
	table := func(title string, m map[string]int) {
		if len(m) == 0 {
			return
		}
		keys := make([]string, 0, len(m))
		for k := range m {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		fmt.Fprintln(im.out, title)
		for _, k := range keys {
			fmt.Fprintf(im.out, "  %-32s %d\n", k, m[k])
		}
	}
	table("By service:", im.perService)
	table("By month:", im.perMonth)
	table("App names with no entry in --map, sent to the default service:", im.names)
	if im.old > 0 {
		fmt.Fprintf(im.out, "Not imported, more than 364 days old (Dokkit stamps a line that old with its arrival time): %d events.\n", im.old)
		table("  By month:", im.oldMonth)
	}
	if im.unmapped > 0 {
		fmt.Fprintf(im.out, "Not imported, no service to put them in (give --default-service and --key, or --map): %d events.\n", im.unmapped)
	}
	if im.skipped > 0 {
		fmt.Fprintf(im.out, "Refused by the server: %d events.\n", im.skipped)
	}
}
