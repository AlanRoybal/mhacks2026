// Deploys TestUSDC (contracts/src/TestUSDC.sol) to Base Sepolia and records ESCROW_TOKEN_ADDRESS in .env.chain.
// Then run `npm run deploy:sepolia` to deploy an escrow bound to it, and `npm run mint:test-usdc -- <wallet> 500`.
// Safe to repeat: an existing deployment is reused.
import { existsSync, readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { createPublicClient, createWalletClient, http, encodeDeployData, keccak256 } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { baseSepolia } from 'viem/chains';
import { tokenABI } from './escrow-abi.mjs';

const account = privateKeyToAccount(process.env.ESCROW_ARBITER_PRIVATE_KEY);
const rpc = process.env.BASE_SEPOLIA_RPC_URL ?? 'https://sepolia.base.org';
const publicClient = createPublicClient({ chain: baseSepolia, transport: http(rpc) });
const wallet = createWalletClient({ account, chain: baseSepolia, transport: http(rpc) });
if (await publicClient.getChainId() !== 84532) throw new Error('TestUSDC is for Base Sepolia only.');

mkdirSync(new URL('./data', import.meta.url), { recursive: true });
const path = new URL('./data/sepolia-test-usdc.json', import.meta.url);
let deployment = existsSync(path) ? JSON.parse(readFileSync(path, 'utf8')) : null;
if (!deployment) {
  const artifact = JSON.parse(readFileSync(new URL('../contracts/out/TestUSDC.sol/TestUSDC.json', import.meta.url), 'utf8'));
  const request = await wallet.prepareTransactionRequest({ account, chain: baseSepolia, data: encodeDeployData({ abi: artifact.abi, bytecode: artifact.bytecode.object }) });
  const raw = await wallet.signTransaction(request);
  deployment = { hash: keccak256(raw), raw, chainID: 84532, deployer: account.address };
  writeFileSync(path, JSON.stringify(deployment, null, 2), { mode: 0o600 });
}
let receipt;
try { receipt = await publicClient.getTransactionReceipt({ hash: deployment.hash }); } catch {}
if (!receipt) {
  try { await wallet.sendRawTransaction({ serializedTransaction: deployment.raw }); }
  catch (error) { if (!/already known|nonce too low/i.test(error.shortMessage ?? '')) throw error; }
}
receipt = await publicClient.waitForTransactionReceipt({ hash: deployment.hash, confirmations: 2 });
if (receipt.status !== 'success' || !receipt.contractAddress) throw new Error('TestUSDC deployment reverted.');
const address = receipt.contractAddress;
if (await publicClient.readContract({ address, abi: tokenABI, functionName: 'decimals' }) !== 6) throw new Error('Deployed token is not 6 decimals.');
writeFileSync(path, JSON.stringify({ ...deployment, contractAddress: address }, null, 2), { mode: 0o600 });

const envPath = new URL('./.env.chain', import.meta.url);
const env = readFileSync(envPath, 'utf8').replace(/^ESCROW_TOKEN_ADDRESS=.*\n?/m, '');
writeFileSync(envPath, `${env.endsWith('\n') ? env : `${env}\n`}ESCROW_TOKEN_ADDRESS=${address}\n`, { mode: 0o600 });
console.log(`TestUSDC deployed: ${address}`);
console.log('Next: npm run deploy:sepolia (an escrow bound to this token), then npm run mint:test-usdc -- <wallet> <amount>');
