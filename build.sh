#!/bin/bash

cabal new-build all
cp dist-newstyle/build/x86_64-linux/ghc-8.10.7/encoins-relay-server-0.1.0.0/x/encoins-relay-server/build/encoins-relay-server/encoins-relay-server ~/.local/bin/encoins

cp dist-newstyle/build/x86_64-linux/ghc-8.10.7/encoins-relay-client-0.1.0.0/x/encoins-relay-client/build/encoins-relay-client/encoins-relay-client ~/.local/bin/encoins-client
