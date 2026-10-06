package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// What one pass sends from one file. The server takes 10,000 lines and 5 MB a batch.
const (
	logChunk = 1 << 20
	logLines = 5000
)

// tail sends the new whole lines of every file named under [logs]. A position only moves
// once the server has the lines, so a line can arrive twice and never goes missing.
func (w *watcher) tail() {
	moved := false
	w.c.http.Timeout = 20 * time.Second
	for _, d := range w.files {
		if d.Logs.Path == "" {
			continue
		}
		pattern := d.Logs.Path
		if !filepath.IsAbs(pattern) {
			pattern = filepath.Join(filepath.Dir(d.path), pattern)
		}
		files, _ := filepath.Glob(pattern)
		for _, f := range files {
			moved = w.c.sendLog(d.Service.ID, f, w.logs) || moved
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
// A file is known by its first line, so it is followed through a rename.
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
	key := hex.EncodeToString(sum[:16])
	pos := positions[key]
	if info, err := f.Stat(); err != nil || info.Size() < pos {
		pos = 0
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
	var body bytes.Buffer
	used, count := 0, 0
	for used < end && count < logLines {
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
		body.Write(j)
		body.WriteByte('\n')
		count++
	}
	used = min(used, end)
	if count > 0 {
		// The same lines from the same machine always carry the same batch id, so a resend is not stored twice.
		batch := sha256.Sum256(append([]byte(c.key+"\n"+key+"\n"+strconv.FormatInt(pos, 10)+"\n"), buf[:used]...))
		status, answer, err := c.post(uuid(batch[:16]), body.Bytes())
		at := key + ":" + strconv.FormatInt(pos, 10)
		switch {
		case err != nil:
			return false
		case status/100 == 2:
			refused(answer)
			delete(c.stuck, at)
		case status == 413 || status == 422:
		case status == 500 && c.giveUp(at):
			delete(c.stuck, at)
			msg := fmt.Sprintf("the server keeps answering %d to the lines of %s (bytes %d to %d), skipping them", status, path, pos, pos+int64(used))
			fmt.Fprintln(os.Stderr, "dokkit:", msg)
			c.report(map[string]any{"type": "log", "t": now(), "level": "warn", "msg": "dokkit: " + msg})
		default:
			return false
		}
	}
	positions[key] = pos + int64(used)
	return used > 0
}
