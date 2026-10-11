package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"maps"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"time"
)

// What one pass sends from one file. The server takes 10,000 lines and 5 MB a batch.
const (
	logChunk = 1 << 20
	logLines = 5000
	// The most of a message or of a line's fields the server keeps.
	logMsgMax = 64 << 10
)

// tail sends the new whole lines of every file named under [logs]. A position only moves
// once the server has the lines, so a line can arrive twice and never goes missing.
func (w *watcher) tail() {
	moved := false
	c := w.c
	if w.logc != nil {
		c = w.logc
	}
	c.http.Timeout = 20 * time.Second
	w.mu.Lock()
	declared := slices.Collect(maps.Values(w.files))
	w.mu.Unlock()
	for _, d := range declared {
		if d.Logs.Path == "" {
			continue
		}
		dir, pattern := filepath.Dir(d.path), d.Logs.Path
		if !filepath.IsAbs(pattern) {
			pattern = filepath.Join(dir, pattern)
		}
		files, _ := filepath.Glob(pattern)
		for _, f := range files {
			if within(dir, f) {
				moved = c.sendLog(d.Service.ID, f, w.logs) || moved
			}
		}
	}
	if moved || w.unsaved {
		// Positions of files that are gone stay: one number a file, and a folder that is
		// away for a moment must not make every line arrive again.
		b, _ := json.Marshal(w.logs)
		w.unsaved = writeFile(filepath.Join(w.c.spool, "logs.json"), b) != nil
	}
}

// sendLog sends what is new in one file and says whether its position moved.
// A file is known by its first line and its own identity (inode, or volume and file index), so
// it is followed through a rename and two files that start alike are told apart. A position
// saved under the first line alone is taken over by the first file that starts with that line.
func (c *client) sendLog(service, path string, positions map[string]int64) bool {
	f, err := os.Open(path)
	if err != nil {
		return false
	}
	defer f.Close()
	first := make([]byte, 1024)
	n, _ := io.ReadFull(f, first)
	if i := bytes.IndexByte(first[:n], '\n'); i >= 0 {
		first = first[:i]
	} else if n < len(first) {
		return false
	}
	sum := sha256.Sum256(first)
	old := hex.EncodeToString(sum[:16])
	sum = sha256.Sum256(append(append(first[:len(first):len(first)], 0), fileIdentity(f)...))
	key := hex.EncodeToString(sum[:16])
	pos, known := positions[key]
	oldPos, hadOld := positions[old]
	migrate := !known && hadOld
	if migrate {
		pos = oldPos
	}
	if info, err := f.Stat(); err != nil || info.Size() < pos {
		pos = 0
	}
	at := key + ":" + strconv.FormatInt(pos, 10)
	if s := c.stuck[at]; s != nil && time.Now().Before(s.until) {
		return false
	}

	buf := make([]byte, logChunk)
	n, _ = f.ReadAt(buf, pos)
	end := bytes.LastIndexByte(buf[:n], '\n') + 1
	if end == 0 {
		if n < logChunk {
			return false
		}
		// A line longer than a chunk is sent in pieces.
		end = n
	}
	var entries []entry
	used := 0
	for used < end && len(entries) < logLines {
		start := used
		raw := buf[used:end]
		if i := bytes.IndexByte(raw, '\n'); i >= 0 {
			raw = raw[:i]
		}
		used += len(raw) + 1
		if raw = bytes.TrimSpace(raw); len(raw) == 0 {
			continue
		}
		var l map[string]any
		if json.Unmarshal(raw, &l) != nil || l == nil {
			l = map[string]any{"t": now(), "level": "info", "msg": strings.ToValidUTF8(string(raw), "")}
		}
		_, clef := l["@t"]
		if _, ok := l["@m"]; ok {
			clef = true
		}
		if _, ok := l["@mt"]; ok {
			clef = true
		}
		if _, ok := l["msg"].(string); !ok && !clef {
			l["msg"] = strings.ToValidUTF8(string(raw), "")
			for _, k := range []string{"message", "event"} {
				if m, ok := l[k].(string); ok {
					l["msg"] = m
					break
				}
			}
		}
		l["type"] = "log"
		// The file's service owns the line; one of its own is kept as a field.
		if own, named := l["service"]; named {
			if clef {
				l["service_name"] = own
			} else {
				fields, ok := l["fields"].(map[string]any)
				if !ok {
					fields = map[string]any{}
					if l["fields"] != nil {
						fields["fields"] = l["fields"]
					}
				}
				fields["service"], l["fields"] = own, fields
			}
		}
		l["service"] = service
		j, _ := json.Marshal(l)
		entries = append(entries, entry{line: j, raw: buf[start : start+len(raw)], end: min(used, end)})
	}
	used = min(used, end)
	if len(entries) > 0 {
		// The same lines from the same machine always carry the same batch id, so a resend is not stored twice.
		id := func(sub []entry, _ bool) string {
			h := sha256.New()
			fmt.Fprintf(h, "%s\n%s\n%d\n", c.key, key, pos)
			for _, e := range sub {
				h.Write(e.raw)
				h.Write([]byte{'\n'})
			}
			return uuid(h.Sum(nil)[:16])
		}
		done, lost, stop := c.deliver(entries, id)
		c.noteLoss(path, lost)
		used = 0
		if done == len(entries) {
			used = min(entries[done-1].end+trailingBlank(buf[entries[done-1].end:end]), end)
		} else if done > 0 {
			used = entries[done-1].end
		}
		if stop != nil {
			c.backOff(at)
			if used == 0 {
				return false
			}
		} else {
			delete(c.stuck, at)
		}
	}
	positions[key] = pos + int64(used)
	if migrate {
		delete(positions, old)
	}
	return used > 0
}

