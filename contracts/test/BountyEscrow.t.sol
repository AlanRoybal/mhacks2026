// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
import {Test} from "forge-std/Test.sol";
import {BountyEscrow} from "../src/BountyEscrow.sol";
import {MockUSDC} from "./MockUSDC.sol";

contract BountyEscrowTest is Test {
    BountyEscrow escrow;
    MockUSDC usdc;
    address poster = address(0xA11CE);
    address worker = address(0xB0B);
    bytes32 jobId = keccak256("job");
    uint256 amount = 15_000_000;
    uint64 deadline;

    function setUp() public {
        usdc = new MockUSDC();
        escrow = new BountyEscrow(address(usdc), address(this));
        deadline = uint64(block.timestamp + 1 days);
        escrow.registerJob(jobId, poster, amount, deadline);
        usdc.mint(poster, amount);
        vm.prank(poster); usdc.approve(address(escrow), amount);
    }
    function fund() internal { vm.prank(poster); escrow.deposit(jobId); }
    function state() internal view returns (BountyEscrow.State) { (,,,, BountyEscrow.State s) = escrow.jobs(jobId); return s; }
    function test_DepositHoldsExactUSDC() public {
        fund();
        assertEq(usdc.balanceOf(address(escrow)), amount);
        assertEq(uint8(state()), uint8(BountyEscrow.State.FUNDED));
    }
    function test_OnlyPosterCanDeposit() public {
        vm.expectRevert(BountyEscrow.Unauthorized.selector); escrow.deposit(jobId);
    }
    function test_OnlyArbiterRegistersAndReleases() public {
        vm.prank(worker); vm.expectRevert(BountyEscrow.Unauthorized.selector);
        escrow.registerJob(keccak256("other"), poster, amount, deadline);
        fund();
        vm.prank(poster); vm.expectRevert(BountyEscrow.Unauthorized.selector); escrow.release(jobId, worker);
    }
    function test_NoDuplicateDepositOrRegistration() public {
        vm.expectRevert(BountyEscrow.InvalidState.selector); escrow.registerJob(jobId, poster, amount, deadline);
        fund();
        vm.prank(poster); vm.expectRevert(BountyEscrow.InvalidState.selector); escrow.deposit(jobId);
    }
    function test_NoLateDeposit() public {
        vm.warp(deadline);
        vm.prank(poster); vm.expectRevert(BountyEscrow.InvalidState.selector); escrow.deposit(jobId);
    }
    function test_ReleasePaysOnlySelectedWorkerOnce() public {
        fund(); escrow.release(jobId, worker);
        assertEq(usdc.balanceOf(worker), amount);
        assertEq(usdc.balanceOf(address(escrow)), 0);
        vm.expectRevert(BountyEscrow.InvalidState.selector); escrow.release(jobId, worker);
    }
    function test_RefundOnlyAfterDeadlineAndOnlyPosterOrArbiter() public {
        fund();
        vm.prank(poster); vm.expectRevert(BountyEscrow.TooEarly.selector); escrow.refund(jobId);
        vm.warp(deadline);
        vm.prank(worker); vm.expectRevert(BountyEscrow.Unauthorized.selector); escrow.refund(jobId);
        vm.prank(poster); escrow.refund(jobId);
        assertEq(usdc.balanceOf(poster), amount);
        assertEq(uint8(state()), uint8(BountyEscrow.State.REFUNDED));
    }
    function test_ArbiterCanRefundForDeadlineScheduler() public {
        fund(); vm.warp(deadline); escrow.refund(jobId);
        assertEq(usdc.balanceOf(poster), amount);
    }
    function test_ReleaseThenRefundCannotPayTwice() public {
        fund(); vm.warp(deadline); escrow.release(jobId, worker);
        vm.prank(poster); vm.expectRevert(BountyEscrow.InvalidState.selector); escrow.refund(jobId);
        assertEq(usdc.balanceOf(worker), amount);
    }
    function test_RefundThenReleaseCannotPayTwice() public {
        fund(); vm.warp(deadline); vm.prank(poster); escrow.refund(jobId);
        vm.expectRevert(BountyEscrow.InvalidState.selector); escrow.release(jobId, worker);
        assertEq(usdc.balanceOf(poster), amount);
        assertEq(usdc.balanceOf(worker), 0);
    }
    function test_FailedTransfersRollBackState() public {
        usdc.setFail(true);
        vm.prank(poster); vm.expectRevert(BountyEscrow.TransferFailed.selector); escrow.deposit(jobId);
        assertEq(uint8(state()), uint8(BountyEscrow.State.REGISTERED));
        usdc.setFail(false); fund(); usdc.setFail(true);
        vm.expectRevert(BountyEscrow.TransferFailed.selector); escrow.release(jobId, worker);
        assertEq(uint8(state()), uint8(BountyEscrow.State.FUNDED));
    }
    function test_ShortDepositCannotFund() public {
        usdc.setShortTransfer(true);
        vm.prank(poster); vm.expectRevert(BountyEscrow.TransferFailed.selector); escrow.deposit(jobId);
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }
    function testFuzz_TerminalOutcomeIsExclusive(bool refundWins) public {
        fund(); vm.warp(deadline);
        if (refundWins) {
            vm.prank(poster); escrow.refund(jobId);
            vm.expectRevert(BountyEscrow.InvalidState.selector); escrow.release(jobId, worker);
        } else {
            escrow.release(jobId, worker);
            vm.prank(poster); vm.expectRevert(BountyEscrow.InvalidState.selector); escrow.refund(jobId);
        }
        assertEq(usdc.balanceOf(poster) + usdc.balanceOf(worker), amount);
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }
}
