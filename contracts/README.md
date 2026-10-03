# Bounty USDC escrow

`src/BountyEscrow.sol` holds each job's exact USDC amount. The arbiter registers immutable job ID, poster, amount, and deadline. Only that poster can deposit before the deadline, and only the arbiter can release to a worker. After the deadline, either the poster or arbiter can refund. Release and refund are mutually exclusive terminal states. Failed token transfers roll back contract state.

Public deployment is restricted to **Base Sepolia (84532)** and [Circle's six-decimal test USDC](https://developers.circle.com/stablecoins/usdc-contract-addresses): `0x036CbD53842c5426634e7929541eC2318f3dCF7e`. A $15 job deposits 15,000,000 token units. This test USDC path has no platform fee; the poster pays wallet gas in test ETH. The Stripe path retains its 10% fee.

## Test locally

Node 22.13+ and the pinned npm Foundry binaries are sufficient:

```sh
cd backend
npm ci
npm run test:contracts
npm run test:chain
```

The repository pins `forge-std` as a submodule. After a fresh clone, restore it with `git submodule update --init --recursive contracts/lib/forge-std`. Forge downloads Solidity 0.8.30 when needed.

The 13 escrow tests cover permissions, immutable terms, exact deposits, duplicate calls, deadlines, failed token transfers, and both release/refund orderings, including fuzzing. The two Counter scaffold tests remain separate. The local integration test starts a disposable Anvil node, deploys MockUSDC and the actual escrow, runs the backend wallet-signature/funding/release/refund flow, retries a confirmed reverted settlement, and compares ledger records with real token balances. MockUSDC and Anvil's public keys are used only on the local chain.

## Deploy Base Sepolia

```sh
cd backend
npm run setup:chain
```

This generates a dedicated test signer and backend admin token in ignored `.env.chain` with file mode 0600. It prints only the public address and preserves any existing signer. Fund that signer with **faucet ETH on Base Sepolia**, using the [Coinbase Developer Platform faucet](https://portal.cdp.coinbase.com/products/faucet) or [Base's funding guidance](https://docs.base.org/get-started/get-funds). The Coinbase faucet requires your sign-in. The signer pays registration/release/refund gas and does not need USDC.

```sh
npm run deploy:sepolia
npm start
```

Deployment checks the chain and official USDC token, stores the exact signed deployment before broadcasting, waits two confirmations, verifies the arbiter, and writes `ESCROW_CONTRACT_ADDRESS` and `ESCROW_DEPLOYMENT_BLOCK` into `.env.chain`. Repeating the command recovers the original deployment transaction. If the signer lacks test ETH, deployment exits with the funding address. Until deployed, the backend returns a clear unavailable response for USDC operations. Keep keys and `.env.chain` out of Git and the iOS app.

## Fund from iOS

The app uses pinned Coinbase Wallet Mobile SDK 1.1.2; no Reown project ID is required. Run on an iPhone with the compatible wallet installed, enable Base Sepolia testnet, and fund the poster wallet with test ETH and [Circle faucet USDC](https://faucet.circle.com/). Configure the phone's reachable backend URL as described in [STRIPE_SETUP.md](../STRIPE_SETUP.md).

1. Post a job and select **Test USDC**.
2. Connect the poster wallet. The backend registers the job's immutable terms.
3. Authorize approval of the exact job amount, then authorize the escrow deposit.
4. The backend verifies the contract, job ID, poster, amount, event, and confirmed chain state before setting `funded` and appending one funding ledger entry.

An approval transaction cannot fund a job. A rejected or reverted deposit leaves it `draft`. The phone persists the pending job ID before requesting payment, and the backend polls confirmed escrow events, so it can recover after the app closes.

## Release, refund, and reconcile

A worker connects their payout wallet in Earnings and signs a one-time, expiring challenge bound to their worker ID and wallet address. Assignment freezes that verified destination. Trusted backend decisions call the same `/admin/jobs/:id/assign`, `/review`, `/approve`, and `/refund` endpoints as Stripe; see [STRIPE_SETUP.md](../STRIPE_SETUP.md).

The backend persists each exact signed arbiter transaction before sending it. RPC retries reuse the same nonce/hash. A new transaction is allowed only after the prior transaction is confirmed reverted, with reverted hashes retained for inspection. Confirmed Released/Refunded events atomically update the terminal ledger and status. If a poster refund wins against a release, reconciliation records only the actual refund. `GET /admin/jobs/:id/audit` checks confirmed contract terms, state, worker, and transaction references. Earnings recheck released transactions before displaying them.

After the deadline, Jobs → Posted → job details offers **Refund expired job** for funded, unreleased USDC jobs. It requires the wallet that originally funded the job; the contract enforces that permission independently. The backend deadline scheduler can also refund using the arbiter.

The Solidity deployment script is an alternative for an existing Foundry environment. The npm deployment script additionally persists signed transactions and backend configuration. Contract ABI artifacts are generated under ignored `out/`; the backend's checked-in `escrow-abi.mjs` supplies the app's calldata. This is testnet code, not an audited production escrow.
