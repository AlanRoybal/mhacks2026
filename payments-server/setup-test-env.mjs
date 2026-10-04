import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { randomBytes } from 'node:crypto';
import { generatePrivateKey, privateKeyToAccount } from 'viem/accounts';

const path = new URL('./.env.chain', import.meta.url);
const existing = existsSync(path) ? readFileSync(path, 'utf8') : '';
let content = existing;
const add = (name, value) => {
  if (!new RegExp(`^${name}=`, 'm').test(content)) content += `${name}=${value}\n`;
};
add('ESCROW_ARBITER_PRIVATE_KEY', generatePrivateKey());
add('BOUNTY_ADMIN_TOKEN', randomBytes(32).toString('hex'));
add('BASE_SEPOLIA_RPC_URL', 'https://sepolia.base.org');
add('ESCROW_CONTRACT_ADDRESS', '');
writeFileSync(path, content, { mode: 0o600 });
const key = content.match(/^ESCROW_ARBITER_PRIVATE_KEY=(.+)$/m)[1];
console.log(`Dedicated test signer: ${privateKeyToAccount(key).address}`);
console.log('Private key and admin token saved in ignored payments-server/.env.chain. No credentials were printed.');
