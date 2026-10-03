# Contracts

This Forge project shares the repository with the Swift/Xcode app in `Bounty/`
and `Bounty.xcodeproj`. `Counter.sol`, its tests, and its deployment script are
generated development examples; actual contract requirements are still to be
defined. Stripe integration in the app and `backend/` continues independently.

## Tools and installation

Install [Foundry](https://getfoundry.sh/introduction/installation): `forge` builds
and tests contracts, `anvil` runs a local chain, and `cast` provides RPC utilities.
Git and internet access are needed to fetch dependencies and the Solidity compiler.

```sh
curl -L https://getfoundry.sh/install | bash
# Open a new terminal, or reload your shell configuration.
foundryup --install 1.8.4
forge --version
anvil --version
```

Foundry 1.8.4 was used for setup. To install the latest stable toolchain instead,
run `foundryup` without a version.

## Build and test

From the repository root, restore the pinned dependency after cloning:

```sh
git submodule update --init --recursive contracts/lib/forge-std
cd contracts
forge build
forge test
```

`src/` contains contracts, `test/` contains tests, `script/` contains example
deployment scripts, and `lib/` contains dependencies. `foundry.toml` configures
Forge; `foundry.lock` records the `forge-std` version. Forge downloads a compatible
Solidity compiler on the first build. Build outputs, caches, transaction logs,
local environment files, and signing material are ignored by Git.

## Local development

In a separate terminal:

```sh
cd contracts
anvil
```

The default local RPC endpoint is `http://127.0.0.1:8545`, with chain ID `31337`.
Anvil's accounts and keys are disposable local development credentials. Starting
Anvil does not deploy any contracts; this setup does not run deployment scripts.

## Future Swift integration

Once contract behavior and a deployment are defined, the Swift app could use an
EVM JSON-RPC client with a network-specific **RPC endpoint**, **chain ID**,
**contract address**, and **ABI**. Forge emits the ABI in the `abi` field of
`out/<Contract>.sol/<Contract>.json`; an ABI intended for the app can later be
exported into an app resource rather than including all build outputs.

Future decisions include the network, contract API, Swift client library, and
whether the app only reads data or sends transactions through a wallet or signing
service. Keep private keys out of the app and Git. This scaffold adds no blockchain
behavior to Swift, changes no payment flows, and leaves Stripe development independent.
