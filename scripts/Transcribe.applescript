-- Transcribe.app — local, offline audio/video transcription (whisper.cpp)
-- Drop files on the icon, or open the app and pick a file. No cloud upload.
-- Each file is transcribed in a DETACHED background job, so the app never
-- freezes and quits immediately. Progress + results arrive as notifications.

property audioExts : {"m4a", "mp3", "wav", "aiff", "aif", "caf", "flac", "ogg", "opus", "mp4", "mov", "m4v", "mkv", "webm", "aac", "wma", "avi"}

-- Launched directly (Spotlight / double-click): ask for files.
on run
	set chosen to choose file with prompt "Choose audio or video file(s) to transcribe:" with multiple selections allowed
	processFiles(chosen)
end run

-- Files dropped onto the icon.
on open theFiles
	processFiles(theFiles)
end open

on processFiles(theFiles)
	set skipped to {}
	repeat with f in theFiles
		set p to POSIX path of f
		set ext to my lc(my fileExt(p))
		if audioExts does not contain ext then
			set end of skipped to (my baseName(p) & " (unsupported ." & ext & ")")
		else
			-- Fire the notifier script detached; $HOME is expanded by /bin/sh.
			-- nohup + & + redirect => returns instantly and survives app quit.
			do shell script "nohup bash \"$HOME/.claude/skills/transcribe/transcribe-notify.sh\" " & quoted form of p & " >/dev/null 2>&1 &"
		end if
	end repeat

	if (count of skipped) > 0 then
		display alert "Skipped unsupported file(s)" message (my joinList(skipped, return)) as warning
	end if
end processFiles

-- ---- helpers ----
on fileExt(p)
	if p contains "." then
		set AppleScript's text item delimiters to "."
		set e to last text item of p
		set AppleScript's text item delimiters to ""
		return e
	end if
	return ""
end fileExt

on baseName(p)
	set AppleScript's text item delimiters to "/"
	set b to last text item of p
	set AppleScript's text item delimiters to ""
	return b
end baseName

on lc(s)
	return do shell script "echo " & quoted form of s & " | tr '[:upper:]' '[:lower:]'"
end lc

on joinList(lst, delim)
	set AppleScript's text item delimiters to delim
	set r to lst as text
	set AppleScript's text item delimiters to ""
	return r
end joinList
