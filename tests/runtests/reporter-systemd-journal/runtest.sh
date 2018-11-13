#!/bin/bash
# vim: dict=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   runtest.sh of reporter-systemd-journal
#   Description: Verify reporter-systemd-journal functionality
#   Author: Matej Habrnal <mhabrnal@redhat.com>
#
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   Copyright (c) 2016 Red Hat, Inc. All rights reserved.
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

TEST="reporter-systemd-journal"
PACKAGE="abrt"
EXAMPLES_PATH="../../examples"
OOPS_FILE="oops1.test"

# generated by journalctl --new-id128
CATALOG_MSG_ID="1bea0b0f98524411b3696309155f34db"
JOURNAL_CATALOG_PATH="/usr/lib/systemd/catalog/abrt_test.catalog"
SYSLOG_ID="abrt_reporter_systemd_journal_testing"


# $1 reporter parameters
# $2 journal parameters
# $3 log file name
# $4 Array with testing strings
function check()
{
    REPORTER_PARAMS=$1
    shift
    JOURNAL_PARAMS=$1
    shift
    LOG_FILE=$1.log
    shift

    # ignore of previous reports
    sleep 2
    SINCE=$(date +"%Y-%m-%d %T")
    rlLog "Start date time stamp $SINCE"
    sleep 2

    # reporting
    reporter-systemd-journal -d problem_dir -s $SYSLOG_ID $REPORTER_PARAMS
    sleep 2

    # list journal
    journalctl $JOURNAL_PARAMS "SYSLOG_IDENTIFIER=$SYSLOG_ID" --since="$SINCE" 2>&1 | tee $LOG_FILE

    # lines before string 'NULL' shoudl be placed in journal log and lines
    # after string 'NULL' shouldn't
    array=( "$@" )
    SHOULD_CONTAIN=true
    for line in "${array[@]}"; do
        if [ "$line" = "NULL" ]; then
            SHOULD_CONTAIN=false
            continue
        fi

        if [ $SHOULD_CONTAIN = true ]; then
            rlAssertGrep "$line" $LOG_FILE
        else
            rlAssertNotGrep "$line" $LOG_FILE
        fi
    done
}

function check_crash()
{
    CRASH_BIN=$1
    shift
    LOG_FILE=$1.log
    LOG_RIGHT=$1.right

    sleep 2
    SINCE=$(date +"%Y-%m-%d %T")
    rlLog "Start date time stamp $SINCE"
    sleep 2

    # reporting
    prepare
    $CRASH_BIN
    wait_for_hooks
    get_crash_path

    sleep 5

    # list journal
    SYS_ID="abrt-notification"
    journalctl -x "SYSLOG_IDENTIFIER=$SYS_ID" --since="$SINCE" 2>&1 | tee $LOG_FILE

    if [ -f ${crash_PATH}/pid ]; then
        PROBLEM_PID=$(cat ${crash_PATH}/pid)
        # sed pid of crashed binary
        sed -i "s/#PID#/${PROBLEM_PID}/g" $LOG_RIGHT
    else
        rlLog "element pid doesn't exist in dump dir $crash_PATH"
    fi
    # remove first line which is added by journalctl
    sed -i '1d' $LOG_FILE
    # remove jounral identifier
    sed -i "s/^$(date +%b).*${SYS_ID}\[[0-9][0-9]*\]: //g" $LOG_FILE

    rlAssertNotDiffer $LOG_FILE $LOG_RIGHT
    diff $LOG_FILE $LOG_RIGHT

    abrt-cli remove $crash_PATH
}

rlJournalStart
    rlPhaseStartSetup
        LANG=""
        export LANG

        rpm -q libreport-plugin-systemd-journal || rlDie "Package 'libreport-plugin-systemd-journal' is not installed."
        check_prior_crashes

