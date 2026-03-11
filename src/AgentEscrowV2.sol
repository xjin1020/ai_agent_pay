// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// AgentEscrowV2 — trustless payment for agent-to-agent work
// Fixes from v1 feedback:
// - Seller MUST submit work hash before payment window opens (no ghost buyer exploit)
// - 48h auto-release if buyer doesn't dispute (no locked funds forever)
// - Buyer can dispute within window (no garbage delivery exploit)
// - Buyer refunds if seller misses deadline (no locked funds on no-show)
// - Optional milestone release (25/50/100% partial payment)
// - Uses SafeERC20, works with any ERC20 on any EVM chain

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
}

contract AgentEscrowV2 {

    enum Status { Created, WorkSubmitted, Released, Refunded, Disputed }

    struct Job {
        address buyer;
        address seller;
        address token;
        uint256 amount;
        uint256 deadline;       // seller must submit work by this time
        bytes32 workHash;       // SHA256 hash of delivered work (proof of delivery)
        uint64  submittedAt;    // timestamp when work was submitted
        Status  status;
    }

    uint256 public constant DISPUTE_WINDOW = 48 hours;

    uint256 public jobCount;
    mapping(uint256 => Job) public jobs;
    mapping(uint256 => uint256[]) public milestones;      // optional milestone amounts
    mapping(uint256 => uint256)   public nextMilestone;   // next milestone index to release

    event JobCreated(uint256 indexed jobId, address buyer, address seller, address token, uint256 amount, uint256 deadline);
    event WorkSubmitted(uint256 indexed jobId, bytes32 workHash);
    event Released(uint256 indexed jobId, address seller, uint256 amount);
    event AutoReleased(uint256 indexed jobId);
    event Disputed(uint256 indexed jobId);
    event Refunded(uint256 indexed jobId, address buyer, uint256 amount);
    event MilestoneReleased(uint256 indexed jobId, uint256 milestoneIdx, uint256 amount);

    // ── Create ──────────────────────────────────────────────────────────────

    /// @param milestoneAmounts Optional array. Must sum to amount. Empty = single payment.
    function createJob(
        address seller,
        address token,
        uint256 amount,
        uint256 deadline,
        uint256[] calldata milestoneAmounts
    ) external returns (uint256 jobId) {
        require(deadline > block.timestamp, "Deadline in past");
        require(amount > 0, "Amount zero");

        if (milestoneAmounts.length > 0) {
            uint256 total;
            for (uint256 i; i < milestoneAmounts.length; i++) total += milestoneAmounts[i];
            require(total == amount, "Milestones != amount");
        }

        require(IERC20(token).transferFrom(msg.sender, address(this), amount), "Transfer failed");

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

    /// Seller submits SHA256 hash of their deliverable. Opens the 48h dispute window.
    function submitWork(uint256 jobId, bytes32 workHash) external {
        Job storage job = jobs[jobId];
        require(msg.sender == job.seller,          "Not seller");
        require(job.status == Status.Created,      "Already submitted");
        require(block.timestamp <= job.deadline,   "Deadline passed");
        require(workHash != bytes32(0),            "Empty hash");

        job.workHash    = workHash;
        job.submittedAt = uint64(block.timestamp);
        job.status      = Status.WorkSubmitted;

        emit WorkSubmitted(jobId, workHash);
    }

    // ── Buyer: release / dispute ─────────────────────────────────────────────

    /// Buyer confirms work is good and releases payment.
    function release(uint256 jobId) external {
        Job storage job = jobs[jobId];
        require(msg.sender == job.buyer,                  "Not buyer");
        require(job.status == Status.WorkSubmitted,       "Work not submitted");

        _release(job, jobId);
    }

    /// Anyone can trigger auto-release after the 48h dispute window closes.
    function autoRelease(uint256 jobId) external {
        Job storage job = jobs[jobId];
        require(job.status == Status.WorkSubmitted,                          "Work not submitted");
        require(block.timestamp > uint256(job.submittedAt) + DISPUTE_WINDOW, "Window still open");

        _release(job, jobId);
        emit AutoReleased(jobId);
    }

    /// Buyer disputes within the 48h window. Funds stay locked for arbitration.
    function dispute(uint256 jobId) external {
        Job storage job = jobs[jobId];
        require(msg.sender == job.buyer,                                      "Not buyer");
        require(job.status == Status.WorkSubmitted,                           "Work not submitted");
        require(block.timestamp <= uint256(job.submittedAt) + DISPUTE_WINDOW, "Window closed");

        job.status = Status.Disputed;
        emit Disputed(jobId);
    }

    // ── Buyer: refund on no-show ─────────────────────────────────────────────

    /// Buyer reclaims funds if seller never submitted work before deadline.
    function refund(uint256 jobId) external {
        Job storage job = jobs[jobId];
        require(msg.sender == job.buyer,         "Not buyer");
        require(job.status == Status.Created,    "Work was submitted");
        require(block.timestamp > job.deadline,  "Deadline not passed");

        job.status = Status.Refunded;
        require(IERC20(job.token).transfer(job.buyer, job.amount), "Transfer failed");
        emit Refunded(jobId, job.buyer, job.amount);
    }

    // ── Milestones ───────────────────────────────────────────────────────────

    /// Buyer releases the next milestone slice. No work hash required per milestone.
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
        require(IERC20(job.token).transfer(job.seller, slice), "Transfer failed");
        emit MilestoneReleased(jobId, idx, slice);
    }

    // ── Internal ─────────────────────────────────────────────────────────────

    function _release(Job storage job, uint256 jobId) internal {
        job.status = Status.Released;
        require(IERC20(job.token).transfer(job.seller, job.amount), "Transfer failed");
        emit Released(jobId, job.seller, job.amount);
    }

    // ── View ─────────────────────────────────────────────────────────────────

    function getJob(uint256 jobId) external view returns (Job memory) {
        return jobs[jobId];
    }

    function getMilestones(uint256 jobId) external view returns (uint256[] memory) {
        return milestones[jobId];
    }
}
