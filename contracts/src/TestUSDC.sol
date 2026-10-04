// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @notice Free-to-mint 6-decimal stand-in for USDC on Base Sepolia, so testers aren't limited by
/// faucet caps. Worthless by design: anyone can mint up to MAX_MINT per call. Never deploy to mainnet.
contract TestUSDC {
    string public constant name = "Bounty Test USDC";
    string public constant symbol = "tUSDC";
    uint8 public constant decimals = 6;
    uint256 public constant MAX_MINT = 10_000e6;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    error MintTooLarge();
    error InsufficientBalance();
    error InsufficientAllowance();

    constructor() {
        if (block.chainid == 1 || block.chainid == 8453) revert();
    }

    function mint(address to, uint256 amount) external {
        if (amount > MAX_MINT) revert MintTooLarge();
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed < amount) revert InsufficientAllowance();
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) private {
        if (balanceOf[from] < amount) revert InsufficientBalance();
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}
