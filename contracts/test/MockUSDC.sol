// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @dev Local tests only. Public deployments use Circle's Base Sepolia USDC.
contract MockUSDC {
    uint8 public constant decimals = 6;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    bool public fail;
    bool public shortTransfer;
    function mint(address to, uint256 amount) external { balanceOf[to] += amount; }
    function setFail(bool value) external { fail = value; }
    function setShortTransfer(bool value) external { shortTransfer = value; }
    function approve(address spender, uint256 amount) external returns (bool) { allowance[msg.sender][spender] = amount; return true; }
    function transfer(address to, uint256 amount) external returns (bool) { return move(msg.sender, to, amount); }
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(allowance[from][msg.sender] >= amount, "allowance");
        allowance[from][msg.sender] -= amount;
        return move(from, to, amount);
    }
    function move(address from, address to, uint256 amount) private returns (bool) {
        if (fail) return false;
        require(balanceOf[from] >= amount, "balance");
        balanceOf[from] -= amount;
        balanceOf[to] += shortTransfer ? amount - 1 : amount;
        return true;
    }
}
