// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/ReputationArbiter.sol";
import "../src/AgentEscrowV4.sol";
import "../src/IAlkahest.sol";

contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract ReputationArbiterTest is Test {
    AgentEscrowV4 escrow;
    ReputationArbiter arbiter;
    MockERC20 token;

    address buyer = address(0xBEEF);
    address seller = address(0xCAFE);
    address arbiterAddr = address(0xA1B1);

    function setUp() public {
        escrow = new AgentEscrowV4(arbiterAddr, address(this));
        arbiter = new ReputationArbiter(address(escrow));
        token = new MockERC20();
    }

    function _buildDemand(
        address _seller,
        uint256 minRating,
        uint256 minJobs,
        uint256 maxDispute,
        uint256 minRatings
    ) internal pure returns (bytes memory) {
        return abi.encode(ReputationArbiter.ReputationDemand({
            seller: _seller,
            minRatingX100: minRating,
            minCompletedJobs: minJobs,
            maxDisputeRatioBps: maxDispute,
            minRatingCount: minRatings
        }));
    }

    function _emptyAttestation() internal pure returns (Attestation memory) {
        return Attestation({
            uid: bytes32(0),
            schema: bytes32(0),
            time: 0,
            expirationTime: 0,
            revocationTime: 0,
            refUID: bytes32(0),
            attester: address(0),
            recipient: address(0),
            revocable: false,
            data: ""
        });
    }

    function _createAndCompleteJob(uint8 rating) internal {
        token.mint(buyer, 1e18);
        vm.startPrank(buyer);
        token.approve(address(escrow), 1e18);
        uint256[] memory milestones = new uint256[](0);
        uint256 jobId = escrow.createJob(
            seller,
            address(token),
            1e18,
            block.timestamp + 1 days,
            milestones,
            48 hours
        );
        vm.stopPrank();

        vm.prank(seller);
        escrow.submitWork(jobId, keccak256("work"));

        vm.startPrank(buyer);
        escrow.release(jobId);
        escrow.rateJob(jobId, rating);
        vm.stopPrank();
    }

    // ── Tests ──────────────────────────────────────────────────────────────

    function testPassesWithNoRequirements() public view {
        bytes memory demand = _buildDemand(seller, 0, 0, 10000, 0);
        bool result = arbiter.checkObligation(_emptyAttestation(), demand, bytes32(0));
        assertTrue(result);
    }

    function testCheckMinCompletedJobsFails() public view {
        bytes memory demand = _buildDemand(seller, 0, 5, 10000, 0);
        bool result = arbiter.checkObligation(_emptyAttestation(), demand, bytes32(0));
        assertFalse(result);
    }

    function testPassesMinCompletedJobs() public {
        for (uint8 i = 0; i < 5; i++) {
            _createAndCompleteJob(5);
        }
        bytes memory demand = _buildDemand(seller, 0, 5, 10000, 0);
        bool result = arbiter.checkObligation(_emptyAttestation(), demand, bytes32(0));
        assertTrue(result);
    }

    function testCheckMinRatingFails() public {
        _createAndCompleteJob(2); // 2 stars = 200
        bytes memory demand = _buildDemand(seller, 400, 0, 10000, 0); // require 4.00+
        bool result = arbiter.checkObligation(_emptyAttestation(), demand, bytes32(0));
        assertFalse(result);
    }

    function testPassesMinRating() public {
        _createAndCompleteJob(5); // 5 stars = 500
        bytes memory demand = _buildDemand(seller, 400, 0, 10000, 0); // require 4.00+
        bool result = arbiter.checkObligation(_emptyAttestation(), demand, bytes32(0));
        assertTrue(result);
    }

    function testCheckMinRatingCountFails() public {
        _createAndCompleteJob(5); // only 1 rating
        bytes memory demand = _buildDemand(seller, 0, 0, 10000, 3); // require 3+ ratings
        bool result = arbiter.checkObligation(_emptyAttestation(), demand, bytes32(0));
        assertFalse(result);
    }

    function testWouldPassHelper() public {
        _createAndCompleteJob(4);
        _createAndCompleteJob(5);

        ReputationArbiter.ReputationDemand memory req = ReputationArbiter.ReputationDemand({
            seller: seller,
            minRatingX100: 400,
            minCompletedJobs: 2,
            maxDisputeRatioBps: 10000,
            minRatingCount: 0
        });
        assertTrue(arbiter.wouldPass(req));
    }

    function testEncodeDemandRoundtrip() public view {
        ReputationArbiter.ReputationDemand memory req = ReputationArbiter.ReputationDemand({
            seller: seller,
            minRatingX100: 350,
            minCompletedJobs: 10,
            maxDisputeRatioBps: 1500,
            minRatingCount: 5
        });
        bytes memory encoded = arbiter.encodeDemand(req);
        ReputationArbiter.ReputationDemand memory decoded = abi.decode(
            encoded,
            (ReputationArbiter.ReputationDemand)
        );
        assertEq(decoded.seller, req.seller);
        assertEq(decoded.minRatingX100, req.minRatingX100);
        assertEq(decoded.minCompletedJobs, req.minCompletedJobs);
        assertEq(decoded.maxDisputeRatioBps, req.maxDisputeRatioBps);
        assertEq(decoded.minRatingCount, req.minRatingCount);
    }
}
