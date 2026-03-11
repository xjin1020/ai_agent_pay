// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// AgentEscrowV2Fixed — trustless payment for agent-to-agent work
// Security fixes applied (see SECURITY_AUDIT.md):
//   [CRITICAL] Milestone double-payment: track releasedAmount, send only remainder
//   [MEDIUM]   Dispute resolution: arbiter can resolve locked disputes
//   [MEDIUM]   buyer == seller / zero-address seller now rejected
//   [INFO]     SafeERC20 pattern via try-decode (works with USDT-style void returns)

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @dev Minimal SafeERC20-style wrapper that handles non-standard tokens
library SafeTransfer {
    function safeTransfer(address token, address to, uint256 amount) internal {
        (bool ok, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20.transfer.selector, to, amount)
        );
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "Transfer failed");
    }

    function safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        (bool ok, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, amount)
        );
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "TransferFrom failed");
    }
}

contract AgentEscrowV2Fixed {
    using SafeTransfer for address;

    enum Status { Created, WorkSubmitted, Released, Refunded, Disputed }

    struct Job {
        address buyer;
        address seller;
        address token;
        uint256 amount;
        uint256 deadline;
        bytes32 workHash;
        uint64  submittedAt;
        Status  status;
    }

    uint256 public constant DISPUTE_WINDOW = 48 hours;

    address public immutable arbiter; // dispute resolver

    uint256 public jobCount;
    mapping(uint256 => Job)      public jobs;
    mapping(uint256 => uint256[]) public milestones;
    mapping(uint256 => uint256)   public nextMilestone;
    mapping(uint256 => uint256)   public releasedAmount; // FIX: track milestone payouts

    event JobCreated(uint256 indexed jobId, address buyer, address seller, address token, uint256 amount, uint256 deadline);
    event WorkSubmitted(uint256 indexed jobId, bytes32 workHash);
    event Released(uint256 indexed jobId, address seller, uint256 amount);
    event AutoReleased(uint256 indexed jobId);
    event Disputed(uint256 indexed jobId);
    event DisputeResolved(uint256 indexed jobId, address winner);
    event Refunded(uint256 indexed jobId, address buyer, uint256 amount);
    event MilestoneReleased(uint256 indexed jobId, uint256 milestoneIdx, uint256 amount);

    constructor(address _arbiter) {
        require(_arbiter != address(0), "Invalid arbiter");
        arbiter = _arbiter;
    }

    // ── Create ──────────────────────────────────────────────────────────────

    function createJob(
        address seller,
        address token,
        uint256 amount,
        uint256 deadline,
        uint256[] calldata milestoneAmounts
    ) external returns (uint256 jobId) {
        require(deadline > block.timestamp,  "Deadline in past");
        require(amount > 0,                  "Amount zero");
        require(seller != address(0),        "Invalid seller");       // FIX
        require(seller != msg.sender,        "Buyer cannot be seller"); // FIX

        if (milestoneAmounts.length > 0) {
            uint256 total;
            for (uint256 i; i < milestoneAmounts.length; i++) total += milestoneAmounts[i];
            require(total == amount, "Milestones != amount");
        }

        token.safeTransferFrom(msg.sender, address(this), amount); // FIX: SafeTransfer

        jobId = jobCount++;
        jobs[jobId] = Job({
            buyer:       msg.sender,
            seller:      seller,
            token:       token,
            amount:      amount,
            deadline:    deadline,
            workHash:    bytes32(0),
            submittedAt: 0,
            status:      Status.Created
        });

        if (milestoneAmounts.length > 0) {
            milestones[jobId] = milestoneAmounts;
        }

        emit JobCreated(jobId, msg.sender, seller, token, amount, deadline);
    }

    // ── Seller: submit work ──────────────────────────────────────────────────

    function submitWork(uint256 jobId, bytes32 workHash) external {
        Job storage job = jobs[jobId];
        require(msg.sender == job.seller,        "Not seller");
        require(job.status == Status.Created,    "Already submitted");
        require(block.timestamp <= job.deadline, "Deadline passed");
        require(workHash != bytes32(0),          "Empty hash");

        job.workHash    = workHash;
        job.submittedAt = uint64(block.timestamp);
        job.status      = Status.WorkSubmitted;

        emit WorkSubmitted(jobId, workHash);
    }

    // ── Buyer: release / dispute ─────────────────────────────────────────────

    function release(uint256 jobId) external {
        Job storage job = jobs[jobId];
        require(msg.sender == job.buyer,            "Not buyer");
        require(job.status == Status.WorkSubmitted, "Work not submitted");

        _release(job, jobId);
    }

    function autoRelease(uint256 jobId) external {
        Job storage job = jobs[jobId];
        require(job.status == Status.WorkSubmitted,                           "Work not submitted");
        require(block.timestamp > uint256(job.submittedAt) + DISPUTE_WINDOW,  "Window still open");

        _release(job, jobId);
        emit AutoReleased(jobId);
    }

    function dispute(uint256 jobId) external {
        Job storage job = jobs[jobId];
        require(msg.sender == job.buyer,                                       "Not buyer");
        require(job.status == Status.WorkSubmitted,                            "Work not submitted");
        require(block.timestamp <= uint256(job.submittedAt) + DISPUTE_WINDOW,  "Window closed");

        job.status = Status.Disputed;
        emit Disputed(jobId);
    }

    // ── Arbiter: resolve dispute ─────────────────────────────────────────────

    /// @notice FIX: Arbiter resolves a disputed job.
    /// @param payoutSeller true → pay seller, false → refund buyer
    function resolveDispute(uint256 jobId, bool payoutSeller) external {
        require(msg.sender == arbiter,           "Not arbiter");
        Job storage job = jobs[jobId];
        require(job.status == Status.Disputed,   "Not disputed");

        uint256 remaining = job.amount - releasedAmount[jobId];
        if (payoutSeller) {
            job.status = Status.Released;
            if (remaining > 0) job.token.safeTransfer(job.seller, remaining);
            emit DisputeResolved(jobId, job.seller);
        } else {
            job.status = Status.Refunded;
            if (remaining > 0) job.token.safeTransfer(job.buyer, remaining);
            emit DisputeResolved(jobId, job.buyer);
        }
    }

    // ── Buyer: refund on no-show ─────────────────────────────────────────────

    function refund(uint256 jobId) external {
        Job storage job = jobs[jobId];
        require(msg.sender == job.buyer,        "Not buyer");
        require(job.status == Status.Created,   "Work was submitted");
        require(block.timestamp > job.deadline, "Deadline not passed");

        job.status = Status.Refunded;
        job.token.safeTransfer(job.buyer, job.amount); // FIX: SafeTransfer
        emit Refunded(jobId, job.buyer, job.amount);
    }

    // ── Milestones ───────────────────────────────────────────────────────────

    function releaseMilestone(uint256 jobId) external {
        Job storage job = jobs[jobId];
        require(msg.sender == job.buyer, "Not buyer");
        require(
            job.status == Status.Created || job.status == Status.WorkSubmitted,
            "Job closed"
        );

        uint256[] storage ms = milestones[jobId];
        require(ms.length > 0, "No milestones");

        uint256 idx = nextMilestone[jobId];
        require(idx < ms.length, "All milestones released");

        nextMilestone[jobId]++;
        uint256 slice = ms[idx];
        releasedAmount[jobId] += slice; // FIX: track payout
        job.token.safeTransfer(job.seller, slice); // FIX: SafeTransfer
        emit MilestoneReleased(jobId, idx, slice);
    }

    // ── Internal ─────────────────────────────────────────────────────────────

    function _release(Job storage job, uint256 jobId) internal {
        job.status = Status.Released;
        uint256 remaining = job.amount - releasedAmount[jobId]; // FIX: only send remainder
        if (remaining > 0) {
            job.token.safeTransfer(job.seller, remaining);
        }
        emit Released(jobId, job.seller, remaining);
    }

    // ── View ─────────────────────────────────────────────────────────────────

    function getJob(uint256 jobId) external view returns (Job memory) {
        return jobs[jobId];
    }

    function getMilestones(uint256 jobId) external view returns (uint256[] memory) {
        return milestones[jobId];
    }
}
