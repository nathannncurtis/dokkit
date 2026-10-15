package main

import (
	"errors"
	"fmt"
	"math"
	"net/url"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
)

var (
	serviceKinds = []string{"service", "job", "dependency", "app"}
	serviceID    = regexp.MustCompile(`^[a-z0-9][a-z0-9._-]*$`)
)

// validate holds what the server refuses at declare, in its order and with its words, and
// what this program refuses about the files and addresses it reads itself.
func (d *declaration) validate() error {
	if !serviceID.MatchString(d.Service.ID) {
		return errors.New("service.id may hold lower-case letters, digits, dots, dashes and underscores.")
	}
	if about, _ := d.raw["service"].(map[string]any); about != nil {
		if k, ok := about["kind"]; ok && !slicesHas(serviceKinds, k) {
			return errors.New("service.kind is one of " + strings.Join(serviceKinds, ", ") + ".")
		}
	}
	jobs, _ := d.raw["job"].([]map[string]any)
	for _, j := range jobs {
		if _, ok := j["id"].(string); !ok {
			return errors.New("Every job needs an id.")
		}
	}
	for _, j := range jobs {
		if s, ok := j["schedule"]; ok {
			if str, _ := s.(string); cronReads(str) != nil {
				return errors.New("A job's schedule is not a cron line Dokkit can read. Five fields read as UTC, for example 0 1 * * *; @reboot has no time.")
			}
		}
	}
	checks, _ := d.raw["check"].([]map[string]any)
	for _, c := range checks {
		if f, ok := c["fail_after"]; ok {
			if n, isInt := f.(int64); !isInt || n < 1 || n > 100 {
				return errors.New("fail_after is a whole number from 1 to 100.")
			}
		}
	}
	return nil
}

// misplaced is what `dokkit check` refuses beyond the server's rules. watch keeps such a file and
// reports the part that cannot work, so one bad key_env or log path does not stop its checks.
func (d *declaration) misplaced() error {
	if k := d.Stats.KeyEnv; k != "" && !strings.HasPrefix(k, statsKeyPrefix) {
		return errors.New("key_env must name a variable that starts with " + statsKeyPrefix)
	}
	if s := d.Stats.URL; s != "" {
		if u, err := url.Parse(s); err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
			return fmt.Errorf("stats.url %q is not an http or https address", s)
		}
	}
	if p := d.Logs.Path; p != "" && !insideFolder(filepath.Dir(d.path), p) {
		return fmt.Errorf("logs.path %q must stay inside the folder of its dokkit.toml", p)
	}
	return nil
}

// statusRanges reads status = 200, "200-299", or a list of those, as inclusive ranges of 100 to 599.
func statusRanges(v any) ([][2]int, error) {
	bad := fmt.Errorf("status is a code such as 200, a range such as \"200-299\", or a list of those, from 100 to 599")
	one := func(x any) ([2]int, error) {
		switch x := x.(type) {
		case int64:
			if x >= 100 && x <= 599 {
				return [2]int{int(x), int(x)}, nil
			}
		case float64:
			if x == math.Trunc(x) && x >= 100 && x <= 599 {
				return [2]int{int(x), int(x)}, nil
			}
		case string:
			lo, hi, isRange := strings.Cut(strings.TrimSpace(x), "-")
			a, err1 := strconv.Atoi(strings.TrimSpace(lo))
			b, err2 := a, error(nil)
			if isRange {
				b, err2 = strconv.Atoi(strings.TrimSpace(hi))
			}
			if err1 == nil && err2 == nil && a >= 100 && b <= 599 && a <= b {
				return [2]int{a, b}, nil
			}
		}
		return [2]int{}, bad
	}
	if v == nil {
		return nil, nil
	}
	list, ok := v.([]any)
	if !ok {
		list = []any{v}
	}
	var out [][2]int
	for _, x := range list {
		r, err := one(x)
		if err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	if len(out) == 0 {
		return nil, bad
	}
	return out, nil
}

func slicesHas(list []string, v any) bool {
	s, ok := v.(string)
	if !ok {
		return false
	}
	for _, x := range list {
		if x == s {
			return true
		}
	}
	return false
}

// insideFolder is the part of within that needs no files: a pattern that names its way out is refused whether or not it matches.
func insideFolder(dir, pattern string) bool {
	if !filepath.IsAbs(pattern) {
		pattern = filepath.Join(dir, pattern)
	}
	rel, err := filepath.Rel(filepath.Clean(dir), filepath.Clean(pattern))
	return err == nil && rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator)) && !filepath.IsAbs(rel)
}

