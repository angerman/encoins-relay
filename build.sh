#!/bin/bash

cabal new-build all
cp dist-newstyle/build/x86_64-linux/ghc-8.10.7/encoins-relay-server-1.0.0.0/build/encoins-relay-server/encoins-relay-server ~/.local/bin/encoins

cp dist-newstyle/build/x86_64-linux/ghc-8.10.7/encoins-relay-verifier-0.1.0.0/build/encoins-relay-verifier/encoins-relay-verifier ~/.local/bin/encoins-verifier

cp dist-newstyle/build/x86_64-linux/ghc-8.10.7/encoins-relay-client-0.1.0.0/x/encoins-relay-client/build/encoins-relay-client/encoins-relay-client ~/.local/bin/encoins-client

cp dist-newstyle/build/x86_64-linux/ghc-8.10.7/encoins-relay-apps-0.1.0.0/build/encoins-relay-poll/encoins-relay-poll ~/.local/bin/encoins-poll

cp dist-newstyle/build/x86_64-linux/ghc-8.10.7/encoins-relay-apps-0.1.0.0/build/encoins-relay-delegation/encoins-relay-delegation ~/.local/bin/encoins-delegation

cp dist-newstyle/build/x86_64-linux/ghc-8.10.7/encoins-relay-apps-0.1.0.0/build/encoins-relay-delegation-client/encoins-relay-delegation-client ~/.local/bin/encoins-delegation-client