// trailingBlank is how many bytes of b are blank lines, so a position can pass them.
func trailingBlank(b []byte) int {
	n := 0
	for len(b) > 0 {
		i := bytes.IndexByte(b, '\n')
		if i < 0 || len(bytes.TrimSpace(b[:i])) > 0 {
			break
		}
		n += i + 1
		b = b[i+1:]
	}
	return n
}

// backOff makes the next try at the same lines wait longer each time the server fails them.
func (c *client) backOff(at string) {
	if c.stuck == nil {
		c.stuck = map[string]*stuck{}
	}
	s := c.stuck[at]
	if s == nil {
		s = &stuck{since: time.Now()}
		c.stuck[at] = s
	}
	if s.n++; s.n > 1 {
		s.until = time.Now().Add(min(5*time.Second<<min(s.n-2, 6), 5*time.Minute))
	}
}

// An entry is one line of a batch: what is sent, what it was in the file, and where the file is after it.
type entry struct {
	line, raw []byte
	end       int
	gone, cut bool
}

// What a delivery could not do for lines: cut to the limit, or set aside with the reason.
type loss struct{ cut, aside int }

// httpStatus is a server answer that stopped a delivery.
type httpStatus int

func (s httpStatus) Error() string { return fmt.Sprintf("the server answered %d", int(s)) }