cat > $JOURNAL_CATALOG_PATH << EOF
-- $CATALOG_MSG_ID
Subject: ABRT testing
Defined-By: ABRT
Support: https://bugzilla.redhat.com/
Documentation: man:abrt(1)
@PROBLEM_REPORT@
ABRT TESTING
EOF

        # update catalog messages
        journalctl --update-catalog

        TmpDir=$(mktemp -d)
        cp -R problem_dir $TmpDir
        RPM_VERSION="$( rpm -q --qf "%{version}-%{release}.%{arch}\n" kernel | tail -n 1 | tr -d '\n' )"
        sed "s/2.6.27.9-159.fc10.i686/${RPM_VERSION}/" \
            ${EXAMPLES_PATH}/${OOPS_FILE} > \
            ${TmpDir}/${OOPS_FILE}

        cp -v $EXAMPLES_PATH/xorg_journal_crash2.test $TmpDir/xorg_crash

        pushd $TmpDir

cat > abrt_format.conf << EOF
%summary:: REPORTER MAIN MESSAGE

DESCRIPTION PART
EOF
    rlPhaseEnd
    rlPhaseStartTest "sanity"
        rlRun "reporter-systemd-journal --help &> null"
        rlRun "reporter-systemd-journal --help 2>&1 | grep 'Usage:'"
    rlPhaseEnd

    rlPhaseStartTest "default reporting"
        # catalog message
        check_array=( \
            # should be in log
            'Process /usr/bin/urxvtd was killed by signal 11 (SIGSEGV)' \
            'NULL' \
            # shouldn't be in log
            '-- Subject: ABRT testing' \
            '-- Support: https://bugzilla.redhat.com/' \
            '-- Documentation: man:abrt(1)' \
            '-- DESCRIPTION PART' \
            '-- ABRT TESTING' \
        )
        check "" "-x" "default" "${check_array[@]}"
    rlPhaseEnd

    rlPhaseStartTest "only formatting file"
        # catalog message
        check_array=( \
            # should be in log
            'REPORTER MAIN MESSAGE' \
            'NULL' \
            # shouldn't be in log
            'Process /usr/bin/urxvtd was killed by signal 11 (SIGSEGV)' \
            '-- Subject: ABRT testing' \
            '-- Support: https://bugzilla.redhat.com/' \
            '-- Documentation: man:abrt(1)' \
            '-- DESCRIPTION PART' \
            '-- ABRT TESTING' \
        )
        check "-F abrt_format.conf" "-x" "only_formatting_file" "${check_array[@]}"
    rlPhaseEnd

    rlPhaseStartTest "only message id"
        # catalog message
        check_array=( \
            # should be in log
            'Process /usr/bin/urxvtd was killed by signal 11 (SIGSEGV)' \
            '-- Subject: ABRT testing' \
            '-- Support: https://bugzilla.redhat.com/' \
            '-- Documentation: man:abrt(1)' \
            '-- ABRT TESTING' \
            'NULL' \
            # shouldn't be in log
            'REPORTER MAIN MESSAGE' \
            '-- DESCRIPTION PART' \
        )
        check "-m $CATALOG_MSG_ID" "-x" "only_message_id" "${check_array[@]}"
    rlPhaseEnd

    rlPhaseStartTest "message id and formatting conf"
        # catalog message
        check_array=( \
            # should be in log
            'REPORTER MAIN MESSAGE' \
            '-- Subject: ABRT testing' \
            '-- Support: https://bugzilla.redhat.com/' \
            '-- Documentation: man:abrt(1)' \
            '-- DESCRIPTION PART' \
            '-- ABRT TESTING' \
            'NULL' \
            # shouldn't be in log
            'Process /usr/bin/urxvtd was killed by signal 11 (SIGSEGV)' \
        )
        check "-m $CATALOG_MSG_ID -F abrt_format.conf" "-x" "message_id_formatting_file" "${check_array[@]}"
    rlPhaseEnd

    rlPhaseStartTest "parameter --dump NONE"
        # journal fields
        check_array=( \
            # should be in log
            '"MESSAGE" : "REPORTER MAIN MESSAGE"' \
            '"SYSLOG_IDENTIFIER" : "abrt_reporter_systemd_journal_testing"' \
            '"PROBLEM_BINARY" : "urxvtd"' \
            '"PROBLEM_REASON" : "Process /usr/bin/urxvtd was killed by signal 11 (SIGSEGV)"' \
            '"PROBLEM_CRASH_FUNCTION" : "rxvt_term::selection_delimit_word"' \
            '"PROBLEM_REPORT" : "\\nDESCRIPTION PART\\n"' \
            '"PROBLEM_PID" : "1234"' \
            '"PROBLEM_EXCEPTION_TYPE" : "exception_type"' \
            '"PROBLEM_DIR" : "'"$TmpDir"'/problem_dir' \
            '"PROBLEM_DUPHASH" : "bbfe66399cc9cb8ba647414e33c5d1e4ad82b511"' \
            '"PROBLEM_UUID" : "b43d70450c44352de194f545a7d3841eb80b1ae5"' \
            'NULL' \
            # shouldn't be in log
            '"PROBLEM_CMDLINE" : "urxvtd -q -o -f"' \
            '"PROBLEM_COMPONENT" : "rxvt-unicode"' \
            '"PROBLEM_UID" : "502"' \
            '"PROBLEM_PKG_NAME" : "package name"' \
            '"PROBLEM_PKG_VERSION" : "3"' \
            '"PROBLEM_PKG_RELEASE" : "33"' \
            '"PROBLEM_PKG_FINGERPRINT" : "xxxx-xxxx-xxx"' \
            '"PROBLEM_REPORTED_TO" : "bugzilla"' \
        )
        check "--dump NONE -F abrt_format.conf" "-o json-pretty" "dump_none" "${check_array[@]}"
    rlPhaseEnd

    rlPhaseStartTest "parameter --dump ESSENTIAL"
        # journal fields
        check_array=( \
            # should be in log
            '"MESSAGE" : "REPORTER MAIN MESSAGE"' \
            '"SYSLOG_IDENTIFIER" : "abrt_reporter_systemd_journal_testing"' \
            '"PROBLEM_BINARY" : "urxvtd"' \
            '"PROBLEM_REASON" : "Process /usr/bin/urxvtd was killed by signal 11 (SIGSEGV)"' \
            '"PROBLEM_CRASH_FUNCTION" : "rxvt_term::selection_delimit_word"' \
            '"PROBLEM_REPORT" : "\\nDESCRIPTION PART\\n"' \
            '"PROBLEM_PID" : "1234"' \
            '"PROBLEM_EXCEPTION_TYPE" : "exception_type"' \
            '"PROBLEM_DIR" : "'"$TmpDir"'/problem_dir' \
            '"PROBLEM_DUPHASH" : "bbfe66399cc9cb8ba647414e33c5d1e4ad82b511"' \
            '"PROBLEM_UUID" : "b43d70450c44352de194f545a7d3841eb80b1ae5"' \
            # essential fields
            '"PROBLEM_CMDLINE" : "urxvtd -q -o -f"' \
            '"PROBLEM_COMPONENT" : "rxvt-unicode"' \
            '"PROBLEM_UID" : "502"' \
            '"PROBLEM_PKG_NAME" : "package name"' \
            '"PROBLEM_PKG_VERSION" : "3"' \
            '"PROBLEM_PKG_RELEASE" : "33"' \
            '"PROBLEM_PKG_FINGERPRINT" : "xxxx-xxxx-xxx"' \
            '"PROBLEM_REPORTED_TO" : "bugzilla"' \
            '"PROBLEM_TYPE" : "CCpp"' \
            'NULL' \
            # shouldn't be in log
            '"PROBLEM_DSO_LIST" : "/lib64/libcrypt-2.14.so glibc-2.14-4.x86_64 (Fedora Project) 1310382635"' \
            '"PROBLEM_BACKTRACE_RATING" : "1"' \
            '"POBLEM_HOSTNAME" : "fluffy"' \
            '"PROBLEM_BACKTRACE" : "testing backtrace"' \
            '"PROBLEM_OS_RELEASE" : "Fedora release 15 (Lovelock)"' \
            '"PROBLEM_KERNEL" : "2.6.38.8-35.fc15.x86_64"' \
        )
        check "--dump ESSENTIAL -F abrt_format.conf" "-o json-pretty" "dump_essential" "${check_array[@]}"
    rlPhaseEnd

    rlPhaseStartTest "parameter --dump FULL"
        # journal fields
        check_array=( \
            # should be in log
            '"MESSAGE" : "REPORTER MAIN MESSAGE"' \
            '"SYSLOG_IDENTIFIER" : "abrt_reporter_systemd_journal_testing"' \
            '"PROBLEM_BINARY" : "urxvtd"' \
            '"PROBLEM_REASON" : "Process /usr/bin/urxvtd was killed by signal 11 (SIGSEGV)"' \
            '"PROBLEM_CRASH_FUNCTION" : "rxvt_term::selection_delimit_word"' \
            '"PROBLEM_REPORT" : "\\nDESCRIPTION PART\\n"' \
            '"PROBLEM_PID" : "1234"' \
            '"PROBLEM_EXCEPTION_TYPE" : "exception_type"' \
            '"PROBLEM_DIR" : "'"$TmpDir"'/problem_dir' \
            '"PROBLEM_DUPHASH" : "bbfe66399cc9cb8ba647414e33c5d1e4ad82b511"' \
            '"PROBLEM_UUID" : "b43d70450c44352de194f545a7d3841eb80b1ae5"' \
            # essential fields
            '"PROBLEM_CMDLINE" : "urxvtd -q -o -f"' \
            '"PROBLEM_COMPONENT" : "rxvt-unicode"' \
            '"PROBLEM_UID" : "502"' \
            '"PROBLEM_PKG_NAME" : "package name"' \
            '"PROBLEM_PKG_VERSION" : "3"' \
            '"PROBLEM_PKG_RELEASE" : "33"' \
            '"PROBLEM_PKG_FINGERPRINT" : "xxxx-xxxx-xxx"' \
            '"PROBLEM_REPORTED_TO" : "bugzilla"' \
            '"PROBLEM_TYPE" : "CCpp"' \
            # full fields
            '"PROBLEM_DSO_LIST" : "/lib64/libcrypt-2.14.so glibc-2.14-4.x86_64 (Fedora Project) 1310382635"' \
            '"PROBLEM_BACKTRACE_RATING" : "1"' \
            '"PROBLEM_HOSTNAME" : "fluffy"' \
            '"PROBLEM_BACKTRACE" : "testing backtrace"' \
            '"PROBLEM_OS_RELEASE" : "Fedora release 15 (Lovelock)"' \
            '"PROBLEM_KERNEL" : "2.6.38.8-35.fc15.x86_64"' \
            'NULL' \
            # shouldn't be in log
        )
        check "--dump FULL -F abrt_format.conf" "-o json-pretty" "dump_full" "${check_array[@]}"
    rlPhaseEnd

    rlPhaseStartTest "ccpp crash abrt-ccpp"
        OUTPUT="ccpp_abrt"
