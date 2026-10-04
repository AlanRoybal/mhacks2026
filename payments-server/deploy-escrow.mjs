import { existsSync, readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { createPublicClient, createWalletClient, http, encodeDeployData, keccak256 } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { baseSepolia } from 'viem/chains';
import { BASE_SEPOLIA_USDC, tokenABI, escrowABI } from './escrow-abi.mjs';

const account = privateKeyToAccount(process.env.ESCROW_ARBITER_PRIVATE_KEY);
const rpc = process.env.BASE_SEPOLIA_RPC_URL ?? 'https://sepolia.base.org';
const publicClient = createPublicClient({ chain: baseSepolia, transport: http(rpc) });
const wallet = createWalletClient({ account, chain: baseSepolia, transport: http(rpc) });
if (await publicClient.getChainId() !== 84532) throw new Error('Deployment is restricted to Base Sepolia.');
// ESCROW_TOKEN_ADDRESS (e.g. TestUSDC from deploy-test-token.mjs) binds a new escrow to a test token.
const token = process.env.ESCROW_TOKEN_ADDRESS ?? BASE_SEPOLIA_USDC;
if (await publicClient.readContract({ address: token, abi: tokenABI, functionName: 'decimals' }) !== 6) throw new Error('Unexpected USDC token.');
mkdirSync(new URL('./data', import.meta.url), { recursive: true });
const custom = token.toLowerCase() !== BASE_SEPOLIA_USDC.toLowerCase();
const path = new URL(custom ? `./data/sepolia-deployment-${token.slice(2, 10).toLowerCase()}.json` : './data/sepolia-deployment.json', import.meta.url);
let deployment = existsSync(path) ? JSON.parse(readFileSync(path, 'utf8')) : null;
if (!deployment) {
  if (await publicClient.getBalance({ address: account.address }) === 0n) {
    console.log(`Deployment waiting for faucet ETH on Base Sepolia: ${account.address}`);
    process.exit(2);
  }
  const artifact = JSON.parse(readFileSync(new URL('../contracts/out/BountyEscrow.sol/BountyEscrow.json', import.meta.url), 'utf8'));
  const request = await wallet.prepareTransactionRequest({ account, chain: baseSepolia,
    data: encodeDeployData({ abi: artifact.abi, bytecode: artifact.bytecode.object, args: [token, account.address] }) });
  const raw = await wallet.signTransaction(request);
  deployment = { hash: keccak256(raw), raw, chainID: 84532, arbiter: account.address, token };
  writeFileSync(path, JSON.stringify(deployment, null, 2), { mode: 0o600 });
}
if (deployment.chainID !== 84532 || deployment.arbiter !== account.address) throw new Error('Deployment record belongs to another signer or chain.');
let receipt;
try { receipt = await publicClient.getTransactionReceipt({ hash: deployment.hash }); } catch {}
if (!receipt) {
  try { await wallet.sendRawTransaction({ serializedTransaction: deployment.raw }); }
  catch (error) { if (!/already known|nonce too low/i.test(error.shortMessage ?? '')) throw error; }
}
receipt = await publicClient.waitForTransactionReceipt({ hash: deployment.hash, confirmations: 2 });
if (receipt.status !== 'success' || !receipt.contractAddress) throw new Error('Escrow deployment reverted.');
const address = receipt.contractAddress;
const arbiter = await publicClient.readContract({ address, abi: escrowABI, functionName: 'arbiter' });
if (arbiter.toLowerCase() !== account.address.toLowerCase()) throw new Error('Deployed arbiter does not match.');
writeFileSync(path, JSON.stringify({ ...deployment, contractAddress: address, deploymentBlock: receipt.blockNumber.toString() }, null, 2), { mode: 0o600 });
const envPath = new URL('./.env.chain', import.meta.url);
let env = readFileSync(envPath, 'utf8');
env = env.replace(/^ESCROW_CONTRACT_ADDRESS=.*$/m, `ESCROW_CONTRACT_ADDRESS=${address}`);
env = env.replace(/^ESCROW_DEPLOYMENT_BLOCK=.*\n?/m, '') + `ESCROW_DEPLOYMENT_BLOCK=${receipt.blockNumber}\n`;
env = env.replace(/^ESCROW_TOKEN_ADDRESS=.*\n?/m, '') + (custom ? `ESCROW_TOKEN_ADDRESS=${token}\n` : '');
writeFileSync(envPath, env, { mode: 0o600 });
console.log(`Base Sepolia escrow deployed and verified: ${address}`);
console.log(`Transaction: https://sepolia.basescan.org/tx/${deployment.hash}`);
