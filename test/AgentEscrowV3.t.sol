// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/AgentEscrowV3.sol";

contract MockToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    function mint(address to, uint256 amt) external { balanceOf[to] += amt; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        require(balanceOf[f] >= a && allowance[f][msg.sender] >= a);
        balanceOf[f] -= a; allowance[f][msg.sender] -= a; balanceOf[t] += a; return true;
    }
    function transfer(address t, uint256 a) external returns (bool) {
        require(balanceOf[msg.sender] >= a);
        balanceOf[msg.sender] -= a; balanceOf[t] += a; return true;
    }
}

contract AgentEscrowV3Test is Test {
    AgentEscrowV3 escrow;
    MockToken     token;
    address arbiter = address(0xA7B1);
    address buyer   = address(0xBEEF);
    address seller  = address(0xCAFE);
    address alice   = address(0xABCD);
    uint256 constant AMOUNT   = 100e18;
    uint256 constant DEADLINE = 7 days;

    function setUp() public {
        escrow = new AgentEscrowV3(arbiter);
        token  = new MockToken();
        token.mint(buyer, 1000e18);
        vm.prank(buyer); token.approve(address(escrow), type(uint256).max);
    }

    function _createJob(uint256 window) internal returns (uint256 jobId) {
        uint256[] memory empty;
        vm.prank(buyer);
        jobId = escrow.createJob(seller, address(token), AMOUNT, block.timestamp + DEADLINE, empty, window);
    }

    function _submitWork(uint256 jobId) internal {
        vm.prank(seller);
        escrow.submitWork(jobId, keccak256("work"));
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Happy path
    // ═══════════════════════════════════════════════════════════════════════

    function test_CreateJob_DefaultWindow() public {
        uint256 jobId = _createJob(0);
        AgentEscrowV3.Job memory j = escrow.getJob(jobId);
        assertEq(j.disputeWindow, 48 hours);
    }

    function test_CreateJob_CustomWindow_6h() public {
        uint256 jobId = _createJob(6 hours);
        assertEq(escrow.getJob(jobId).disputeWindow, 6 hours);
    }

    function test_CreateJob_CustomWindow_7d() public {
        uint256 jobId = _createJob(7 days);
        assertEq(escrow.getJob(jobId).disputeWindow, 7 days);
    }

    function test_AutoRelease_UsesJobWindow() public {
        uint256 jobId = _createJob(6 hours);
        _submitWork(jobId);

        // 6h + 1s should trigger auto-release (not 48h)
        vm.warp(block.timestamp + 6 hours + 1);
        escrow.autoRelease(jobId);
        assertEq(token.balanceOf(seller), AMOUNT);
    }

    function test_AutoRelease_NotBeforeWindow() public {
        uint256 jobId = _createJob(6 hours);
        _submitWork(jobId);
        vm.warp(block.timestamp + 3 hours);
        vm.expectRevert("Window still open");
        escrow.autoRelease(jobId);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Partial arbitration
    // ═══════════════════════════════════════════════════════════════════════

    function test_ResolveDispute_FullSeller() public {
        uint256 jobId = _createJob(0);
        _submitWork(jobId);
        vm.prank(buyer); escrow.dispute(jobId);

        vm.prank(arbiter); escrow.resolveDispute(jobId, 10_000);
        assertEq(token.balanceOf(seller), AMOUNT, "seller gets 100%");
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    function test_ResolveDispute_FullBuyer() public {
        uint256 jobId = _createJob(0);
        _submitWork(jobId);
        vm.prank(buyer); escrow.dispute(jobId);

        vm.prank(arbiter); escrow.resolveDispute(jobId, 0);
        assertEq(token.balanceOf(buyer), 1000e18, "buyer refunded 100%");
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    function test_ResolveDispute_70_30_Split() public {
        uint256 jobId = _createJob(0);
        _submitWork(jobId);
        vm.prank(buyer); escrow.dispute(jobId);

        vm.prank(arbiter); escrow.resolveDispute(jobId, 7_000); // 70% to seller
        assertEq(token.balanceOf(seller), 70e18,   "seller gets 70");
        assertEq(token.balanceOf(buyer),  930e18,  "buyer gets 30 back");
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    function test_ResolveDispute_50_50_Split() public {
        uint256 jobId = _createJob(0);
        _submitWork(jobId);
        vm.prank(buyer); escrow.dispute(jobId);

        vm.prank(arbiter); escrow.resolveDispute(jobId, 5_000);
        assertEq(token.balanceOf(seller), 50e18);
        assertEq(token.balanceOf(buyer),  950e18);
    }

    function test_ResolveDispute_AfterMilestones() public {
        uint256[] memory ms = new uint256[](2);
        ms[0] = 50e18; ms[1] = 50e18;
        vm.prank(buyer);
        uint256 jobId = escrow.createJob(seller, address(token), AMOUNT, block.timestamp + DEADLINE, ms, 0);

        vm.prank(buyer); escrow.releaseMilestone(jobId); // 50 already paid
        _submitWork(jobId);
        vm.prank(buyer); escrow.dispute(jobId);

        // Only 50 remaining — arbiter splits 60/40
        vm.prank(arbiter); escrow.resolveDispute(jobId, 6_000);
        // buyer spent 100 on job, got 20 back from dispute → 900 + 20 = 920
        assertEq(token.balanceOf(seller), 80e18,  "50 milestone + 30 from dispute = 80");
        assertEq(token.balanceOf(buyer),  920e18, "900 after job creation + 20 from dispute");
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    function test_Revert_ResolveDispute_InvalidBps() public {
        uint256 jobId = _createJob(0);
        _submitWork(jobId);
        vm.prank(buyer); escrow.dispute(jobId);
        vm.prank(arbiter);
        vm.expectRevert("bps > 10000");
        escrow.resolveDispute(jobId, 10_001);
    }

    function test_Revert_ResolveDispute_NotArbiter() public {
        uint256 jobId = _createJob(0);
        _submitWork(jobId);
        vm.prank(buyer); escrow.dispute(jobId);
        vm.prank(alice);
        vm.expectRevert("Not arbiter");
        escrow.resolveDispute(jobId, 5_000);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Window validation
    // ═══════════════════════════════════════════════════════════════════════

    function test_Revert_Window_TooShort() public {
        uint256[] memory empty;
        vm.prank(buyer);
        vm.expectRevert("Window too short (min 6h)");
        escrow.createJob(seller, address(token), AMOUNT, block.timestamp + DEADLINE, empty, 1 hours);
    }

    function test_Revert_Window_TooLong() public {
        uint256[] memory empty;
        vm.prank(buyer);
        vm.expectRevert("Window too long (max 7d)");
        escrow.createJob(seller, address(token), AMOUNT, block.timestamp + DEADLINE, empty, 8 days);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // remainingAmount view
    // ═══════════════════════════════════════════════════════════════════════

    function test_RemainingAmount_AfterMilestone() public {
        uint256[] memory ms = new uint256[](2);
        ms[0] = 40e18; ms[1] = 60e18;
        vm.prank(buyer);
        uint256 jobId = escrow.createJob(seller, address(token), AMOUNT, block.timestamp + DEADLINE, ms, 0);
        assertEq(escrow.remainingAmount(jobId), 100e18);

        vm.prank(buyer); escrow.releaseMilestone(jobId);
        assertEq(escrow.remainingAmount(jobId), 60e18);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Fuzz
    // ═══════════════════════════════════════════════════════════════════════

    function testFuzz_PartialResolution(uint96 sellerBps) public {
        sellerBps = uint96(bound(sellerBps, 0, 10_000));
        uint256 jobId = _createJob(0);
        _submitWork(jobId);
        vm.prank(buyer); escrow.dispute(jobId);

        vm.prank(arbiter); escrow.resolveDispute(jobId, sellerBps);

        uint256 toSeller = AMOUNT * sellerBps / 10_000;
        uint256 toBuyer  = AMOUNT - toSeller;
        assertEq(token.balanceOf(seller), toSeller);
        assertEq(token.balanceOf(buyer),  1000e18 - AMOUNT + toBuyer);
        assertEq(token.balanceOf(address(escrow)), 0, "no funds left in contract");
    }

    function testFuzz_DynamicWindow(uint32 windowSeconds) public {
        uint256 w = bound(windowSeconds, 6 hours, 7 days);
        uint256 jobId = _createJob(w);
        assertEq(escrow.getJob(jobId).disputeWindow, w);
    }
}