cat > ${OUTPUT}.right << END
Process #PID# (will_stackoverflow) crashed in f()
-- Subject: ABRT has detected unexpected termination: will_stackoverflow
-- Defined-By: ABRT
-- Support: https://bugzilla.redhat.com/
-- Documentation: man:abrt(1)
-- 
-- will_stackoverflow killed by SIGSEGV
-- 
-- #1 [will_stackoverflow] f
-- #2 [will_stackoverflow] main
-- 
-- Use the abrt command-line tool for further analysis or to report
-- the problem to the appropriate support site.
END

        check_crash "will_stackoverflow" $OUTPUT
    rlPhaseEnd

    rlPhaseStartTest "ccpp crash systemd-coredump"
        rlRun "systemctl stop abrt-ccpp"
        rlRun "systemctl start abrt-journal-core"
        OLD_ULIMIT=$(ulimit -c)
        rlRun "ulimit -c unlimited"
        SELINUX_MODE=$(getenforce -c)
        rlRun "setenforce 0"

        OUTPUT="ccpp_systemd"
cat > ${OUTPUT}.right << END
Process #PID# (will_stackoverflow) crashed in f()
-- Subject: ABRT has detected unexpected termination: will_stackoverflow
-- Defined-By: ABRT
-- Support: https://bugzilla.redhat.com/
-- Documentation: man:abrt(1)
-- 
-- will_stackoverflow killed by SIGSEGV
-- 
-- Use the abrt command-line tool for further analysis or to report
-- the problem to the appropriate support site.
END

        check_crash "will_stackoverflow" $OUTPUT

        rlRun "setenforce $SELINUX_MODE"
        rlRun "ulimit -c $OLD_ULIMIT"
        rlRun "systemctl stop abrt-journal-core"
        rlRun "systemctl start abrt-ccpp"
    rlPhaseEnd

    rlPhaseStartTest "python3 crash"
        OUTPUT="python3"
