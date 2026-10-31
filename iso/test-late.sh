#!/bin/sh
# Runs in the installed system from the test preseed's late_command: adds a
# service that reports the booted system on the serial console.
set -e
cat > /usr/local/sbin/bande-test-report <<'EOT'
#!/bin/sh
state=$(systemctl is-system-running --wait)
{
    [ "$state" = running ] || systemctl --failed --no-legend --plain | sed 's/^/BANDE-TEST-FAILED: /'
    echo "BANDE-TEST-EFI: $([ -d /sys/firmware/efi ] && echo yes || echo no)"
    echo "BANDE-TEST-APT: $(grep -rhs '^[^#].*bande-linux' /etc/apt/sources.list /etc/apt/sources.list.d | head -1)"
    for p in @PACKAGES@ ""; do
        [ -n "$p" ] || continue
        echo "BANDE-TEST-PACKAGE: $(dpkg-query -W -f '${Package} ${Version} ${db:Status-Status}' "$p" 2>&1)"
    done
    echo "BANDE-TEST-KERNEL: $(uname -r)"
    echo "BANDE-TEST-BOOTED: $state"
} > /dev/console
EOT
chmod +x /usr/local/sbin/bande-test-report
cat > /etc/systemd/system/bande-test-report.service <<'EOT'
[Unit]
Description=Report the installed system for the install test

[Service]
ExecStart=/usr/local/sbin/bande-test-report

[Install]
WantedBy=multi-user.target
EOT
systemctl enable bande-test-report.service
