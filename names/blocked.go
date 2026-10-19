package main

import "strings"

// Words no name may contain anywhere, even inside a longer word.
var blockedAnywhere = strings.Fields(`
	fuck phuck shit shyt cunt bollock bitch bastard
	nigger nigga faggot tranny whore slut skank rapist incest pedophile paedophile molest
	porn pr0n hentai xxx jizz cumshot blowjob handjob rimjob bukkake nazi hitler kkk
`)

// Words a name may not have as one of its parts, so cockpit, brightwater and grapefruit still pass.
var blockedWhole = strings.Fields(`
	ass arse cock dick dik prick tit tits boob boobs cum sex sexy anal anus penis vagina pussy
	fag fagot hoe fap nsfw piss twat wank fuk fck rape pedo paedo spic kike chink gook dyke
	retard spastic wetback raghead niger heil
`)

var unleet = strings.NewReplacer("0", "o", "1", "i", "3", "e", "4", "a", "5", "s", "7", "t", "8", "b", "@", "a", "$", "s")

// offensive says whether a label holds a word the service will not hand out.
func offensive(label string, extra map[string]bool) bool {
	plain := unleet.Replace(label)
	joined := strings.ReplaceAll(plain, "-", "")
	for _, w := range blockedAnywhere {
		if strings.Contains(joined, w) {
			return true
		}
	}
	parts := strings.FieldsFunc(plain, func(r rune) bool { return r == '-' })
	for _, part := range parts {
		for _, w := range blockedWhole {
			if part == w {
				return true
			}
		}
		if extra[part] {
			return true
		}
	}
	for w := range extra {
		if len(w) >= 4 && strings.Contains(joined, w) {
			return true
		}
	}
	return false
}