// deliver sends lines in order and returns how many leading ones are finished. A batch the server
// finds too large is halved down to one line; a line it names as refused, or the one line left in a
// batch it will not parse, is set aside. Any other answer stops it where it is.
func (c *client) deliver(es []entry, id func([]entry, bool) string) (int, loss, error) {
	var lost loss
	var aside []asideLine
	defer func() { c.setAside(aside) }()
	i, size := 0, len(es)
	for i < len(es) {
		n := min(size, len(es)-i)
		var live []int
		for j := i; j < i+n; j++ {
			if !es[j].gone {
				live = append(live, j)
			}
		}
		if len(live) == 0 {
			i += n
			continue
		}
		var body bytes.Buffer
		var sub []entry
		for _, j := range live {
			body.Write(es[j].line)
			body.WriteByte('\n')
			sub = append(sub, es[j])
		}
		status, answer, err := c.post(id(sub, len(live) == len(es)), body.Bytes())
		if err != nil {
			return i, lost, err
		}
		named := refusedLines(answer, len(live))
		take := func(k int, reason string) {
			aside = append(aside, asideLine{reason, es[live[k]].line})
			es[live[k]].gone = true
			lost.aside++
		}
		switch {
		case status/100 == 2:
			refused(answer)
			for _, r := range named {
				take(r.Line-1, r.Code+": "+r.Message)
			}
			i += n
		case status == 413 && len(live) > 1:
			size = max(n/2, 1)
		case status == 413:
			e := &es[live[0]]
			if cut, ok := cutLine(e.line); !e.cut && ok {
				e.line, e.cut = cut, true
				lost.cut++
			} else {
				take(0, "too large for the server")
			}
		case status == 422 && len(named) > 0:
			for _, r := range named {
				take(r.Line-1, r.Code+": "+r.Message)
			}
		case status == 422 && len(live) > 1:
			size = max(n/2, 1)
		case status == 422:
			take(0, "refused: "+strings.TrimSpace(string(answer)))
		default:
			return i, lost, httpStatus(status)
		}
	}
	return len(es), lost, nil
}

type lineRefusal struct {
	Line          int
	Code, Message string
}

// refusedLines are the lines of a batch of n that the server's answer names, once each.
func refusedLines(answer []byte, n int) []lineRefusal {
	var a struct{ Refused []lineRefusal }
	json.Unmarshal(answer, &a)
	var out []lineRefusal
	seen := map[int]bool{}
	for _, r := range a.Refused {
		if r.Line >= 1 && r.Line <= n && !seen[r.Line] {
			seen[r.Line] = true
			out = append(out, r)
		}
	}
	return out
}

// cutLine shortens a log line to what the server keeps, with a marker, and says whether it got smaller.
func cutLine(line []byte) ([]byte, bool) {
	var l map[string]any
	if json.Unmarshal(line, &l) != nil {
		return line, false
	}
	for _, k := range []string{"msg", "@m"} {
		if m, ok := l[k].(string); ok && len(m) > logMsgMax {
			l[k] = strings.ToValidUTF8(m[:logMsgMax], "") + fmt.Sprintf(" [dokkit cut %d bytes]", len(m)-logMsgMax)
		}
	}
	if f, err := json.Marshal(l["fields"]); err == nil && len(f) > logMsgMax {
		delete(l, "fields")
	}
	j, _ := json.Marshal(l)
	return j, len(j) < len(line)
}

type asideLine struct {
	reason string
	line   []byte
}

// setAside keeps lines the server will not take where the spool keeps set-aside batches.
func (c *client) setAside(lines []asideLine) {
	if len(lines) == 0 {
		return
	}
	var b bytes.Buffer
	for _, l := range lines {
		var v any = json.RawMessage(l.line)
		if !json.Valid(l.line) {
			v = string(l.line)
		}
		j, _ := json.Marshal(map[string]any{"reason": l.reason, "line": v})
		b.Write(j)
		b.WriteByte('\n')
	}
	name := fmt.Sprintf("%020d-%s.ndjson.rejected", time.Now().UnixNano(), id())
	if err := writeFile(filepath.Join(c.spool, name), b.Bytes()); err != nil {
		fmt.Fprintln(os.Stderr, "dokkit: could not write to the spool:", err)
	}
}

// noteLoss says on the console and to the server what was cut or set aside.
func (c *client) noteLoss(what string, l loss) {
	var msgs []string
	if l.cut > 0 {
		msgs = append(msgs, fmt.Sprintf("%d line(s) of %s cut to %d bytes of message because the server would not take them whole", l.cut, what, logMsgMax))
	}
	if l.aside > 0 {
		msgs = append(msgs, fmt.Sprintf("%d line(s) of %s set aside in the spool as .rejected because the server will not take them", l.aside, what))
	}
	for _, msg := range msgs {
		fmt.Fprintln(os.Stderr, "dokkit:", msg)
		c.report(map[string]any{"type": "log", "t": now(), "level": "warn", "msg": "dokkit: " + msg})
	}
}
