// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/AgentEscrowV4.sol";

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

contract AgentEscrowV4Test is Test {
    AgentEscrowV4 escrow;
    MockToken     token;

    address arbiter      = address(0xA7B1);
    address feeCollector = address(0xFEE5);
    address buyer        = address(0xBEEF);
    address seller       = address(0xCAFE);
    address alice        = address(0xABCD);

    uint256 constant AMOUNT   = 100e18;
    uint256 constant DEADLINE = 7 days;

    function setUp() public {
        escrow = new AgentEscrowV4(arbiter, feeCollector);
        token  = new MockToken();
        token.mint(buyer, 1000e18);
        vm.prank(buyer); token.approve(address(escrow), type(uint256).max);
    }

    function _create(uint256 window) internal returns (uint256 jobId) {
        uint256[] memory empty;
        vm.prank(buyer);
        jobId = escrow.createJob(seller, address(token), AMOUNT, block.timestamp + DEADLINE, empty, window);
    }

    function _submit(uint256 jobId) internal {
        vm.prank(seller); escrow.submitWork(jobId, keccak256("work"));
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Protocol fee
    // ═══════════════════════════════════════════════════════════════════════

    function test_Fee_DefaultHalfPercent() public {
        uint256 jobId = _create(0);
        _submit(jobId);
        vm.prank(buyer); escrow.release(jobId);

        uint256 expectedFee    = AMOUNT * 50 / 10_000; // 0.5%
        uint256 expectedSeller = AMOUNT - expectedFee;

        assertEq(token.balanceOf(feeCollector), expectedFee,    "fee correct");
        assertEq(token.balanceOf(seller),       expectedSeller, "seller correct");
    }

    function test_Fee_Configurable() public {
        vm.prank(arbiter); escrow.setProtocolFee(100); // 1%
        uint256 jobId = _create(0);
        _submit(jobId);
        vm.prank(buyer); escrow.release(jobId);

        uint256 expectedFee = AMOUNT * 100 / 10_000; // 1%
        assertEq(token.balanceOf(feeCollector), expectedFee);
    }

    function test_Fee_Zero() public {
        vm.prank(arbiter); escrow.setProtocolFee(0);
        uint256 jobId = _create(0);
        _submit(jobId);
        vm.prank(buyer); escrow.release(jobId);

        assertEq(token.balanceOf(feeCollector), 0);
        assertEq(token.balanceOf(seller), AMOUNT);
    }

    function test_Revert_Fee_TooHigh() public {
        vm.prank(arbiter);
        vm.expectRevert("Fee too high");
        escrow.setProtocolFee(501); // > 5%
    }

    function test_Fee_InDisputeResolution() public {
        uint256 jobId = _create(0);
        _submit(jobId);
        vm.prank(buyer); escrow.dispute(jobId);

        vm.prank(arbiter); escrow.resolveDispute(jobId, 7_000);

        uint256 fee    = AMOUNT * 50 / 10_000; // 0.5%
        uint256 net    = AMOUNT - fee;
        uint256 toSeller = net * 7_000 / 10_000;
        uint256 toBuyer  = net - toSeller;

        assertEq(token.balanceOf(feeCollector), fee,      "fee");
        assertEq(token.balanceOf(seller),       toSeller, "seller");
        assertEq(token.balanceOf(buyer),        1000e18 - AMOUNT + toBuyer, "buyer");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Reputation
    // ═══════════════════════════════════════════════════════════════════════

    function test_Rating_AfterRelease() public {
        uint256 jobId = _create(0);
        _submit(jobId);
        vm.prank(buyer); escrow.release(jobId);

        vm.prank(buyer); escrow.rateJob(jobId, 5);

        (uint256 avgX100, uint256 count) = escrow.sellerRating(seller);
        assertEq(count,    1);
        assertEq(avgX100,  500); // 5.00 stars
    }

    function test_Rating_Average() public {
        // Job 1: 5 stars
        uint256 job0 = _create(0);
        _submit(job0);
        vm.prank(buyer); escrow.release(job0);
        vm.prank(buyer); escrow.rateJob(job0, 5);

        // Job 2: 3 stars (new buyer)
        address buyer2 = address(0xD00D);
        token.mint(buyer2, AMOUNT);
        vm.prank(buyer2); token.approve(address(escrow), type(uint256).max);
        uint256[] memory empty;
        vm.prank(buyer2);
        uint256 job1 = escrow.createJob(seller, address(token), AMOUNT, block.timestamp + DEADLINE, empty, 0);
        vm.prank(seller); escrow.submitWork(job1, keccak256("work2"));
        vm.prank(buyer2); escrow.release(job1);
        vm.prank(buyer2); escrow.rateJob(job1, 3);

        (uint256 avgX100, uint256 count) = escrow.sellerRating(seller);
        assertEq(count, 2);
        assertEq(avgX100, 400); // (5+3)/2 = 4.00
    }

    function test_Revert_Rating_DoubleRate() public {
        uint256 jobId = _create(0);
        _submit(jobId);
        vm.prank(buyer); escrow.release(jobId);
        vm.prank(buyer); escrow.rateJob(jobId, 4);

        vm.prank(buyer);
        vm.expectRevert("Already rated");
        escrow.rateJob(jobId, 5);
    }

    function test_Revert_Rating_InvalidScore() public {
        uint256 jobId = _create(0);
        _submit(jobId);
        vm.prank(buyer); escrow.release(jobId);

        vm.prank(buyer);
        vm.expectRevert("Rating must be 1-5");
        escrow.rateJob(jobId, 0);

        vm.prank(buyer);
        vm.expectRevert("Rating must be 1-5");
        escrow.rateJob(jobId, 6);
    }

    function test_Revert_Rating_BeforeComplete() public {
        uint256 jobId = _create(0);
        _submit(jobId);
        vm.prank(buyer);
        vm.expectRevert("Job not complete");
        escrow.rateJob(jobId, 5);
    }

    function test_SellerStats_TrackCompleted() public {
        uint256 jobId = _create(0);
        _submit(jobId);
        vm.prank(buyer); escrow.release(jobId);

        (uint256 completed, uint256 disputed,,) = escrow.sellerStats(seller);
        assertEq(completed, 1);
        assertEq(disputed,  0);
    }

    function test_SellerStats_TrackDisputed() public {
        uint256 jobId = _create(0);
        _submit(jobId);
        vm.prank(buyer); escrow.dispute(jobId);
        vm.prank(arbiter); escrow.resolveDispute(jobId, 7_000); // seller wins

        (uint256 completed, uint256 disputed,,) = escrow.sellerStats(seller);
        assertEq(completed, 1); // seller won, counts as completed
        assertEq(disputed,  1);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Arbiter timeout
    // ═══════════════════════════════════════════════════════════════════════

    function test_ArbiterTimeout_ReleasesToSeller() public {
        uint256 jobId = _create(0);
        _submit(jobId);
        vm.prank(buyer); escrow.dispute(jobId);

        // Fast forward past arbiter timeout (7 days default)
        vm.warp(block.timestamp + 7 days + 1);
        alice; // anyone can call
        vm.prank(alice); escrow.arbiterTimeoutRelease(jobId);

        uint256 fee    = AMOUNT * 50 / 10_000;
        uint256 net    = AMOUNT - fee;
        assertEq(token.balanceOf(seller), net, "seller gets funds after timeout");
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    function test_Revert_ArbiterTimeout_TooEarly() public {
        uint256 jobId = _create(0);
        _submit(jobId);
        vm.prank(buyer); escrow.dispute(jobId);

        vm.warp(block.timestamp + 3 days);
        vm.expectRevert("Arbiter timeout not reached");
        escrow.arbiterTimeoutRelease(jobId);
    }

    function test_Revert_ArbiterTimeout_NotDisputed() public {
        uint256 jobId = _create(0);
        vm.expectRevert("Not disputed");
        escrow.arbiterTimeoutRelease(jobId);
    }

    function test_ArbiterTimeout_Configurable() public {
        vm.prank(arbiter); escrow.setArbiterTimeout(2 days);
        uint256 jobId = _create(0);
        _submit(jobId);
        vm.prank(buyer); escrow.dispute(jobId);

        vm.warp(block.timestamp + 2 days + 1);
        escrow.arbiterTimeoutRelease(jobId); // should succeed
        assertGt(token.balanceOf(seller), 0);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Fuzz
    // ═══════════════════════════════════════════════════════════════════════

    function testFuzz_FeeAlwaysDrains(uint96 amount, uint16 feeBps) public {
        feeBps = uint16(bound(feeBps, 0, 500));
        amount = uint96(bound(amount, 1e6, 1e24));

        vm.prank(arbiter); escrow.setProtocolFee(feeBps);
        token.mint(buyer, amount);
        uint256[] memory empty;
        vm.prank(buyer); token.approve(address(escrow), type(uint256).max);
        vm.prank(buyer);
        uint256 jobId = escrow.createJob(seller, address(token), amount, block.timestamp + DEADLINE, empty, 0);
        vm.prank(seller); escrow.submitWork(jobId, keccak256("fuzz"));
        vm.prank(buyer); escrow.release(jobId);

        assertEq(token.balanceOf(address(escrow)), 0, "no funds left in escrow");
        assertEq(
            token.balanceOf(seller) + token.balanceOf(feeCollector),
            amount,
            "seller + fee = amount"
        );
    }
}
