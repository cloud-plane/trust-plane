# SPDX-License-Identifier: Apache-2.0
#
# Throw-away test PKI: offline root -> name-constrained transport CA -> node
# certificates. Mirrors the shape of design 4.1 (the real root is offline).
{ pkgs, nodes }:
pkgs.runCommand "test-pki"
  {
    nativeBuildInputs = [ pkgs.openssl ];
  }
  ''
    mkdir -p $out
    cd $out

    # Offline root.
    openssl ecparam -name secp384r1 -genkey -noout -out root.key
    openssl req -x509 -new -key root.key -sha384 -days 3650 \
      -subj "/CN=test offline root" -out root.pem \
      -addext "basicConstraints=critical,CA:TRUE" \
      -addext "keyUsage=critical,keyCertSign,cRLSign"

    # Transport CA, name constrained to the node names.
    permitted="${pkgs.lib.concatMapStringsSep "," (n: "permitted;DNS:${n}") nodes}"
    cat > transport.ext <<EOF2
    basicConstraints=critical,CA:TRUE,pathlen:0
    keyUsage=critical,keyCertSign,cRLSign
    nameConstraints=critical,$permitted
    EOF2
    openssl ecparam -name secp384r1 -genkey -noout -out transport.key
    openssl req -new -key transport.key -subj "/CN=test transport CA" -out transport.csr
    openssl x509 -req -in transport.csr -CA root.pem -CAkey root.key -CAcreateserial \
      -sha384 -days 365 -extfile transport.ext -out transport.pem

    # Node certificates (server + client auth), full chain without the root.
    for n in ${toString nodes}; do
      cat > $n.ext <<EOF2
    basicConstraints=critical,CA:FALSE
    keyUsage=critical,digitalSignature
    extendedKeyUsage=serverAuth,clientAuth
    subjectAltName=DNS:$n
    EOF2
      openssl ecparam -name prime256v1 -genkey -noout -out $n.key
      openssl req -new -key $n.key -subj "/CN=$n" -out $n.csr
      openssl x509 -req -in $n.csr -CA transport.pem -CAkey transport.key -CAcreateserial \
        -sha256 -days 90 -extfile $n.ext -out $n.pem
      cat $n.pem transport.pem > $n.chain.pem
    done

    rm -f *.csr *.srl *.ext
    openssl verify -CAfile root.pem -untrusted transport.pem ${pkgs.lib.head nodes}.pem
  ''
