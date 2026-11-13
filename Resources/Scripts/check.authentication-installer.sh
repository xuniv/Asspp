#!/bin/bash
set -euo pipefail
check_repo_dir=$(cd "$(dirname "$0")/../.." && pwd)
check_dir=$(mktemp -d)
trap 'rm -rf "$check_dir"' EXIT
cd "$check_repo_dir"
swiftc Asspp/Backend/AppStore/StoreProtocol.swift \
    Asspp/Backend/AppStore/StoreAuthenticationProtocol.swift \
    Asspp/Backend/Installer/InstallationProtocol.swift \
    Resources/Tests/AuthenticationInstallerChecks.swift -o "$check_dir/checks"
"$check_dir/checks"
# Check the actual bundled chain, hostname, expiry, EKU and leaf/private-key pair.
cert_dir=Certificates/localhost.qaq.wiki
openssl verify -purpose sslserver -verify_hostname app.localhost.qaq.wiki \
    -CAfile "$cert_dir/rootCA.pem" "$cert_dir/localhost.qaq.wiki.pem"
openssl x509 -checkend 2592000 -noout -in "$cert_dir/localhost.qaq.wiki.pem"
openssl x509 -in "$cert_dir/localhost.qaq.wiki.pem" -pubkey -noout > "$check_dir/certificate.pub"
openssl pkey -in "$cert_dir/localhost.qaq.wiki-key.pem" -pubout > "$check_dir/server.pub"
cmp "$check_dir/certificate.pub" "$check_dir/server.pub"
if [ "$(uname -s)" = Darwin ]; then
    /usr/bin/python3 Resources/Tests/LocalizationChecks.py \
        Asspp/Backend/AppStore/StoreAuthenticationProtocol.swift \
        Asspp/Backend/AppStore/StoreAuthenticator.swift \
        Asspp/Backend/Installer/InstallationProtocol.swift \
        Asspp/Interface/Download/ImportIPAView.swift \
        Asspp/Interface/Download/InstallerView.swift
fi
