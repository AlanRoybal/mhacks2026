// Mints TestUSDC (ESCROW_TOKEN_ADDRESS) to a wallet on Base Sepolia, paid for by the arbiter's test ETH.
//   npm run mint:test-usdc -- 0xYourWallet 500
import { createPublicClient, createWalletClient, http, getAddress, parseUnits, formatUnits, parseAbi } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { baseSepolia } from 'viem/chains';

const [to, amount = '500'] = process.argv.slice(2);
const token = process.env.ESCROW_TOKEN_ADDRESS;
if (!token) throw new Error('No ESCROW_TOKEN_ADDRESS in .env.chain. Run npm run deploy:test-token first.');
if (!to) throw new Error('Usage: npm run mint:test-usdc -- <wallet address> [amount, default 500]');
const abi = parseAbi(['function mint(address to, uint256 amount)', 'function balanceOf(address) view returns (uint256)', 'function MAX_MINT() view returns (uint256)']);
const account = privateKeyToAccount(process.env.ESCROW_ARBITER_PRIVATE_KEY);
const rpc = process.env.BASE_SEPOLIA_RPC_URL ?? 'https://sepolia.base.org';
const publicClient = createPublicClient({ chain: baseSepolia, transport: http(rpc) });
const wallet = createWalletClient({ account, chain: baseSepolia, transport: http(rpc) });

const recipient = getAddress(to);
let remaining = parseUnits(amount, 6);
const cap = await publicClient.readContract({ address: token, abi, functionName: 'MAX_MINT' });
while (remaining > 0n) {
  const chunk = remaining > cap ? cap : remaining;
  const hash = await wallet.writeContract({ address: token, abi, functionName: 'mint', args: [recipient, chunk] });
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  if (receipt.status !== 'success') throw new Error(`Mint reverted: ${hash}`);
  remaining -= chunk;
}
const balance = await publicClient.readContract({ address: token, abi, functionName: 'balanceOf', args: [recipient] });
console.log(`Minted ${amount} tUSDC to ${recipient}. Balance: ${formatUnits(balance, 6)} tUSDC`);
