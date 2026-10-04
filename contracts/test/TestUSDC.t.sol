// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
import {Test} from "forge-std/Test.sol";
import {BountyEscrow} from "../src/BountyEscrow.sol";
import {TestUSDC} from "../src/TestUSDC.sol";

contract TestUSDCTest is Test {
    TestUSDC token;
    address poster = address(0xA11CE);
    address worker = address(0xB0B);

    function setUp() public {
        vm.chainId(84532);
        token = new TestUSDC();
    }

    function test_AnyoneMintsUpToTheCap() public {
        vm.prank(poster);
        token.mint(poster, 500e6);
        assertEq(token.balanceOf(poster), 500e6);
        assertEq(token.totalSupply(), 500e6);
        vm.expectRevert(TestUSDC.MintTooLarge.selector);
        token.mint(poster, 10_001e6);
    }

    function test_RefusesMainnets() public {
        vm.chainId(8453);
        vm.expectRevert();
        new TestUSDC();
    }

    function test_WorksWithTheEscrow() public {
        BountyEscrow escrow = new BountyEscrow(address(token), address(this));
        bytes32 jobId = keccak256("job");
        escrow.registerJob(jobId, poster, 15e6, uint64(block.timestamp + 1 days));
        token.mint(poster, 15e6);
        vm.startPrank(poster);
        token.approve(address(escrow), 15e6);
        escrow.deposit(jobId);
        vm.stopPrank();
        escrow.release(jobId, worker);
        assertEq(token.balanceOf(worker), 15e6);
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    function test_TransferFromNeedsAllowanceAndBalance() public {
        token.mint(poster, 5e6);
        vm.expectRevert(TestUSDC.InsufficientAllowance.selector);
        token.transferFrom(poster, worker, 1e6);
        vm.prank(poster);
        token.approve(address(this), 10e6);
        vm.expectRevert(TestUSDC.InsufficientBalance.selector);
        token.transferFrom(poster, worker, 6e6);
    }
}
