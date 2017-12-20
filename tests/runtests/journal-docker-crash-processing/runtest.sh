#!/bin/bash
# vim: dict=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   runtest.sh of journal-docker-crash-processing
#   Description: test for abrt-dump-journal-docker
#   Author: Julius Milan <jmilan@redhat.com>
#
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   Copyright (c) 2017 Red Hat, Inc. All rights reserved.
#
#   This program is free software: you can redistribute it and/or
#   modify it under the terms of the GNU General Public License as
#   published by the Free Software Foundation, either version 3 of
#   the License, or (at your option) any later version.
#
#   This program is distributed in the hope that it will be
#   useful, but WITHOUT ANY WARRANTY; without even the implied
#   warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
#   PURPOSE.  See the GNU General Public License for more details.
#
#   You should have received a copy of the GNU General Public License
#   along with this program. If not, see http://www.gnu.org/licenses/.
#
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

. /usr/share/beakerlib/beakerlib.sh
. ../aux/lib.sh

TEST="journal-docker-crash-processing"
PACKAGE="abrt"
CONTAINER_CRASH_REQUIRED_FILES="pid executable reason backtrace type" # TODO add next
EXAMPLES_PATH="../../examples"
SYSLOG_IDENTIFIER="abrt-docker-test-${BASHPID}"

function test_single_crash
{
    crash="$1"

    if [ -z "$crash" ]; then
        rlDie "Need an journal log file as the first command line argument"
    fi

    rlLog "Journal Docker container crash: ${crash}"
    crash_name=${crash%.test}

    prepare

    rlRun "journalctl --flush"

    rlRun "ABRT_DUMP_JOURNAL_DOCKERD_DEBUG_FILTER=\"SYSLOG_IDENTIFIER=${SYSLOG_IDENTIFIER}\" setsid abrt-dump-journal-dockerd -f -xD -o > ${crash_name}.log 2>&1 &"
    rlRun "ABRT_DUMPER_PID=$!"

    sleep 2
    rlRun "logger -t ${SYSLOG_IDENTIFIER} -f $crash"
    rlRun "journalctl --flush"

    sleep 2

    rlAssertGrep "Found crashes: 1" $crash_name".log"

    wait_for_hooks
    get_crash_path

    ls $crash_PATH > crash_dir_ls

    check_dump_dir_attributes $crash_PATH

    for f in $CONTAINER_CRASH_REQUIRED_FILES; do
        rlAssertExists "$crash_PATH/$f"
    done

    rlRun "abrt-cli rm $crash_PATH" 0 "Remove crash directory"

    # Kill the dumper with TERM to verify that it can store its state.
    # Next time, the dumper should start following the journald from
    # the last seen cursor.
    rlRun "killall -TERM abrt-dump-journal-dockerd"
    sleep 2

    if [ -d /proc/$ABRT_DUMPER_PID ]; then
        rlLogError "Failed to kill the abrt journal docker dumper"
        rlRun "kill -TERM -$ABRT_DUMPER_PID"
    fi

    rlRun "diff -u ${crash_name}.right ${crash_name}.log" 0 "The dumper copied docker container crash data without any differences"
}

rlJournalStart
    rlPhaseStartSetup
        check_prior_crashes

        TmpDir=$(mktemp -d)
        # TODO add more tests, not just python
        cp -v $EXAMPLES_PATH/container_python_journal_crash.test $TmpDir/
        # TODO move "placeholder" to "Python" in following file after type field addition
        cp -v $EXAMPLES_PATH/container_python_journal_crash.right $TmpDir/

        pushd $TmpDir

        rlRun "systemctl stop abrt-dockerd"

        # Backup the stored cursor
        cp /var/lib/abrt/abrt-dump-journal-dockerd.state /var/lib/abrt/abrt-dump-journal-dockerd.state.bak
    rlPhaseEnd

    rlPhaseStartTest "docker crashes"
        for crash in container*.test; do
            test_single_crash ${crash}
        done
    rlPhaseEnd

    rlPhaseStartCleanup
        # Restore the backuped cursor
        rm -rf /var/lib/abrt/abrt-dump-journal-dockerd.state
        mv /var/lib/abrt/abrt-dump-journal-dockerd.state.bak /var/lib/abrt/abrt-dump-journal-dockerd.state

        rlBundleLogs abrt crash_dir_ls $(echo *.log)
        popd # TmpDir
        rm -r $TmpDir
    rlPhaseEnd
    rlJournalPrintText
rlJournalEnd
