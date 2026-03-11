// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/AgentEscrowV2Fixed.sol";

contract MockERC20Fixed {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external { balanceOf[to] += amt; }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        require(balanceOf[from] >= amt, "insufficient balance");
        require(allowance[from][msg.sender] >= amt, "insufficient allowance");
        balanceOf[from]              -= amt;
        allowance[from][msg.sender]  -= amt;
        balanceOf[to]                += amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        require(balanceOf[msg.sender] >= amt, "insufficient balance");
        balanceOf[msg.sender] -= amt;
        balanceOf[to]         += amt;
        return true;
    }
}

contract AgentEscrowV2FixedTest is Test {

    AgentEscrowV2Fixed escrow;
    MockERC20Fixed     token;

    address arbiter = address(0xA7B1);
    address buyer   = address(0xBEEF);
    address seller  = address(0xCAFE);
    address alice   = address(0xABCD);

    uint256 constant AMOUNT   = 100e18;
    uint256 constant DEADLINE = 7 days;

    function setUp() public {
        escrow = new AgentEscrowV2Fixed(arbiter);
        token  = new MockERC20Fixed();
        token.mint(buyer, 1000e18);
        vm.prank(buyer);
        token.approve(address(escrow), type(uint256).max);
    }

    function _createJob() internal returns (uint256 jobId) {
        uint256[] memory empty;
        vm.prank(buyer);
        jobId = escrow.createJob(seller, address(token), AMOUNT, block.timestamp + DEADLINE, empty);
    }

    function _createJobWithMilestones(uint256[] memory ms) internal returns (uint256 jobId) {
        vm.prank(buyer);
        jobId = escrow.createJob(seller, address(token), AMOUNT, block.timestamp + DEADLINE, ms);
    }

    function _submitWork(uint256 jobId) internal {
        vm.prank(seller);
        escrow.submitWork(jobId, keccak256("deliverable-v1"));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Happy path
    // ═══════════════════════════════════════════════════════════════════════════

    function test_CreateJob() public {
        uint256 jobId = _createJob();
        AgentEscrowV2Fixed.Job memory j = escrow.getJob(jobId);
        assertEq(j.buyer, buyer);
        assertEq(j.seller, seller);
        assertEq(j.amount, AMOUNT);
        assertEq(token.balanceOf(address(escrow)), AMOUNT);
    }

    function test_BuyerRelease() public {
        uint256 jobId = _createJob();
        _submitWork(jobId);
        vm.prank(buyer); escrow.release(jobId);
        assertEq(token.balanceOf(seller), AMOUNT);
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    function test_AutoRelease() public {
        uint256 jobId = _createJob();
        _submitWork(jobId);
        vm.warp(block.timestamp + 48 hours + 1);
        escrow.autoRelease(jobId);
        assertEq(token.balanceOf(seller), AMOUNT);
    }

    function test_Refund() public {
        uint256 jobId = _createJob();
        vm.warp(block.timestamp + DEADLINE + 1);
        vm.prank(buyer); escrow.refund(jobId);
        assertEq(token.balanceOf(buyer), 1000e18);
    }

    function test_Dispute() public {
        uint256 jobId = _createJob();
        _submitWork(jobId);
        vm.prank(buyer); escrow.dispute(jobId);
        assertEq(uint8(escrow.getJob(jobId).status), uint8(AgentEscrowV2Fixed.Status.Disputed));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // FIX 1: Milestone double-payment — MUST PASS NOW
    // ═══════════════════════════════════════════════════════════════════════════

    function test_FIX_MilestoneDoubleSpend_NoLongerDrainsVictim() public {
        uint256[] memory ms = new uint256[](2);
        ms[0] = 50e18; ms[1] = 50e18;
        uint256 job0 = _createJobWithMilestones(ms);

        // Victim job (innocent user)
        address buyer2 = address(0xDEAD);
        token.mint(buyer2, AMOUNT);
        vm.prank(buyer2); token.approve(address(escrow), type(uint256).max);
        uint256[] memory empty;
        vm.prank(buyer2);
        escrow.createJob(seller, address(token), AMOUNT, block.timestamp + DEADLINE, empty);

        assertEq(token.balanceOf(address(escrow)), 200e18);

        // Release milestone 0
        vm.prank(buyer); escrow.releaseMilestone(job0);
        assertEq(token.balanceOf(seller), 50e18);
        assertEq(token.balanceOf(address(escrow)), 150e18);

        // Submit work
        _submitWork(job0);

        // Auto-release: should only send remaining 50, NOT drain victim
        vm.warp(block.timestamp + 48 hours + 1);
        escrow.autoRelease(job0);

        assertEq(token.balanceOf(seller), 100e18, "seller total = 50 + 50 = 100");
        assertEq(token.balanceOf(address(escrow)), 100e18, "victim job funds intact");
    }

    function test_FIX_Milestone_AllReleased_ThenSubmit_NoDoublePay() public {
        uint256[] memory ms = new uint256[](2);
        ms[0] = 50e18; ms[1] = 50e18;
        uint256 jobId = _createJobWithMilestones(ms);

        vm.prank(buyer); escrow.releaseMilestone(jobId); // 50
        vm.prank(buyer); escrow.releaseMilestone(jobId); // 50
        assertEq(token.balanceOf(seller), 100e18);
        assertEq(token.balanceOf(address(escrow)), 0);

        // Seller submits work after all milestones done
        _submitWork(jobId);

        vm.prank(buyer); escrow.release(jobId);

        // Seller should NOT receive anything extra
        assertEq(token.balanceOf(seller), 100e18, "no double payment");
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // FIX 2: Dispute resolution via arbiter
    // ═══════════════════════════════════════════════════════════════════════════

    function test_FIX_ArbiterResolvesDisputeForSeller() public {
        uint256 jobId = _createJob();
        _submitWork(jobId);
        vm.prank(buyer); escrow.dispute(jobId);

        vm.prank(arbiter); escrow.resolveDispute(jobId, true);

        assertEq(token.balanceOf(seller), AMOUNT, "seller wins dispute");
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    function test_FIX_ArbiterResolvesDisputeForBuyer() public {
        uint256 jobId = _createJob();
        _submitWork(jobId);
        vm.prank(buyer); escrow.dispute(jobId);

        vm.prank(arbiter); escrow.resolveDispute(jobId, false);

        assertEq(token.balanceOf(buyer), 1000e18, "buyer wins dispute, refunded");
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    function test_Revert_ResolveDispute_NotArbiter() public {
        uint256 jobId = _createJob();
        _submitWork(jobId);
        vm.prank(buyer); escrow.dispute(jobId);

        vm.prank(alice);
        vm.expectRevert("Not arbiter");
        escrow.resolveDispute(jobId, true);
    }

    function test_Revert_ResolveDispute_NotDisputed() public {
        uint256 jobId = _createJob();
        vm.prank(arbiter);
        vm.expectRevert("Not disputed");
        escrow.resolveDispute(jobId, true);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // FIX 3: buyer == seller and zero-address now rejected
    // ═══════════════════════════════════════════════════════════════════════════

    function test_FIX_Revert_BuyerEqualsSeller() public {
        uint256[] memory empty;
        vm.prank(buyer);
        vm.expectRevert("Buyer cannot be seller");
        escrow.createJob(buyer, address(token), AMOUNT, block.timestamp + DEADLINE, empty);
    }

    function test_FIX_Revert_ZeroAddressSeller() public {
        uint256[] memory empty;
        vm.prank(buyer);
        vm.expectRevert("Invalid seller");
        escrow.createJob(address(0), address(token), AMOUNT, block.timestamp + DEADLINE, empty);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Regression: original happy path tests must still pass
    // ═══════════════════════════════════════════════════════════════════════════

    function test_Milestone_ThreeSlices_StillWorks() public {
        uint256[] memory ms = new uint256[](3);
        ms[0] = 25e18; ms[1] = 50e18; ms[2] = 25e18;
        uint256 jobId = _createJobWithMilestones(ms);

        vm.prank(buyer); escrow.releaseMilestone(jobId);
        assertEq(token.balanceOf(seller), 25e18);

        vm.prank(buyer); escrow.releaseMilestone(jobId);
        assertEq(token.balanceOf(seller), 75e18);

        vm.prank(buyer); escrow.releaseMilestone(jobId);
        assertEq(token.balanceOf(seller), 100e18);

        assertEq(token.balanceOf(address(escrow)), 0);
    }

    function testFuzz_MilestoneRemainder(uint96 pct) public {
        // pct in [1, 99] = first slice percentage
        pct = uint96(bound(pct, 1, 99));
        uint256 slice1 = AMOUNT * pct / 100;
        uint256 slice2 = AMOUNT - slice1;
        vm.assume(slice1 > 0 && slice2 > 0);

        uint256[] memory ms = new uint256[](2);
        ms[0] = uint256(slice1); ms[1] = uint256(slice2);
        uint256 jobId = _createJobWithMilestones(ms);

        // Release first milestone only
        vm.prank(buyer); escrow.releaseMilestone(jobId);

        // Submit and auto-release
        _submitWork(jobId);
        vm.warp(block.timestamp + 48 hours + 1);
        escrow.autoRelease(jobId);

        // Seller should have exactly job.amount total
        assertEq(token.balanceOf(seller), AMOUNT, "seller total always equals job.amount");
        assertEq(token.balanceOf(address(escrow)), 0);
    }
}
