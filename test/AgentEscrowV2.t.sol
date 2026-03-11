// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/AgentEscrowV2.sol";

// ─── Minimal ERC20 mock ────────────────────────────────────────────────────────
contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    string public name = "MockToken";

    function mint(address to, uint256 amt) external { balanceOf[to] += amt; }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        require(balanceOf[from] >= amt, "insufficient balance");
        require(allowance[from][msg.sender] >= amt, "insufficient allowance");
        balanceOf[from]    -= amt;
        allowance[from][msg.sender] -= amt;
        balanceOf[to]      += amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        require(balanceOf[msg.sender] >= amt, "insufficient balance");
        balanceOf[msg.sender] -= amt;
        balanceOf[to]         += amt;
        return true;
    }
}

// ─── Main test suite ──────────────────────────────────────────────────────────
contract AgentEscrowV2Test is Test {

    AgentEscrowV2 escrow;
    MockERC20     token;

    address buyer  = address(0xBEEF);
    address seller = address(0xCAFE);
    address alice  = address(0xABCD); // third party

    uint256 constant AMOUNT   = 100e18;
    uint256 constant DEADLINE = 7 days;

    function setUp() public {
        escrow = new AgentEscrowV2();
        token  = new MockERC20();

        // Fund buyer
        token.mint(buyer, 1000e18);
        vm.prank(buyer);
        token.approve(address(escrow), type(uint256).max);
    }

    // ─── Helper ───────────────────────────────────────────────────────────────

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
    // SECTION 1 — Happy path
    // ═══════════════════════════════════════════════════════════════════════════

    function test_CreateJob() public {
        uint256 jobId = _createJob();
        AgentEscrowV2.Job memory j = escrow.getJob(jobId);
        assertEq(j.buyer,  buyer);
        assertEq(j.seller, seller);
        assertEq(j.amount, AMOUNT);
        assertEq(uint8(j.status), uint8(AgentEscrowV2.Status.Created));
        assertEq(token.balanceOf(address(escrow)), AMOUNT, "escrow holds funds");
    }

    function test_SubmitWork() public {
        uint256 jobId = _createJob();
        bytes32 h = keccak256("my work");
        vm.prank(seller);
        escrow.submitWork(jobId, h);

        AgentEscrowV2.Job memory j = escrow.getJob(jobId);
        assertEq(j.workHash, h);
        assertEq(uint8(j.status), uint8(AgentEscrowV2.Status.WorkSubmitted));
    }

    function test_BuyerRelease() public {
        uint256 jobId = _createJob();
        _submitWork(jobId);

        vm.prank(buyer);
        escrow.release(jobId);

        assertEq(token.balanceOf(seller),          AMOUNT, "seller paid");
        assertEq(token.balanceOf(address(escrow)), 0,      "escrow empty");
        assertEq(uint8(escrow.getJob(jobId).status), uint8(AgentEscrowV2.Status.Released));
    }

    function test_AutoRelease() public {
        uint256 jobId = _createJob();
        _submitWork(jobId);

        vm.warp(block.timestamp + 48 hours + 1);
        escrow.autoRelease(jobId);

        assertEq(token.balanceOf(seller), AMOUNT);
    }

    function test_Refund_OnNoShow() public {
        uint256 jobId = _createJob();
        vm.warp(block.timestamp + DEADLINE + 1);

        vm.prank(buyer);
        escrow.refund(jobId);

        assertEq(token.balanceOf(buyer),           1000e18, "buyer refunded");
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    function test_Dispute() public {
        uint256 jobId = _createJob();
        _submitWork(jobId);

        vm.prank(buyer);
        escrow.dispute(jobId);

        assertEq(uint8(escrow.getJob(jobId).status), uint8(AgentEscrowV2.Status.Disputed));
        // funds still locked
        assertEq(token.balanceOf(address(escrow)), AMOUNT);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 2 — Access control
    // ═══════════════════════════════════════════════════════════════════════════

    function test_Revert_SubmitWork_NotSeller() public {
        uint256 jobId = _createJob();
        vm.prank(alice);
        vm.expectRevert("Not seller");
        escrow.submitWork(jobId, keccak256("x"));
    }

    function test_Revert_Release_NotBuyer() public {
        uint256 jobId = _createJob();
        _submitWork(jobId);
        vm.prank(alice);
        vm.expectRevert("Not buyer");
        escrow.release(jobId);
    }

    function test_Revert_Refund_NotBuyer() public {
        uint256 jobId = _createJob();
        vm.warp(block.timestamp + DEADLINE + 1);
        vm.prank(alice);
        vm.expectRevert("Not buyer");
        escrow.refund(jobId);
    }

    function test_Revert_Dispute_NotBuyer() public {
        uint256 jobId = _createJob();
        _submitWork(jobId);
        vm.prank(alice);
        vm.expectRevert("Not buyer");
        escrow.dispute(jobId);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 3 — State machine guards
    // ═══════════════════════════════════════════════════════════════════════════

    function test_Revert_SubmitWork_AfterDeadline() public {
        uint256 jobId = _createJob();
        vm.warp(block.timestamp + DEADLINE + 1);
        vm.prank(seller);
        vm.expectRevert("Deadline passed");
        escrow.submitWork(jobId, keccak256("late"));
    }

    function test_Revert_SubmitWork_AlreadySubmitted() public {
        uint256 jobId = _createJob();
        _submitWork(jobId);
        vm.prank(seller);
        vm.expectRevert("Already submitted");
        escrow.submitWork(jobId, keccak256("again"));
    }

    function test_Revert_Release_WorkNotSubmitted() public {
        uint256 jobId = _createJob();
        vm.prank(buyer);
        vm.expectRevert("Work not submitted");
        escrow.release(jobId);
    }

    function test_Revert_AutoRelease_WindowOpen() public {
        uint256 jobId = _createJob();
        _submitWork(jobId);
        vm.prank(alice);
        vm.expectRevert("Window still open");
        escrow.autoRelease(jobId);
    }

    function test_Revert_Dispute_WindowClosed() public {
        uint256 jobId = _createJob();
        _submitWork(jobId);
        vm.warp(block.timestamp + 48 hours + 1);
        vm.prank(buyer);
        vm.expectRevert("Window closed");
        escrow.dispute(jobId);
    }

    function test_Revert_Refund_WorkWasSubmitted() public {
        uint256 jobId = _createJob();
        _submitWork(jobId);
        vm.warp(block.timestamp + DEADLINE + 1);
        vm.prank(buyer);
        vm.expectRevert("Work was submitted");
        escrow.refund(jobId);
    }

    function test_Revert_Refund_DeadlineNotPassed() public {
        uint256 jobId = _createJob();
        vm.prank(buyer);
        vm.expectRevert("Deadline not passed");
        escrow.refund(jobId);
    }

    function test_Revert_CreateJob_DeadlineInPast() public {
        uint256[] memory empty;
        vm.prank(buyer);
        vm.expectRevert("Deadline in past");
        escrow.createJob(seller, address(token), AMOUNT, block.timestamp - 1, empty);
    }

    function test_Revert_CreateJob_ZeroAmount() public {
        uint256[] memory empty;
        vm.prank(buyer);
        vm.expectRevert("Amount zero");
        escrow.createJob(seller, address(token), 0, block.timestamp + DEADLINE, empty);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 4 — Milestone happy path
    // ═══════════════════════════════════════════════════════════════════════════

    function test_Milestone_ThreeSlices() public {
        uint256[] memory ms = new uint256[](3);
        ms[0] = 25e18; ms[1] = 50e18; ms[2] = 25e18;
        uint256 jobId = _createJobWithMilestones(ms);

        // Release slice 0
        vm.prank(buyer);
        escrow.releaseMilestone(jobId);
        assertEq(token.balanceOf(seller), 25e18);

        // Release slice 1
        vm.prank(buyer);
        escrow.releaseMilestone(jobId);
        assertEq(token.balanceOf(seller), 75e18);

        // Release slice 2
        vm.prank(buyer);
        escrow.releaseMilestone(jobId);
        assertEq(token.balanceOf(seller), 100e18);

        assertEq(token.balanceOf(address(escrow)), 0);
    }

    function test_Milestone_SumValidation() public {
        uint256[] memory ms = new uint256[](2);
        ms[0] = 60e18; ms[1] = 60e18; // 120 != 100
        vm.prank(buyer);
        vm.expectRevert("Milestones != amount");
        escrow.createJob(seller, address(token), AMOUNT, block.timestamp + DEADLINE, ms);
    }

    function test_Revert_ReleaseMilestone_NoMilestones() public {
        uint256 jobId = _createJob();
        vm.prank(buyer);
        vm.expectRevert("No milestones");
        escrow.releaseMilestone(jobId);
    }

    function test_Revert_ReleaseMilestone_AllReleased() public {
        uint256[] memory ms = new uint256[](1);
        ms[0] = AMOUNT;
        uint256 jobId = _createJobWithMilestones(ms);

        vm.prank(buyer); escrow.releaseMilestone(jobId);
        vm.prank(buyer);
        vm.expectRevert("All milestones released");
        escrow.releaseMilestone(jobId);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 5 — SECURITY: Critical vulnerability tests
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice CRITICAL BUG: Milestone partial releases + autoRelease/release = double payment.
    /// Seller gets milestone slice, then gets full job.amount again on release.
    /// This drains funds from OTHER jobs in the contract.
    function test_CRITICAL_MilestoneDoubleSpend() public {
        // Setup: two jobs in the contract so there are extra funds to drain
        uint256[] memory ms = new uint256[](2);
        ms[0] = 50e18; ms[1] = 50e18;

        // Job 0: milestone job (attacker / accidental)
        uint256 job0 = _createJobWithMilestones(ms);

        // Job 1: innocent victim job (separate buyer)
        address buyer2 = address(0xDEAD);
        token.mint(buyer2, AMOUNT);
        vm.prank(buyer2);
        token.approve(address(escrow), type(uint256).max);
        uint256[] memory empty;
        vm.prank(buyer2);
        uint256 job1 = escrow.createJob(seller, address(token), AMOUNT, block.timestamp + DEADLINE, empty);

        uint256 escrowBalanceBefore = token.balanceOf(address(escrow));
        assertEq(escrowBalanceBefore, 200e18, "200 USDC locked in escrow (2 jobs)");

        // Buyer releases milestone 0 → seller gets 50
        vm.prank(buyer);
        escrow.releaseMilestone(job0);
        assertEq(token.balanceOf(seller), 50e18);

        // Seller submits work on job 0
        _submitWork(job0);

        // Auto-release fires: _release() sends job.amount (100) to seller
        // But only 50 remain for job0 — so it drains 50 from job1!
        vm.warp(block.timestamp + 48 hours + 1);

        uint256 sellerBefore = token.balanceOf(seller);
        escrow.autoRelease(job0); // should revert or only send remaining 50
        uint256 sellerAfter = token.balanceOf(seller);

        // Document what actually happens
        uint256 escrowAfter = token.balanceOf(address(escrow));
        emit log_named_uint("Seller received on autoRelease", sellerAfter - sellerBefore);
        emit log_named_uint("Escrow balance after (victim job funds)", escrowAfter);

        // FAIL CONDITION: seller received 100 (full amount) despite 50 already paid
        // and victim job funds are now stolen
        assertLe(
            sellerAfter - sellerBefore,
            50e18,
            "BUG: seller should only receive remaining 50, not full 100"
        );
        assertEq(
            escrowAfter,
            100e18,
            "BUG: victim job funds must remain intact"
        );
    }

    /// @notice SECURITY: Disputed funds are permanently locked — no resolver path.
    /// This is a design gap, not an exploit, but a critical UX/safety concern.
    function test_INFO_DisputedFundsLockedForever() public {
        uint256 jobId = _createJob();
        _submitWork(jobId);

        vm.prank(buyer); escrow.dispute(jobId);

        // After dispute: no release, no refund, no way to recover funds
        vm.prank(buyer);
        vm.expectRevert();
        escrow.release(jobId);

        vm.prank(buyer);
        vm.expectRevert();
        escrow.refund(jobId);

        // Funds stuck forever
        assertEq(token.balanceOf(address(escrow)), AMOUNT, "DESIGN GAP: funds locked with no resolver");
    }

    /// @notice SECURITY: Seller can be set to address(0) — funds burned on release.
    function test_SECURITY_SellerZeroAddress() public {
        uint256[] memory empty;
        vm.prank(buyer);
        // This should revert but currently doesn't
        uint256 jobId = escrow.createJob(address(0), address(token), AMOUNT, block.timestamp + DEADLINE, empty);

        // With seller = address(0), submitWork would fail because nobody can call it
        // but buyer can't get a refund until deadline passes either — funds locked
        AgentEscrowV2.Job memory j = escrow.getJob(jobId);
        assertEq(j.seller, address(0), "INFO: zero-address seller accepted without revert");
    }

    /// @notice SECURITY: Buyer can create job where buyer == seller (self-payment).
    /// Not a direct exploit but breaks trust model.
    function test_SECURITY_BuyerEqualsSeller() public {
        uint256[] memory empty;
        // buyer creates job where seller is also buyer
        vm.prank(buyer);
        uint256 jobId = escrow.createJob(buyer, address(token), AMOUNT, block.timestamp + DEADLINE, empty);

        AgentEscrowV2.Job memory j = escrow.getJob(jobId);
        assertEq(j.buyer, j.seller, "INFO: buyer==seller accepted");

        // Buyer is also seller, can submit work and immediately trigger autoRelease
        vm.prank(buyer); // also seller
        escrow.submitWork(jobId, keccak256("self"));

        vm.warp(block.timestamp + 48 hours + 1);
        escrow.autoRelease(jobId);
        // "seller" = buyer gets full amount back
        assertEq(token.balanceOf(buyer), 1000e18, "buyer==seller can extract funds freely");
    }

    /// @notice SECURITY: SubmitWork with empty hash (bytes32(0)) is rejected — verify guard works.
    function test_SECURITY_EmptyWorkHash_Rejected() public {
        uint256 jobId = _createJob();
        vm.prank(seller);
        vm.expectRevert("Empty hash");
        escrow.submitWork(jobId, bytes32(0));
    }

    /// @notice SECURITY: Double-release is not possible (status guard).
    function test_SECURITY_NoDoubleRelease() public {
        uint256 jobId = _createJob();
        _submitWork(jobId);

        vm.prank(buyer); escrow.release(jobId);

        vm.prank(buyer);
        vm.expectRevert("Work not submitted");
        escrow.release(jobId);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 6 — Edge cases & fuzzing
    // ═══════════════════════════════════════════════════════════════════════════

    function test_MultipleJobs_IsolatedFunds() public {
        uint256 job0 = _createJob();

        address buyer2 = address(0xD00D);
        token.mint(buyer2, AMOUNT);
        vm.prank(buyer2);
        token.approve(address(escrow), type(uint256).max);
        uint256[] memory empty;
        vm.prank(buyer2);
        uint256 job1 = escrow.createJob(seller, address(token), AMOUNT, block.timestamp + DEADLINE, empty);

        // Release job0 only
        _submitWork(job0);
        vm.prank(buyer); escrow.release(job0);

        assertEq(token.balanceOf(seller), AMOUNT,   "seller got job0 funds");
        assertEq(token.balanceOf(address(escrow)), AMOUNT, "job1 funds intact");
        assertEq(escrow.getJob(job1).amount, AMOUNT);
    }

    function testFuzz_CreateAndRelease(uint96 amount, uint32 delaySeconds) public {
        vm.assume(amount > 0);
        vm.assume(delaySeconds > 0 && delaySeconds < 365 days);

        token.mint(buyer, amount);
        uint256[] memory empty;
        vm.prank(buyer);
        uint256 jobId = escrow.createJob(seller, address(token), amount, block.timestamp + delaySeconds, empty);

        vm.prank(seller);
        escrow.submitWork(jobId, keccak256("fuzz work"));

        vm.prank(buyer);
        escrow.release(jobId);

        assertEq(token.balanceOf(seller), amount);
    }

    function testFuzz_AutoRelease(uint96 amount) public {
        vm.assume(amount > 0);
        token.mint(buyer, amount);
        uint256[] memory empty;
        vm.prank(buyer);
        uint256 jobId = escrow.createJob(seller, address(token), amount, block.timestamp + 1 days, empty);

        vm.prank(seller);
        escrow.submitWork(jobId, keccak256("auto fuzz"));

        vm.warp(block.timestamp + 48 hours + 1);
        escrow.autoRelease(jobId);

        assertEq(token.balanceOf(seller), amount);
    }
}
