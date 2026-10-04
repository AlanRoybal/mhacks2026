import { createPublicClient, createWalletClient, http, encodeFunctionData, keccak256, decodeEventLog, getAddress } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { baseSepolia, foundry } from 'viem/chains';
import { escrowABI, tokenABI, BASE_SEPOLIA_USDC, chainJobID } from './escrow-abi.mjs';
import { validateDraft, PaymentError } from './payments.mjs';

const sameAddress = (a, b) => typeof a === 'string' && typeof b === 'string' && a.toLowerCase() === b.toLowerCase();
export class CryptoPayments {
  constructor({ store, rpcURL, address, privateKey, token = BASE_SEPOLIA_USDC, confirmations = 2, deploymentBlock = 0, local = false }) {
    this.store = store; this.address = getAddress(address); this.token = getAddress(token);
    this.chain = local ? foundry : baseSepolia;
    if (!local && !sameAddress(token, BASE_SEPOLIA_USDC)) throw new Error('Use Circle’s Base Sepolia USDC.');
    this.account = privateKeyToAccount(privateKey);
    this.public = createPublicClient({ chain: this.chain, transport: http(rpcURL, { timeout: 15_000, retryCount: 1 }) });
    this.wallet = createWalletClient({ account: this.account, chain: this.chain, transport: http(rpcURL, { timeout: 15_000, retryCount: 1 }) });
    this.confirmations = confirmations; this.deploymentBlock = BigInt(deploymentBlock);
    this.queue = Promise.resolve();
  }
  async ready() {
    if (await this.public.getChainId() !== this.chain.id) throw new PaymentError(503, 'The RPC is connected to the wrong chain.');
    const [token, arbiter] = await Promise.all([
      this.public.readContract({ address: this.address, abi: escrowABI, functionName: 'token' }),
      this.public.readContract({ address: this.address, abi: escrowABI, functionName: 'arbiter' }),
    ]);
    if (!sameAddress(token, this.token) || !sameAddress(arbiter, this.account.address)) {
      throw new PaymentError(503, 'The escrow token or arbiter does not match the backend configuration.');
    }
  }
  async read(job, confirmed = true) {
    const block = await this.public.getBlockNumber({ cacheTime: 0 });
    const blockNumber = confirmed ? block - BigInt(Math.min(this.confirmations - 1, Number(block))) : block;
    const [poster, worker, amount, deadline, state] = await this.public.readContract({ address: this.address,
      abi: escrowABI, functionName: 'jobs', args: [job.chainJobID], blockNumber });
    return { poster, worker, amount, deadline, state, blockNumber };
  }
  checkTerms(job, actual) {
    if (job.chainID !== this.chain.id || !sameAddress(job.escrowAddress, this.address) || !sameAddress(job.tokenAddress, this.token)
        || !sameAddress(job.posterWallet, actual.poster) || actual.amount !== BigInt(job.amountUnits)
        || actual.deadline !== BigInt(Math.floor(new Date(job.deadline).getTime() / 1000))) {
      throw new PaymentError(409, 'On-chain escrow terms do not match this job.');
    }
  }
  async writeOnce(key, functionName, args) {
    const work = async () => {
      await this.ready();
      let saved = this.store.chainWrite(key);
      if (saved && (saved.chainID !== this.chain.id || saved.functionName !== functionName || !sameAddress(saved.escrowAddress, this.address)
          || saved.data !== encodeFunctionData({ abi: escrowABI, functionName, args }))) throw new PaymentError(409, 'Conflicting persisted chain operation.');
      let previousReceipt;
      if (saved) {
        try { previousReceipt = await this.public.getTransactionReceipt({ hash: saved.hash }); } catch {}
        if (previousReceipt?.status === 'reverted') {
          // A confirmed revert moved no funds. Only then may we sign a new nonce.
          await this.public.waitForTransactionReceipt({ hash: saved.hash, confirmations: this.confirmations, timeout: 45_000 });
        }
      }
      const previous = saved;
      if (previousReceipt?.status === 'reverted') saved = null;
      if (!saved) {
        const request = await this.wallet.prepareTransactionRequest({ account: this.account, chain: this.chain,
          to: this.address, data: encodeFunctionData({ abi: escrowABI, functionName, args }) });
        const raw = await this.wallet.signTransaction(request);
        saved = { hash: keccak256(raw), raw, functionName, chainID: this.chain.id, escrowAddress: this.address,
          data: encodeFunctionData({ abi: escrowABI, functionName, args }),
          revertedAttempts: previous ? [...(previous.revertedAttempts ?? []), previous.hash] : [] };
        // Save the exact signed transaction before broadcast. Retrying reuses its nonce/hash.
        this.store.saveChainWrite(key, saved);
      }
      if (saved.chainID !== this.chain.id || saved.functionName !== functionName || !sameAddress(saved.escrowAddress, this.address)
          || saved.data !== encodeFunctionData({ abi: escrowABI, functionName, args })) throw new PaymentError(409, 'Conflicting persisted chain operation.');
      let receipt;
      try { receipt = await this.public.getTransactionReceipt({ hash: saved.hash }); } catch {}
      if (!receipt) {
        try { await this.wallet.sendRawTransaction({ serializedTransaction: saved.raw }); }
        catch (error) {
          const message = error.shortMessage ?? '';
          if (!/already known|nonce too low|known transaction/i.test(message)) throw error;
        }
      }
      receipt = await this.public.waitForTransactionReceipt({ hash: saved.hash, confirmations: this.confirmations, timeout: 45_000 });
      this.store.saveChainWrite(key, { ...saved, blockNumber: receipt.blockNumber.toString(), state: receipt.status });
      if (receipt.status !== 'success') throw new PaymentError(409, 'The escrow transaction reverted. Reconcile its on-chain outcome.');
      return receipt;
    };
    const run = this.queue.then(work);
    this.queue = run.catch(() => {});
    return run;
  }
  async prepare(input) {
    const draft = validateDraft(input);
    let posterWallet;
    try { posterWallet = getAddress(input.posterWallet); } catch { throw new PaymentError(400, 'Connect a valid poster wallet.'); }
    await this.ready();
    let job = this.store.get(draft.id);
    if (job && (job.fundingRail !== 'usdc' || !sameAddress(job.escrowAddress, this.address)
        || !sameAddress(job.posterWallet, posterWallet) || JSON.stringify(job.draft) !== JSON.stringify(draft))) {
      throw new PaymentError(409, 'This checkout belongs to another job or wallet.');
    }
    if (!job) job = this.store.save({ ...draft, draft, feeCents: 0, totalCents: draft.amountCents, currency: 'usdc',
      fundingRail: 'usdc', status: 'draft', posterWallet, chainJobID: chainJobID(draft.id), amountUnits: String(draft.amountCents * 10_000),
      chainID: this.chain.id, escrowAddress: this.address, tokenAddress: this.token });
    let actual = await this.read(job, false);
    if (actual.state === 0) {
      const receipt = await this.writeOnce(`${job.id}:register`, 'registerJob',
        [job.chainJobID, posterWallet, BigInt(job.amountUnits), BigInt(Math.floor(new Date(job.deadline).getTime() / 1000))]);
      job = this.store.save({ ...this.store.get(job.id), registrationBlock: receipt.blockNumber.toString() });
      actual = await this.read(job, false);
    }
    this.checkTerms(job, actual);
    await this.reconcile(job);
    job = this.store.get(job.id);
    return { job: this.publicJob(job), chainID: this.chain.id, tokenAddress: this.token, escrowAddress: this.address,
      amountUnits: job.amountUnits,
      approve: { to: this.token, data: encodeFunctionData({ abi: tokenABI, functionName: 'approve', args: [this.address, BigInt(job.amountUnits)] }) },
      deposit: { to: this.address, data: encodeFunctionData({ abi: escrowABI, functionName: 'deposit', args: [job.chainJobID] }) },
      refund: { to: this.address, data: encodeFunctionData({ abi: escrowABI, functionName: 'refund', args: [job.chainJobID] }) } };
  }
  publicJob(job) { const { draft, paymentIntentID, ...safe } = job; return safe; }
  async refundTransaction(id) {
    const job = this.store.get(id.toLowerCase());
    if (!job || job.fundingRail !== 'usdc') throw new PaymentError(404, 'USDC job not found.');
    await this.reconcile(job);
    const current = this.store.get(job.id);
    if (['draft', 'released', 'refunded'].includes(current.status) || new Date(job.deadline).getTime() > Date.now()) {
      throw new PaymentError(409, 'The job must be funded, unreleased, and past its deadline.');
    }
    return { to: this.address, data: encodeFunctionData({ abi: escrowABI, functionName: 'refund', args: [job.chainJobID] }) };
  }
  async confirm(id, hash) {
    const job = this.store.get(id.toLowerCase());
    if (!job || job.fundingRail !== 'usdc') throw new PaymentError(404, 'USDC job not found.');
    if (typeof hash !== 'string' || !/^0x[0-9a-f]{64}$/i.test(hash)) throw new PaymentError(400, 'A transaction hash is required.');
    const receipt = await this.public.waitForTransactionReceipt({ hash, confirmations: this.confirmations, timeout: 45_000 });
    if (receipt.status !== 'success') throw new PaymentError(409, 'The wallet transaction reverted. The job remains unfunded.');
    const event = receipt.logs.flatMap(log => {
      if (!sameAddress(log.address, this.address)) return [];
      try { return [decodeEventLog({ abi: escrowABI, data: log.data, topics: log.topics })]; } catch { return []; }
    }).find(event => ['Deposited', 'Refunded'].includes(event.eventName) && event.args.jobId === job.chainJobID);
    if (!event || !sameAddress(event.args.poster, job.posterWallet) || event.args.amount !== BigInt(job.amountUnits)) {
      throw new PaymentError(409, 'This transaction did not fund or refund the expected job.');
    }
    await this.reconcile(job);
    return this.publicJob(this.store.get(job.id));
  }
  async event(job, eventName, blockNumber) {
    const event = escrowABI.find(item => item.type === 'event' && item.name === eventName);
    const logs = await this.public.getLogs({ address: this.address, event, args: { jobId: job.chainJobID },
      fromBlock: BigInt(job.registrationBlock ?? this.deploymentBlock), toBlock: blockNumber, strict: true });
    if (logs.length !== 1) throw new PaymentError(409, 'Expected one confirmed escrow event for this job.');
    return logs[0];
  }
  async reconcile(job) {
    await this.ready();
    const actual = await this.read(job);
    if (actual.state < 1) return;
    this.checkTerms(job, actual);
    // A fast deposit+refund can arrive before the poller sees the funded state.
    if (actual.state >= 2 && job.status === 'draft') {
      const deposited = await this.event(job, 'Deposited', actual.blockNumber);
      this.store.transaction(() => {
        const current = this.store.get(job.id);
        if (current.status !== 'draft') return;
        this.store.appendFunding(current, { source: 'base-sepolia', stripeEventID: null, reference: deposited.transactionHash });
        current.status = 'funded'; current.fundingTransactionHash = deposited.transactionHash;
        this.store.save(current);
      });
    }
    job = this.store.get(job.id);
    if (actual.state === 3 && job.status !== 'released') {
      if (!sameAddress(actual.worker, job.workerDestination)) throw new PaymentError(409, 'The on-chain recipient does not match the assigned worker.');
      const released = await this.event(job, 'Released', actual.blockNumber);
      this.settlements.finish(job.id, 'release', released.transactionHash, { source: 'base-sepolia', destination: actual.worker });
    }
    if (actual.state === 4 && job.status !== 'refunded') {
      const refunded = await this.event(job, 'Refunded', actual.blockNumber);
      this.settlements.finish(job.id, 'refund', refunded.transactionHash, { source: 'base-sepolia', destination: actual.poster });
    }
  }
  async settle(job, operation) {
    await this.reconcile(job);
    if (['released', 'refunded'].includes(this.store.get(job.id).status)) return;
    try {
      await this.writeOnce(`${job.id}:${operation.kind}`, operation.kind === 'release' ? 'release' : 'refund',
        operation.kind === 'release' ? [job.chainJobID, operation.destination] : [job.chainJobID]);
    } catch (error) {
      // A poster's deadline refund may win while an approved release is in flight.
      await this.reconcile(this.store.get(job.id));
      if (!['released', 'refunded'].includes(this.store.get(job.id).status)) throw error;
      return;
    }
    await this.reconcile(this.store.get(job.id));
  }
  async reconcileAll() {
    for (const job of this.store.list().filter(job => job.fundingRail === 'usdc' && !['released', 'refunded'].includes(job.status))) {
      try { await this.reconcile(job); } catch { /* Retry next polling cycle; audit reports unresolved state. */ }
    }
  }
  async status(id) {
    const job = this.store.get(id.toLowerCase());
    if (!job || job.fundingRail !== 'usdc') throw new PaymentError(404, 'USDC job not found.');
    await this.reconcile(job);
    return this.publicJob(this.store.get(job.id));
  }
  async audit(job) {
    await this.ready();
    const actual = await this.read(job);
    const issues = [];
    try { this.checkTerms(job, actual); } catch { issues.push('Escrow terms do not match the ledger.'); }
    const expected = job.status === 'released' ? 3 : job.status === 'refunded' ? 4 : job.status === 'draft' ? 1 : 2;
    if (actual.state !== expected) issues.push('Confirmed escrow state does not match the job status.');
    if (actual.state === 3 && !sameAddress(actual.worker, job.workerDestination)) issues.push('Escrow paid a different recipient.');
    if (job.settlementReference) {
      try {
        const event = await this.event(job, job.status === 'released' ? 'Released' : 'Refunded', actual.blockNumber);
        if (event.transactionHash !== job.settlementReference) issues.push('Settlement transaction does not match its ledger reference.');
      } catch { issues.push('Settlement event missing on chain.'); }
    }
    return issues;
  }
}