cat > ${OUTPUT}.right << END
Process #PID# (will_python3_raise) of user $(id -u) encountered an uncaught ZeroDivisionError exception
-- Subject: ABRT has detected an uncaught ZeroDivisionError exception in will_python3_raise
-- Defined-By: ABRT
-- Support: https://bugzilla.redhat.com/
-- Documentation: man:abrt(1)
-- 
-- will_python3_raise:3:<module>:ZeroDivisionError: division by zero
-- 
-- #1 [/usr/bin/will_python3_raise:3] <module>
-- 
-- Use the abrt command-line tool for further analysis or to report
-- the problem to the appropriate support site.
END

        check_crash "will_python3_raise" $OUTPUT
    rlPhaseEnd

    rlPhaseStartTest "kernel oops"
        OUTPUT="oops"
cat > ${OUTPUT}.right << END
System encountered a non-fatal error in radeon_cp_init_ring_buffer()
-- Subject: ABRT has detected a non-fatal system error
-- Defined-By: ABRT
-- Support: https://bugzilla.redhat.com/
-- Documentation: man:abrt(1)
-- 
-- BUG: unable to handle kernel NULL pointer dereference at 00000000 [radeon]
-- 
-- Use the abrt command-line tool for further analysis or to report
-- the problem to the appropriate support site.
END

        check_crash "abrt-dump-oops -Dx $OOPS_FILE" $OUTPUT
    rlPhaseEnd

    rlPhaseStartTest "xorg"
        OUTPUT="xorg"

        SYSLOG_IDENTIFIER="reporter-journal-test"
        WILL_XORG="will_xorg.sh"
