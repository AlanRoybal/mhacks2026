import { parseAbi, keccak256, stringToHex } from 'viem';
export const BASE_SEPOLIA_USDC = '0x036CbD53842c5426634e7929541eC2318f3dCF7e';
export const escrowABI = parseAbi([
  'constructor(address token_, address arbiter_)',
  'function token() view returns (address)',
  'function arbiter() view returns (address)',
  'function jobs(bytes32) view returns (address poster, address worker, uint256 amount, uint64 deadline, uint8 state)',
  'function registerJob(bytes32 jobId, address poster, uint256 amount, uint64 deadline)',
  'function deposit(bytes32 jobId)',
  'function release(bytes32 jobId, address worker)',
  'function refund(bytes32 jobId)',
  'event Deposited(bytes32 indexed jobId, address indexed poster, uint256 amount)',
  'event Released(bytes32 indexed jobId, address indexed worker, uint256 amount)',
  'event Refunded(bytes32 indexed jobId, address indexed poster, uint256 amount)',
]);
export const tokenABI = parseAbi([
  'function approve(address spender, uint256 amount) returns (bool)',
  'function allowance(address owner, address spender) view returns (uint256)',
  'function balanceOf(address account) view returns (uint256)',
  'function decimals() view returns (uint8)',
]);
export const chainJobID = id => keccak256(stringToHex(`bounty:${id.toLowerCase()}`));
