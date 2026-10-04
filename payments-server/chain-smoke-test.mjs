import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { randomUUID } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { setTimeout as delay } from 'node:timers/promises';
import { createPublicClient, createWalletClient, createTestClient, http, bytesToHex, encodeFunctionData } from 'viem';
import { mnemonicToAccount } from 'viem/accounts';
import { foundry } from 'viem/chains';
import { JobStore } from './payments.mjs';
import { Workers } from './workers.mjs';
import { Settlements } from './settlements.mjs';
import { CryptoPayments } from './crypto.mjs';
import { tokenABI, escrowABI } from './escrow-abi.mjs';

// These are Anvil's public, disposable test accounts. Never use them on public networks.
const mnemonic = 'test test test test test test test test test test test junk';
const arbiter = mnemonicToAccount(mnemonic), poster = mnemonicToAccount(mnemonic, { addressIndex: 1 }),
  recipient = mnemonicToAccount(mnemonic, { addressIndex: 2 });
const port = 18545, rpcURL = `http://127.0.0.1:${port}`;
const anvil = spawn(fileURLToPath(new URL('./node_modules/.bin/anvil', import.meta.url)), ['--port', String(port), '--chain-id', '31337', '--silent'], { stdio: 'ignore' });
const store = new JobStore();
try {
  for (let attempt = 0; ; attempt++) {
    try { if ((await fetch(rpcURL, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}' })).ok) break; } catch {}
    if (attempt >= 30) throw new Error('Local Anvil did not start.');
    await delay(100);
  }
  const publicClient = createPublicClient({ chain: foundry, transport: http(rpcURL) });
  const testClient = createTestClient({ chain: foundry, mode: 'anvil', transport: http(rpcURL) });
  const wallet = account => createWalletClient({ account, chain: foundry, transport: http(rpcURL) });
  const artifact = name => JSON.parse(readFileSync(new URL(`../contracts/out/${name}.sol/${name}.json`, import.meta.url), 'utf8'));
  const deploy = async (name, args = []) => {
    const compiled = artifact(name);
    const hash = await wallet(arbiter).deployContract({ abi: compiled.abi, bytecode: compiled.bytecode.object, args });
    return (await publicClient.waitForTransactionReceipt({ hash })).contractAddress;
  };
  const token = await deploy('MockUSDC'), address = await deploy('BountyEscrow', [token, arbiter.address]);
  const mock = artifact('MockUSDC').abi;
  await wallet(arbiter).writeContract({ address: token, abi: mock, functionName: 'mint', args: [poster.address, 100_000_000n] });
  const crypto = new CryptoPayments({ store, rpcURL, address, token, local: true, confirmations: 1,
    privateKey: bytesToHex(arbiter.getHdKey().privateKey) });
  const workers = new Workers({ store });
  const session = workers.create(), challenge = workers.challenge(session.worker, recipient.address);
  await workers.verifyWallet(workers.get(session.worker.id), await recipient.signMessage({ message: challenge.message }));
  const settlements = new Settlements({ store, workers, crypto }); crypto.settlements = settlements;
  const prepare = () => crypto.prepare({ id: randomUUID(), title: 'USDC local checkout', details: 'Confirmed test token movement.', category: 'Technology',
    isRemote: true, deadline: new Date(Date.now() + 3600_000).toISOString(), amountCents: 1500, posterWallet: poster.address });
  const send = tx => wallet(poster).sendTransaction({ to: tx.to, data: tx.data, value: 0n });
  const fund = async prepared => {
    const approval = await send(prepared.approve);
    await assert.rejects(crypto.confirm(prepared.job.id, approval), { status: 409 });
    assert.equal(store.get(prepared.job.id).status, 'draft');
    const deposit = await send(prepared.deposit);
    await crypto.confirm(prepared.job.id, deposit);
    await crypto.confirm(prepared.job.id, deposit);
    assert.equal(store.get(prepared.job.id).status, 'funded');
    assert.equal(store.ledgerEvents(prepared.job.id).filter(event => event.type === 'JOB_FUNDED').length, 1);
    assert.equal(store.ledgerEvents(prepared.job.id)[0].reference, deposit);
  };
  const balance = owner => publicClient.readContract({ address: token, abi: tokenABI, functionName: 'balanceOf', args: [owner] });
  const paid = await prepare(); await fund(paid);
  await settlements.assign(paid.job.id, session.worker.id); settlements.review(paid.job.id);
  await Promise.all([settlements.settle(paid.job.id, 'release'), settlements.settle(paid.job.id, 'release')]);
  assert.equal(await balance(recipient.address), 15_000_000n);
  assert.equal(settlements.earnings(session.worker.id).totals.usdc.releasedCents, 1500);
  assert.equal((await settlements.audit(paid.job.id)).consistent, true);
  const retryable = await prepare(); await fund(retryable);
  await settlements.assign(retryable.job.id, session.worker.id); settlements.review(retryable.job.id);
  settlements.reserve(retryable.job.id, 'release');
  await wallet(arbiter).writeContract({ address: token, abi: mock, functionName: 'setFail', args: [true] });
  const data = encodeFunctionData({ abi: escrowABI, functionName: 'release', args: [retryable.job.chainJobID, recipient.address] });
  const raw = await wallet(arbiter).signTransaction(await wallet(arbiter).prepareTransactionRequest({ to: address, data, gas: 500_000n }));
  const revertedHash = await wallet(arbiter).sendRawTransaction({ serializedTransaction: raw });
  assert.equal((await publicClient.waitForTransactionReceipt({ hash: revertedHash })).status, 'reverted');
  store.saveChainWrite(`${retryable.job.id}:release`, { hash: revertedHash, raw, functionName: 'release', chainID: 31337, escrowAddress: address, data });
  await wallet(arbiter).writeContract({ address: token, abi: mock, functionName: 'setFail', args: [false] });
  await settlements.settle(retryable.job.id, 'release');
  assert.equal(await balance(recipient.address), 30_000_000n);
  assert.deepEqual(store.chainWrite(`${retryable.job.id}:release`).revertedAttempts, [revertedHash]);
  assert.equal(store.ledgerEvents(retryable.job.id).filter(event => event.type === 'JOB_RELEASED').length, 1);
  const canceled = await prepare(); // A rejected wallet request sends nothing.
  assert.equal(store.get(canceled.job.id).status, 'draft');
  assert.equal(store.ledgerEvents(canceled.job.id).length, 0);
  const refundable = await prepare(); await fund(refundable);
  const racing = await prepare(); await fund(racing);
  await settlements.assign(racing.job.id, session.worker.id); settlements.review(racing.job.id);
  const end = BigInt(Math.floor(new Date(racing.job.deadline).getTime() / 1000) + 1);
  await testClient.setNextBlockTimestamp({ timestamp: end }); await testClient.mine({ blocks: 1 });
  await send(refundable.refund); await crypto.reconcile(store.get(refundable.job.id));
  assert.equal(store.get(refundable.job.id).status, 'refunded');
  assert.equal((await settlements.audit(refundable.job.id)).consistent, true);
  const outcomes = await Promise.allSettled([settlements.settle(racing.job.id, 'release'), send(racing.refund)]);
  assert(outcomes.some(outcome => outcome.status === 'fulfilled'));
  await crypto.reconcile(store.get(racing.job.id));
  const terminal = store.get(racing.job.id).status;
  assert(['released', 'refunded'].includes(terminal));
  assert.equal(store.ledgerEvents(racing.job.id).filter(event => ['JOB_RELEASED', 'JOB_REFUNDED'].includes(event.type)).length, 1);
  assert.equal(await balance(address), 0n);
  assert.equal(await balance(poster.address) + await balance(recipient.address), 100_000_000n);
  assert.equal((await settlements.audit(racing.job.id)).consistent, true);
  console.log('Local chain passed: verified deposit, exact worker payment, confirmed-revert retry, poster deadline refund, rejected checkout, duplicate confirmation, release/refund race, token conservation, and ledger audits.');
} finally { store.close(); anvil.kill('SIGTERM'); }