cat > $WILL_XORG << END
#!/usr/bin/bash
echo "Generating xorg crash"
set -x
journalctl --flush
ABRT_DUMP_JOURNAL_XORG_DEBUG_FILTER="SYSLOG_IDENTIFIER=${SYSLOG_IDENTIFIER}" setsid abrt-dump-journal-xorg -vvv -f -xD -o &
sleep 2
logger -t ${SYSLOG_IDENTIFIER} -f xorg_crash
journalctl --flush
sleep 2
killall abrt-dump-journal-xorg
set +x

END
        rlRun "chmod +x $WILL_XORG"

cat > ${OUTPUT}.right << END
Display server /usr/libexec/Xorg crash in OsLookupColor()
-- Subject: ABRT has detected crash of display server
-- Defined-By: ABRT
-- Support: https://bugzilla.redhat.com/
-- Documentation: man:abrt(1)
-- 
-- Segmentation fault at address 0x7f61d93f6160
-- 
-- Use the abrt command-line tool for further analysis or to report
-- the problem to the appropriate support site.
END

        check_crash "./$WILL_XORG" $OUTPUT
    rlPhaseEnd

    rlPhaseStartTest "vmcore"
        OUTPUT="vmcore"

        WILL_VMCORE="will_vmcore.sh"
cat > $WILL_VMCORE << END
#!/usr/bin/bash
echo "Generating vmcore"
set -x
mkdir -p /var/crash/test
echo testing > /var/crash/test/vmcore
sleep 2
systemctl restart  abrtd.service
systemctl restart  abrt-vmcore.service
sleep 2
set +x
END
        rlRun "chmod +x $WILL_VMCORE"

cat > ${OUTPUT}.right << END
System encountered a fatal error in ??()
-- Subject: ABRT has detected a fatal system error
-- Defined-By: ABRT
-- Support: https://bugzilla.redhat.com/
-- Documentation: man:abrt(1)
-- 
-- Use the abrt command-line tool for further analysis or to report
-- the problem to the appropriate support site.
END

        check_crash "./$WILL_VMCORE" $OUTPUT
    rlPhaseEnd

    rlPhaseStartCleanup
        rlBundleLogs abrt $(ls *.log)
        rlRun "rm -f $JOURNAL_CATALOG_PATH"
        journalctl --update-catalog
        popd # TmpDir
        rm -rf $TmpDir
    rlPhaseEnd
    rlJournalPrintText
rlJournalEnd