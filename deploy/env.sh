#!/usr/bin/env bash
#
# source into environment for deploy library functions/variables
#

# wrapper for (BSD|Linux) `sed -i`
sed_inplace() {
	if [[ $(uname) == "Linux" ]]; then
		sed -i "$@"
	else
		sed -i '' "$@"
	fi
}
export -f sed_inplace

# internal log function that bash log API calls.
_log() {
	# log level: (INFO|WARNING|ERROR|DEBUG)
	local level="$1"
	# log message
	local msg="$2"

	# level of the caller's callstack. caller -> (i|w|e|d)log -> _log, so the
	# level of the caller's callstack is 2.
	local callstack=2

	local timestamp
	timestamp=$(date '+%Y-%m-%d %H:%M:%S')

	local file
	file="$(basename "${BASH_SOURCE[$callstack]}")"

	local line="${BASH_LINENO[$callstack]}"
	local func="${FUNCNAME[$callstack]:-main}"
	local pid=$$

	echo "$timestamp | $level | $file[$pid]:$func:$line | $msg"
}
# NOTE: must be exported too, for the exported wrapper functions to call!
export -f _log

# INFO to stdout
ilog() {
	_log "INFO" "$1" 2>&1
}
export -f ilog

# WARNING to stderr
wlog() {
	_log "WARNING" "$1" >&2
}
export -f wlog

# ERROR to stderr
elog() {
	_log "ERROR" "$1" >&2
}
export -f elog

# DEBUG to stdout
dlog() {
	if [[ $DEBUG == true ]]; then
		_log "DEBUG" "$1" 2>&1
	fi
}
export -f dlog
