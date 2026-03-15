// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ReputationArbiter — Alkahest-compatible arbiter that validates escrow release
// based on on-chain seller reputation from AgentEscrowV4.
//
// This arbiter implements IArbiter from the Alkahest protocol and can be composed
// with other arbiters via AllArbiter/AnyArbiter.
//
// Use cases:
//   - Require minimum seller rating before releasing escrow funds
//   - Require minimum completed jobs (track record)
//   - Require maximum dispute ratio
//   - Gate high-value escrows behind reputation thresholds

import {Attestation} from "./IAlkahest.sol";

/// @notice Minimal Alkahest IArbiter interface
interface IArbiter {
    function checkObligation(
        Attestation memory obligation,
        bytes memory demand,
        bytes32 fulfilling
    ) external view returns (bool);
}

/// @notice Interface to read reputation from AgentEscrowV4
interface IAgentEscrowReputation {
    function sellerStats(address seller) external view returns (
        uint256 completedJobs,
        uint256 disputedJobs,
        uint256 avgRatingX100,
        uint256 ratingCount
    );
}

/// @title ReputationArbiter
/// @notice Alkahest arbiter that gates escrow release on seller reputation thresholds.
///         Buyers encode their minimum requirements in the demand; the arbiter checks
///         the seller's on-chain reputation from AgentEscrowV4.
contract ReputationArbiter is IArbiter {

    // ── Storage ────────────────────────────────────────────────────────────

    IAgentEscrowReputation public immutable reputationSource;

    // ── Demand Struct ──────────────────────────────────────────────────────

    /// @notice Encoded as `demand` bytes in Alkahest escrow creation.
    /// @param seller           Address of the seller to check reputation for
    /// @param minRatingX100    Minimum average rating (e.g., 400 = 4.00 stars). 0 = no minimum.
    /// @param minCompletedJobs Minimum completed jobs. 0 = no minimum.
    /// @param maxDisputeRatioBps Maximum dispute ratio in basis points (e.g., 2000 = 20%). 10000 = no limit.
    /// @param minRatingCount   Minimum number of ratings received. 0 = no minimum (allows unrated sellers).
    struct ReputationDemand {
        address seller;
        uint256 minRatingX100;
        uint256 minCompletedJobs;
        uint256 maxDisputeRatioBps;
        uint256 minRatingCount;
    }

    // ── Events ─────────────────────────────────────────────────────────────

    event ReputationChecked(
        address indexed seller,
        bool passed,
        uint256 avgRatingX100,
        uint256 completedJobs,
        uint256 disputeRatioBps
    );

    // ── Constructor ────────────────────────────────────────────────────────

    /// @param _reputationSource Address of deployed AgentEscrowV4 contract
    constructor(address _reputationSource) {
        reputationSource = IAgentEscrowReputation(_reputationSource);
    }

    // ── IArbiter Implementation ────────────────────────────────────────────

    /// @notice Check if the seller meets the reputation requirements encoded in demand.
    /// @param obligation The EAS attestation (unused in this arbiter, but required by interface)
    /// @param demand     ABI-encoded ReputationDemand struct
    /// @param fulfilling Counter-offer reference (unused)
    /// @return True if seller meets all reputation thresholds
    function checkObligation(
        Attestation memory obligation,
        bytes memory demand,
        bytes32 fulfilling
    ) external view override returns (bool) {
        // Suppress unused variable warnings
        obligation;
        fulfilling;

        ReputationDemand memory req = abi.decode(demand, (ReputationDemand));

        (
            uint256 completedJobs,
            uint256 disputedJobs,
            uint256 avgRatingX100,
            uint256 ratingCount
        ) = reputationSource.sellerStats(req.seller);

        // Check minimum completed jobs
        if (req.minCompletedJobs > 0 && completedJobs < req.minCompletedJobs) {
            return false;
        }

        // Check minimum rating count (must have enough ratings to be meaningful)
        if (req.minRatingCount > 0 && ratingCount < req.minRatingCount) {
            return false;
        }

        // Check minimum average rating
        if (req.minRatingX100 > 0 && ratingCount > 0 && avgRatingX100 < req.minRatingX100) {
            return false;
        }

        // Check maximum dispute ratio
        if (req.maxDisputeRatioBps < 10000 && completedJobs > 0) {
            uint256 totalJobs = completedJobs + disputedJobs;
            uint256 disputeRatio = (disputedJobs * 10000) / totalJobs;
            if (disputeRatio > req.maxDisputeRatioBps) {
                return false;
            }
        }

        return true;
    }

    // ── View Helpers ───────────────────────────────────────────────────────

    /// @notice Check if a seller would pass a given reputation demand (off-chain preview)
    function wouldPass(ReputationDemand memory req) external view returns (bool) {
        (
            uint256 completedJobs,
            uint256 disputedJobs,
            uint256 avgRatingX100,
            uint256 ratingCount
        ) = reputationSource.sellerStats(req.seller);

        if (req.minCompletedJobs > 0 && completedJobs < req.minCompletedJobs) return false;
        if (req.minRatingCount > 0 && ratingCount < req.minRatingCount) return false;
        if (req.minRatingX100 > 0 && ratingCount > 0 && avgRatingX100 < req.minRatingX100) return false;
        if (req.maxDisputeRatioBps < 10000 && completedJobs > 0) {
            uint256 totalJobs = completedJobs + disputedJobs;
            if ((disputedJobs * 10000) / totalJobs > req.maxDisputeRatioBps) return false;
        }
        return true;
    }

    /// @notice Encode a ReputationDemand for use in Alkahest escrow creation
    function encodeDemand(ReputationDemand memory req) external pure returns (bytes memory) {
        return abi.encode(req);
    }
}
