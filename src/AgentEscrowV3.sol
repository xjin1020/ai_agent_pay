// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// AgentEscrowV3 — trustless payment for agent-to-agent work
// Changes from V2Fixed:
// - Partial arbitration: arbiter splits funds by % (basis points), not binary winner-takes-all
// - Dynamic dispute window: configurable per job (6h–7d), not fixed 48h
// - releasedAmount accounting carried forward from V2Fixed (no double-pay bug)
// - SafeTransfer library for USDT-compatible tokens
// - buyer==seller and zero-address seller rejected

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
}

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

contract AgentEscrowV3 {
    using SafeTransfer for address;

    enum Status { Created, WorkSubmitted, Released, Refunded, Disputed, PartiallyResolved }

    struct Job {
        address buyer;
        address seller;
        address token;
        uint256 amount;
        uint256 deadline;
        uint256 disputeWindow;  // seconds — dynamic per job
        bytes32 workHash;
        uint64  submittedAt;
        Status  status;
    }

    // Dispute window bounds
    uint256 public constant MIN_DISPUTE_WINDOW = 6 hours;
    uint256 public constant MAX_DISPUTE_WINDOW = 7 days;
    uint256 public constant DEFAULT_DISPUTE_WINDOW = 48 hours;

    address public immutable arbiter;

    uint256 public jobCount;
    mapping(uint256 => Job)       public jobs;
    mapping(uint256 => uint256[]) public milestones;
    mapping(uint256 => uint256)   public nextMilestone;
    mapping(uint256 => uint256)   public releasedAmount;

    event JobCreated(uint256 indexed jobId, address buyer, address seller, address token, uint256 amount, uint256 deadline, uint256 disputeWindow);
    event WorkSubmitted(uint256 indexed jobId, bytes32 workHash);
    event Released(uint256 indexed jobId, address seller, uint256 amount);
    event AutoReleased(uint256 indexed jobId);
    event Disputed(uint256 indexed jobId);
    event DisputeResolved(uint256 indexed jobId, address seller, uint256 sellerAmount, address buyer, uint256 buyerAmount);
    event Refunded(uint256 indexed jobId, address buyer, uint256 amount);
    event MilestoneReleased(uint256 indexed jobId, uint256 milestoneIdx, uint256 amount);

    constructor(address _arbiter) {
        require(_arbiter != address(0), "Invalid arbiter");
        arbiter = _arbiter;
    }

    // ── Create ──────────────────────────────────────────────────────────────

    /// @param disputeWindowSeconds 0 = use default (48h). Must be within MIN/MAX bounds.
    function createJob(
        address seller,
        address token,
        uint256 amount,
        uint256 deadline,
        uint256[] calldata milestoneAmounts,
        uint256 disputeWindowSeconds
    ) external returns (uint256 jobId) {
        require(deadline > block.timestamp,  "Deadline in past");
        require(amount > 0,                  "Amount zero");
        require(seller != address(0),        "Invalid seller");
        require(seller != msg.sender,        "Buyer cannot be seller");

        uint256 window = disputeWindowSeconds == 0 ? DEFAULT_DISPUTE_WINDOW : disputeWindowSeconds;
        require(window >= MIN_DISPUTE_WINDOW, "Window too short (min 6h)");
        require(window <= MAX_DISPUTE_WINDOW, "Window too long (max 7d)");

        if (milestoneAmounts.length > 0) {
            uint256 total;
            for (uint256 i; i < milestoneAmounts.length; i++) total += milestoneAmounts[i];
            require(total == amount, "Milestones != amount");
        }

        token.safeTransferFrom(msg.sender, address(this), amount);

        jobId = jobCount++;
        jobs[jobId] = Job({
            buyer:         msg.sender,
            seller:        seller,
            token:         token,
            amount:        amount,
            deadline:      deadline,
            disputeWindow: window,
            workHash:      bytes32(0),
            submittedAt:   0,
            status:        Status.Created
        });

        if (milestoneAmounts.length > 0) {
            milestones[jobId] = milestoneAmounts;
        }

        emit JobCreated(jobId, msg.sender, seller, token, amount, deadline, window);
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
        require(job.status == Status.WorkSubmitted,                              "Work not submitted");
        require(block.timestamp > uint256(job.submittedAt) + job.disputeWindow,  "Window still open");
        _release(job, jobId);
        emit AutoReleased(jobId);
    }

    function dispute(uint256 jobId) external {
        Job storage job = jobs[jobId];
        require(msg.sender == job.buyer,                                          "Not buyer");
        require(job.status == Status.WorkSubmitted,                               "Work not submitted");
        require(block.timestamp <= uint256(job.submittedAt) + job.disputeWindow,  "Window closed");
        job.status = Status.Disputed;
        emit Disputed(jobId);
    }

    // ── Arbiter: partial resolution ──────────────────────────────────────────

    /// @notice Arbiter resolves dispute with partial split.
    /// @param sellerBps Basis points for seller (0–10000). 10000 = 100% to seller, 0 = full refund.
    function resolveDispute(uint256 jobId, uint256 sellerBps) external {
        require(msg.sender == arbiter,         "Not arbiter");
        require(sellerBps <= 10_000,           "bps > 10000");
        Job storage job = jobs[jobId];
        require(job.status == Status.Disputed, "Not disputed");

        uint256 remaining = job.amount - releasedAmount[jobId];
        uint256 toSeller  = (remaining * sellerBps) / 10_000;
        uint256 toBuyer   = remaining - toSeller;

        job.status = sellerBps == 10_000 ? Status.Released : Status.PartiallyResolved;

        if (toSeller > 0) job.token.safeTransfer(job.seller, toSeller);
        if (toBuyer  > 0) job.token.safeTransfer(job.buyer,  toBuyer);

        emit DisputeResolved(jobId, job.seller, toSeller, job.buyer, toBuyer);
    }

    // ── Buyer: refund on no-show ─────────────────────────────────────────────

    function refund(uint256 jobId) external {
        Job storage job = jobs[jobId];
        require(msg.sender == job.buyer,        "Not buyer");
        require(job.status == Status.Created,   "Work was submitted");
        require(block.timestamp > job.deadline, "Deadline not passed");

        job.status = Status.Refunded;
        job.token.safeTransfer(job.buyer, job.amount);
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
        releasedAmount[jobId] += slice;
        job.token.safeTransfer(job.seller, slice);
        emit MilestoneReleased(jobId, idx, slice);
    }

    // ── Internal ─────────────────────────────────────────────────────────────

    function _release(Job storage job, uint256 jobId) internal {
        job.status = Status.Released;
        uint256 remaining = job.amount - releasedAmount[jobId];
        if (remaining > 0) job.token.safeTransfer(job.seller, remaining);
        emit Released(jobId, job.seller, remaining);
    }

    // ── View ─────────────────────────────────────────────────────────────────

    function getJob(uint256 jobId) external view returns (Job memory) {
        return jobs[jobId];
    }

    function getMilestones(uint256 jobId) external view returns (uint256[] memory) {
        return milestones[jobId];
    }

    /// @notice Remaining funds locked for this job (after milestone payouts)
    function remainingAmount(uint256 jobId) external view returns (uint256) {
        return jobs[jobId].amount - releasedAmount[jobId];
    }
}
