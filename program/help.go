package main

import (
	"fmt"
	"os"
)

type topic struct{ group, name, synopsis, short, more string }

var topics = []topic{
	{"In an app's repo", "init", "dokkit init",
		"Asks what the app is and writes dokkit.toml.",
		"Asks a few questions and writes a dokkit.toml in this folder: what the app is,\nand how to tell it is healthy. Nothing is sent."},
	{"In an app's repo", "check", "dokkit check [dokkit.toml]",
		"Runs the checks it can once and prints what would be sent.",
		"Checks the file's schema, service id and each check's fields. Runs the http, tcp,\nprocess, windows-service, systemd and expiry checks that can run here, once, and\nprints exactly what would be sent. Checks the app reports itself are listed as\nnot run. A check aimed at another host does make its request. Needs no server and\nsends nothing to it. A slow answer shows as slow, not as a failure."},
	{"In an app's repo", "apply", "dokkit apply [dokkit.toml]",
		"Sends the file to the server.",
		"Declares the file to the server, for a file dokkit watch does not read. It needs\nthis machine's key from dokkit enrol; the server refuses an app key. Sending the\nsame file twice changes nothing."},
	{"Jobs", "run", "dokkit run [--service <slug>] --job <name> -- <command> [arguments]",
		"Runs a command and reports how it went.",
		"Runs the command and reports its start, finish, exit code, duration and last\nlines of output. Exits with the command's own exit code. With this machine's key,\na job declared in a dokkit.toml in the folders of the saved configuration is\nfound by name, and --service says which service when it is not. With an app key,\n--service is ignored."},
	{"Jobs", "ping", "dokkit ping [--service <slug>] <name> [start|ok|fail]",
		"Reports a job that cannot be wrapped.",
		"Reports one event for a job: start, ok (the default) or fail."},
	{"This machine", "enrol", "dokkit enrol <address> <token> [sha256:<certificate fingerprint>]",
		"Joins this machine to a server.",
		"Trades a one-time token for this machine's key and saves it. Given a\nfingerprint, it trusts the certificate with that fingerprint and no other."},
	{"This machine", "status", "dokkit status",
		"What this machine watches and when it last reported.",
		"Shows the files dokkit watch reads, when it last sent, and how many reports are\nwaiting, and any folder it cannot read. It says a watch is running only while that\nwatch has written down in the last three minutes, and then gives its process\nnumber. On Linux it shows the installed service when root, or the dokkit group, can read its\nfiles; the service's status itself can be read only with sudo."},
	{"This machine", "doctor", "dokkit doctor",
		"A rough check of the server and the clock.",
		"Says whether the server answers and knows this key, whether this machine's clock\nis within 30 seconds of the server's (a slow answer counts as clock difference,\nup to 10 seconds), and whether reports are waiting. A certificate that is not the\none saved at enrol shows as the server not answering."},
	{"Finding things", "scan", "dokkit scan [--no-services] [--no-ports] [--no-containers] [--no-sites] [--no-disks] [--no-declarations]",
		"Looks over this machine and writes a proposal file.",
		"Lists what is on the machine that could be watched and writes it to\ndokkit-proposal.json in this folder. Sends nothing. Each --no- flag leaves one kind of thing out."},
	{"Finding things", "propose", "dokkit propose",
		"Sends the proposal file to be accepted.",
		"Sends dokkit-proposal.json, which a scan wrote. Nothing in it is watched until a\nperson accepts it in the interface, or a token allowed to act accepts it through\nthe API."},
	{"Staying running", "watch", "dokkit watch [--background]",
		"Watches this machine, as an ordinary program.",
		"Reads dokkit.toml files from the folders in DOKKIT_FOLDERS or in the saved\nconfiguration, and from the folders directly inside them. Runs their checks,\nsends the log files they name, and says the\nmachine is alive once a minute. No administrator, no service. --background\nleaves it running after this window closes. Run like this, it never restarts a\nservice or unit; only the installed service does."},
	{"Finding things", "import", "dokkit import seq --from <seq address> [--seq-key <key>] [--to <address>] [--key <app key>] [--default-service <id>] [--map <file>] [--service-property <names>] [--app-pattern <regex>] [--state <file>] [--since <time>] [--until <time>] [--rate <lines a second>] [--filter <expression>] [--dry-run]",
		"Copies a Seq server's stored events into Dokkit, oldest first.",
		"Reads the events with Seq's read API and sends them through the server's normal log intake, each with\nits original time. --seq-key (or SEQ_API_KEY) is a Seq key that may read. --to (or DOKKIT_URL) is the\nDokkit server; --key (or DOKKIT_KEY) is the app key of the service that takes events with no service\nof their own, named by --default-service. --service-property lists the Seq properties, in order, that\nhold an event's app (default Application). --app-pattern is a regular expression with one group,\nused on the message when none of those is set. --map is a JSON file from each such value to\n{\"service\": \"<id>\", \"key\": \"<app key>\"}. The last event sent is kept in --state, so a stopped\nimport continues and a second run adds only what is new. Events more than 364 days old are counted\nand not sent, because the server stamps a line that old with its arrival. --dry-run reads and counts\nper service and per month and writes nothing. --since and --until bound the times read. --rate caps the lines a second (default 200). --filter\nis a Seq filter expression."},
	{"Staying running", "folder", "dokkit folder add|remove <path>",
		"Sets which folders dokkit watch reads dokkit.toml files from.",
		"Adds a folder to the list dokkit watch reads dokkit.toml files from, or takes one\nout. It reads the dokkit.toml in the folder and in the folders directly inside it.\nThe path is made absolute, and for add the folder must exist. Adding one twice\nchanges nothing. A running watch picks up the change within a minute, with no\nrestart. When the service is installed this changes the service's list, which\nneeds an administrator, or root on Linux, and it prints the exact line to run.\nOtherwise it changes your own list. On Linux, it warns when the dokkit user cannot\nread the folder."},
	{"Staying running", "folder", "dokkit folder list",
		"Shows those folders.",
		"Lists the folders dokkit watch reads dokkit.toml files from: the installed service's\nwhen there is one, otherwise your own, and any it cannot read."},
	{"Staying running", "imessage", "dokkit imessage on|off|status",
		"Lets this Mac send iMessages when the server asks.",
		"Alerts by iMessage go out through a Mac that is signed in to Messages. Nothing is\nsent unless this Mac was told it may: on records that it may, off takes it back,\nand status says which. Off is the default, and on works on a Mac only. A running\ndokkit watch picks the change up with no restart. When the service is installed\nthis changes the service's configuration, which needs an administrator, or root,\nand it prints the exact line to run."},
	{"Staying running", "imessage", "dokkit imessage test <recipient> [words...]",
		"Sends one iMessage from this Mac now, to prove Messages works.",
		"Sends the words, or a short test message, to a phone number or an email address\nthrough Messages on this Mac, without the server, and prints sent to <recipient> or\nthe reason it was not. It works whether or not on was run. The first send makes\nmacOS ask once, on this Mac's screen, whether dokkit may control Messages; allow\nit, or switch it on under System Settings, Privacy & Security, Automation. macOS\nremembers the answer only for a signed build of dokkit. A message is cut at 1000\ncharacters."},
	{"Staying running", "startup", "dokkit startup on|off",
		"Starts dokkit watch each time you sign in. Windows only.",
		"Works on Windows only so far. Adds dokkit watch --background to your own startup\nprograms, or takes it out. No administrator. On Linux, use dokkit service, or add\ndokkit watch --background to your desktop's startup programs. On macOS, add it to\na launchd job."},
	{"Staying running", "service", "dokkit service install|uninstall|update|start|stop",
		"Runs it as a service, on Windows or Linux. Needs an administrator or root.",
		"Works on Windows and on Linux with systemd; not on macOS yet. Installs dokkit\nas a service that starts with the machine, so it keeps watching with nobody\nsigned in. On Windows it runs as Local Service, an account with no rights of\nits own, and reads only what that account can read, which leaves out other\npeople's profile folders. On Linux it runs as a user named dokkit, which is made\nif useradd is there, and it reads only the folders that user can read. It may\nrestart only the services or units that this machine's own configuration names,\nand only where the machine lets its account: on Windows the service's own\npermissions, on Linux root or systemd.\nOn Windows it keeps to Program Files\\DokkitProgram and ProgramData\\DokkitProgram, and install\nrefuses a data folder that holds anything but config.json, spool, dokkit.log and update.\nA program installed in the older Program Files\\Dokkit and ProgramData\\dokkit is moved by\ninstall or update: its config.json, spool and dokkit.log are copied, the service is pointed\nat the new copy, and the old files are left where they are.\nNeeds an administrator prompt on Windows and root on Linux.\nOn Linux, run through sudo, it uses the enrolment of the account that ran sudo, and\nroot's own when that account has none, and says which file it used. update puts this\ncopy in place of the installed one and restarts the service. uninstall leaves the\nmachine enrolled on the server."},
	{"Staying running", "updater", "dokkit updater install|uninstall|run|status",
		"Updates the program, and the server on the machine that runs it, when asked.",
		"install, once, from an administrator prompt on Windows or as root on Linux and macOS, sets\nup a separate updater that runs every five minutes with full rights, while the program keeps\nrunning as it does now. On Windows it copies this program to Program Files\\DokkitUpdater,\nmakes ProgramData\\DokkitUpdater for administrators and the system account only, registers\nthe scheduled task Dokkit updater (system account, every five minutes and at start-up), and\nneeds the program's service installed first. On Linux and macOS it finds the running dokkit\nwatch and how it is kept (a systemd system or user unit, a LaunchAgent, or a plain\nbackground process), copies this program to /usr/local/lib/dokkit-updater (Linux) or\n/Library/Application Support/DokkitUpdater (macOS), records what it found in config.json\nbeside it, and sets up the timer: a systemd timer where systemd runs, a LaunchDaemon on\nmacOS, otherwise a root crontab line (/etc/config/crontab on a QNAP). It prints what it\ninstalled and where. install runs one check. run is what the timer runs: it asks the server\nwhether this machine has been told to move to a version, and only installs a release whose\nlist is signed with the project's release key and whose files match it. It never installs an\nolder version. On Linux and macOS it replaces the program's file with a rename that keeps\nits owner and mode, keeps the old one as .previous, restarts the program the way it is kept,\nchecks it is running, and puts the old file back if it is not. status prints the installed\nversions, the last check and the last result. uninstall removes the timer and the updater's\nown files. See spec/updates.md."},
	{"This machine", "version", "dokkit version",
		"Prints the version of this build.",
		"Prints the version this build was made as, such as v1.2.3. A build made by hand says v0.0.0-dev."},
}

const settings = `Reads DOKKIT_URL (the server's address) and DOKKIT_KEY (an app key),
or the address and machine key that dokkit enrol saved.
dokkit help <command> says more about one.`

func help(args []string) int {
	if len(args) == 0 {
		fmt.Println("dokkit " + version)
		group := ""
		for _, t := range topics {
			if t.group != group {
				group = t.group
				fmt.Println("\n" + group)
			}
			fmt.Printf("  %s\n      %s\n", t.synopsis, t.short)
		}
		fmt.Println("\n" + settings)
		return 0
	}
	found := false
	for _, t := range topics {
		if t.name == args[0] {
			if found {
				fmt.Println()
			}
			found = true
			fmt.Printf("%s\n\n%s\n", t.synopsis, t.more)
		}
	}
	if !found {
		fmt.Fprintf(os.Stderr, "dokkit: no command named %q. dokkit help lists them.\n", args[0])
		return 2
	}
	return 0
}