var cronAliases = map[string]bool{"yearly": true, "annually": true, "monthly": true, "weekly": true, "daily": true, "midnight": true, "hourly": true, "minutely": true}

var (
	cronMonths   = map[string]int{"JAN": 1, "FEB": 2, "MAR": 3, "APR": 4, "MAY": 5, "JUN": 6, "JUL": 7, "AUG": 8, "SEP": 9, "OCT": 10, "NOV": 11, "DEC": 12}
	cronWeekdays = map[string]int{"MON": 1, "TUE": 2, "WED": 3, "THU": 4, "FRI": 5, "SAT": 6, "SUN": 7}
)

// cronReads is nil for a schedule the server can work out a next run for: five fields, or a named
// one such as @daily. @reboot is a time of no clock and is refused.
func cronReads(s string) error {
	if strings.HasPrefix(s, "@") {
		if cronAliases[strings.ToLower(s[1:])] {
			return nil
		}
		return fmt.Errorf("%s has no time", s)
	}
	fields := strings.Split(s, " ")
	if len(fields) != 5 {
		return errors.New("a cron line has five fields")
	}
	for i, f := range fields {
		for _, part := range strings.Split(f, ",") {
			if err := cronPart(i, part); err != nil {
				return err
			}
		}
	}
	return nil
}

func cronPart(field int, part string) error {
	if part == "*" {
		return nil
	}
	if base, step, ok := strings.Cut(part, "/"); ok {
		if n, err := strconv.Atoi(step); err != nil || n <= 0 || strings.Contains(step, "/") {
			return fmt.Errorf("%q is not a step", step)
		}
		if base == "*" {
			return nil
		}
		return cronRangeOrValue(field, base)
	}
	return cronRangeOrValue(field, part)
}

func cronRangeOrValue(field int, part string) error {
	if lo, hi, ok := strings.Cut(part, "-"); ok && lo != "" && hi != "" && !strings.Contains(hi, "-") {
		if err := cronValue(field, lo); err != nil {
			return err
		}
		return cronValue(field, hi)
	}
	return cronValue(field, part)
}

func cronValue(field int, v string) error {
	within := func(s string, lo, hi int) error {
		if n, err := strconv.Atoi(s); err != nil || n < lo || n > hi {
			return fmt.Errorf("%q is out of range", v)
		}
		return nil
	}
	switch field {
	case 0:
		return within(v, 0, 59)
	case 1:
		return within(v, 0, 23)
	case 2:
		if v == "L" || v == "LW" {
			return nil
		}
		return within(strings.TrimSuffix(v, "W"), 1, 31)
	case 3:
		if _, ok := cronMonths[strings.ToUpper(v)]; ok || v == "L" {
			return nil
		}
		return within(v, 1, 12)
	}
	weekday := func(s string) error {
		if _, ok := cronWeekdays[strings.ToUpper(s)]; ok {
			return nil
		}
		return within(s, 0, 7)
	}
	switch {
	case v == "L":
		return nil
	case strings.HasSuffix(v, "L"):
		return weekday(strings.TrimSuffix(v, "L"))
	case strings.Contains(v, "#"):
		day, n, _ := strings.Cut(v, "#")
		if _, err := strconv.Atoi(n); err != nil {
			return fmt.Errorf("%q is not a weekday of the month", v)
		}
		return weekday(day)
	}
	return weekday(v)
}
