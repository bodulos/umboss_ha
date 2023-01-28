#!/bin/bash

#[ -f ./ha-wrapper.env ] && source ./ha.wrapper.env

[ -z ${LEADER_KEY} ] && LEADER_KEY="programX_leader"
[ -z ${LEADER_VALUE} ] && LEADER_VALUE="server1"
#LEADER_VALUE="${HOSTNAME}"
OBSERVER_TIMEOUT=10

controller_pid="$$"

# log $msg
function log() {
	echo "$1"
}

# killpid $pid $cmdline_regex
function killpid()
{
	log "KILLPID=${1}"
	log "KILLPID_REGEXP=${2}"
	if [ -z "${1}" ] || [ -z "${2}" ] ; then
		log "Input variables not set. Skipping..."
		return
	fi
	if [ ! -e "/proc/${1}" ] ; then
		log "Process with PID [${1}] is not running. Skipping..."
		return
	fi
	if [ -n "${3}" ] && [ $(grep -E "${3}" /proc/${1}/cmdline) -ne 0 ] ; then
		log "Process runing with PID [${1}] does not match expected cmdline regexp (${3}). Skipping...."
		return
	fi

	kill "${1}"
	log "Killing PID [${1}]"
}

function cleanup() {
	log "Cleanup trap called!"
    # TODO: Have to implement additional process checking before kill, not to kill wrong process by accident.
	# Check pid still exists. Check process cmdline. Check parent pid. Put this into a function?
	# DONE ->
	# Parent PID check can be missleading, when parent is killed, PID 1 takes role of the parent. We will skip this check.
	
	echo "Cleanup: elector process."
	killpid ${elector_pid} "etcdctl elect ${LEADER_KEY} ${LEADER_VALUE}"
	echo "Cleanup: observer process."
	killpid ${observer_pid} "etcdctl elect -l ${LEADER_KEY}"
	echo "Cleanup: application process."
	killpid ${app_pid} "${APP}"

    # Fifo is a pipe so -f test does not work. -e (is a file) or -p (is a pipe) will work.
	[ -e ${observer_fifo} ] && ( log "Cleanup: removing observer fifo ${observer_fifo}" ; rm -f ${observer_fifo} )
    # Disable the EXIT trap. If we reach this point by some other trap, it will be executed again on EXIT trap.
    trap - EXIT    
}

# Start election process for this instance. After we are elected as a leader, etcdctl process will exit when 
# we are not the leader any more, eg. connection to etcd cluster is lost. Leader election timeout applies.
etcdctl elect ${LEADER_KEY} ${LEADER_VALUE} &
elector_pid=$!
log "Started leader election proces [${elector_pid}]"

# We need to cleanup spawned processes in case of external signal or main process exit because of some subprocess error.
trap cleanup SIGHUP SIGINT SIGQUIT SIGTERM EXIT
log "Cleanup trap is setup"

# Wait for us to get elected as a leader.
# While election process is alive:
while kill -0 ${elector_pid} 2> /dev/null; do
	
	log "Leader election process is alive, let's wait our turn..." 
	# Wait for us to get elected as leader.
	# We basicaly need to check if we are elected by parsing the output of elect observation command 
    # and waiting for our $LEADER_VALUE to show up for our election key $LEADER_KEY.
	# Simple pipe could work but this would leave the etcdctl process alive and hanging until
    # it tries to write another line to stdout/stderr when it would get SIGPIPE and die.
	# This is one of possible workarounds for it, with named pipes (FIFO).
	observer_fifo="/tmp/elect_observer_fifo.$$"
	# Our trap will catch this exit and kill the spawned election process.
	mkfifo "${observer_fifo}" || exit 1
	log "Leader election observer FIFO created"
	etcdctl elect -l ${LEADER_KEY} >${observer_fifo} &
	observer_pid=$!
	log "Leader election observer started [${observer_pid}]"
	# THIS GREP BLOCKS! Have to decuple this, with eg. timeout, to be able to check if leader election process is still alive (while loop condition)
    # and we can continue to observe election process 
	grep -m 1 "${LEADER_VALUE}" "${observer_fifo}"
	if [ "$?" -ne "0" ] ; then
		log "Leader election observer process exited without us getting elected. Something went wrong with election proces, bailing out..."
        # Election observer process exited, unset observer_pid variable so it does not get killed in cleanup trap.
        observer_pid=
		exit 2
	fi
    log "We are elected (${LEADER_KEY})"
	# We are elected! We can close the observer now.
    log "Killing Observer PID ${observer_pid}"
	kill "${observer_pid}"
	# Election observer process is killed, unset observer_pid variable so it does not get killed in cleanup trap.
	observer_pid=
	# Delete fifo. It would be done by trap also, as failsafe.
    log "Removing Observer FIFO: ${observer_fifo}"
	rm -f "${observer_fifo}"

    log "Break the Leader election loop."
    break

done

# We are elected, we can start the application process
# TODO: SIGKILL to a process will terminate it unconditionaly. So we have to add some additional failsafe
# so that in case that control process is killed with SIGKILL, app process would also be terminated. Watchdog?
# DONE ->
# We actually do not need to do anything. Systemd will cleanup all the child processes when Controller process exits
#

#APP="./test.sh"
log "Starting the app: ${APP}"
${APP} &
app_pid=$!

# Start a loop that runs until we are a leader.
log "Starting the Leader health monitoring loop."
while kill -0 ${elector_pid} 2> /dev/null; do
    sleep 1
done

log "Leader elecion process is gone. We are not a leader any more. Application should be terminated."

# We are no longer a leader. Application needs to be terminated
kill ${app_pid}
log "Application killed: ${app_pid}"
# If everything went well, leader process sohuld also be dead at this point. 
# This has to be doublechecked, what happens if process is not killed but network connection is disruppted?
# Does leader election etcdctl process die? What happens when network connection is reestablished.

# Everything went fine, disable the EXIT trap on a normal exit.
trap - EXIT