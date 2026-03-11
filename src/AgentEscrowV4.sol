// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// AgentEscrowV4 — trustless payment for agent-to-agent work
// New in V4 (over V3):
//   - On-chain reputation: buyer rates seller (1-5) after job completion
//   - Protocol fee: configurable bps (default 50 = 0.5%), paid to feeCollector on release
//   - Arbiter timeout: if dispute unresolved after arbiterTimeoutSeconds, anyone can force-release to seller

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
}

library SafeTransfer {
    function safeTransfer(address token, address to, uint256 amount) internal {
        if (amount == 0) return;
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

contract AgentEscrowV4 {
    using SafeTransfer for address;

    // ── Enums & Structs ────────────────────────────────────────────────────

    enum Status {
        Created,
        WorkSubmitted,
        Released,
        Refunded,
        Disputed,
        PartiallyResolved
    }

    struct Job {
        address buyer;
        address seller;
        address token;
        uint256 amount;
        uint256 deadline;
        uint256 disputeWindow;
        bytes32 workHash;
        uint64  submittedAt;
        uint64  disputedAt;     // timestamp when dispute was raised
        Status  status;
    }

    struct SellerReputation {
        uint256 totalRatings;   // sum of all ratings (1-5 each)
        uint256 ratingCount;    // number of ratings
        uint256 completedJobs;
        uint256 disputedJobs;
    }

    // ── Constants & Config ─────────────────────────────────────────────────

    uint256 public constant MIN_DISPUTE_WINDOW   = 6 hours;
    uint256 public constant MAX_DISPUTE_WINDOW   = 7 days;
    uint256 public constant DEFAULT_DISPUTE_WINDOW = 48 hours;
    uint256 public constant MAX_PROTOCOL_FEE_BPS = 500; // max 5%

    address public immutable ARBITER;

    address public feeCollector;
    uint256 public protocolFeeBps;       // default 50 = 0.5%
    uint256 public arbiterTimeoutSeconds; // default 7 days

    // ── State ──────────────────────────────────────────────────────────────

    uint256 public jobCount;
    mapping(uint256 => Job)              public jobs;
    mapping(uint256 => uint256[])        public milestones;
    mapping(uint256 => uint256)          public nextMilestone;
    mapping(uint256 => uint256)          public releasedAmount;
    mapping(address => SellerReputation) public reputation;
    mapping(uint256 => bool)             public jobRated; // prevent double-rating

    // ── Events ────────────────────────────────────────────────────────────

    event JobCreated(uint256 indexed jobId, address buyer, address seller, address token, uint256 amount, uint256 deadline, uint256 disputeWindow);
    event WorkSubmitted(uint256 indexed jobId, bytes32 workHash);
    event Released(uint256 indexed jobId, address seller, uint256 sellerAmount, uint256 feeAmount);
    event AutoReleased(uint256 indexed jobId);
    event Disputed(uint256 indexed jobId, uint64 disputedAt);
    event DisputeResolved(uint256 indexed jobId, address seller, uint256 sellerAmount, address buyer, uint256 buyerAmount, uint256 feeAmount);
    event ArbiterTimeoutRelease(uint256 indexed jobId);
    event Refunded(uint256 indexed jobId, address buyer, uint256 amount);
    event MilestoneReleased(uint256 indexed jobId, uint256 milestoneIdx, uint256 amount);
    event SellerRated(uint256 indexed jobId, address indexed seller, uint8 rating);
    event ProtocolFeeUpdated(uint256 newBps);
    event FeeCollectorUpdated(address newCollector);

    // ── Constructor ───────────────────────────────────────────────────────

    constructor(address _arbiter, address _feeCollector) {
        require(_arbiter      != address(0), "Invalid arbiter");
        require(_feeCollector != address(0), "Invalid feeCollector");
        ARBITER              = _arbiter;
        feeCollector         = _feeCollector;
        protocolFeeBps       = 50;       // 0.5%
        arbiterTimeoutSeconds = 7 days;
    }

    // ── Admin (arbiter only) ──────────────────────────────────────────────

    function setProtocolFee(uint256 bps) external {
        require(msg.sender == ARBITER,            "Not arbiter");
        require(bps <= MAX_PROTOCOL_FEE_BPS,      "Fee too high");
        protocolFeeBps = bps;
        emit ProtocolFeeUpdated(bps);
    }

    function setFeeCollector(address newCollector) external {
        require(msg.sender == ARBITER,            "Not arbiter");
        require(newCollector != address(0),       "Invalid address");
        feeCollector = newCollector;
        emit FeeCollectorUpdated(newCollector);
    }

    function setArbiterTimeout(uint256 seconds_) external {
        require(msg.sender == ARBITER,      "Not arbiter");
        require(seconds_ >= 1 days,         "Timeout too short");
        arbiterTimeoutSeconds = seconds_;
    }

    // ── Create ────────────────────────────────────────────────────────────

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
            disputedAt:    0,
            status:        Status.Created
        });

        if (milestoneAmounts.length > 0) milestones[jobId] = milestoneAmounts;

        emit JobCreated(jobId, msg.sender, seller, token, amount, deadline, window);
    }

    // ── Seller ────────────────────────────────────────────────────────────

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

    // ── Buyer ─────────────────────────────────────────────────────────────

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

        job.status     = Status.Disputed;
        job.disputedAt = uint64(block.timestamp);
        emit Disputed(jobId, uint64(block.timestamp));
    }

    function refund(uint256 jobId) external {
        Job storage job = jobs[jobId];
        require(msg.sender == job.buyer,        "Not buyer");
        require(job.status == Status.Created,   "Work was submitted");
        require(block.timestamp > job.deadline, "Deadline not passed");

        job.status = Status.Refunded;
        job.token.safeTransfer(job.buyer, job.amount);
        emit Refunded(jobId, job.buyer, job.amount);
    }

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

    /// @notice Buyer rates seller after job completion (1–5 stars).
    /// Can only be called once per job, only by buyer, only after job is released/resolved.
    function rateJob(uint256 jobId, uint8 rating) external {
        Job storage job = jobs[jobId];
        require(msg.sender == job.buyer, "Not buyer");
        require(
            job.status == Status.Released || job.status == Status.PartiallyResolved,
            "Job not complete"
        );
        require(!jobRated[jobId], "Already rated");
        require(rating >= 1 && rating <= 5, "Rating must be 1-5");

        jobRated[jobId] = true;
        SellerReputation storage rep = reputation[job.seller];
        rep.totalRatings += rating;
        rep.ratingCount++;

        emit SellerRated(jobId, job.seller, rating);
    }

    // ── Anyone ────────────────────────────────────────────────────────────

    /// @notice If arbiter has not resolved a dispute within arbiterTimeoutSeconds,
    /// anyone can force-release remaining funds to seller.
    /// Protects against arbiter disappearing or being censored.
    function arbiterTimeoutRelease(uint256 jobId) external {
        Job storage job = jobs[jobId];
        require(job.status == Status.Disputed, "Not disputed");
        require(
            block.timestamp > uint256(job.disputedAt) + arbiterTimeoutSeconds,
            "Arbiter timeout not reached"
        );
        _release(job, jobId);
        emit ArbiterTimeoutRelease(jobId);
    }

    // ── Arbiter ───────────────────────────────────────────────────────────

    /// @param sellerBps Basis points for seller (0–10000).
    function resolveDispute(uint256 jobId, uint256 sellerBps) external {
        require(msg.sender == ARBITER,         "Not arbiter");
        require(sellerBps <= 10_000,           "bps > 10000");
        Job storage job = jobs[jobId];
        require(job.status == Status.Disputed, "Not disputed");

        uint256 remaining = job.amount - releasedAmount[jobId];
        uint256 fee       = (remaining * protocolFeeBps) / 10_000;
        uint256 net       = remaining - fee;
        uint256 toSeller  = (net * sellerBps) / 10_000;
        uint256 toBuyer   = net - toSeller;

        job.status = sellerBps == 10_000 ? Status.Released : Status.PartiallyResolved;

        job.token.safeTransfer(feeCollector, fee);
        job.token.safeTransfer(job.seller,  toSeller);
        job.token.safeTransfer(job.buyer,   toBuyer);

        _trackReputation(job.seller, sellerBps >= 5_000);
        emit DisputeResolved(jobId, job.seller, toSeller, job.buyer, toBuyer, fee);
    }

    // ── Internal ──────────────────────────────────────────────────────────

    function _release(Job storage job, uint256 jobId) internal {
        job.status = Status.Released;
        uint256 remaining = job.amount - releasedAmount[jobId];
        uint256 fee       = (remaining * protocolFeeBps) / 10_000;
        uint256 net       = remaining - fee;

        job.token.safeTransfer(feeCollector, fee);
        job.token.safeTransfer(job.seller,   net);

        reputation[job.seller].completedJobs++;
        emit Released(jobId, job.seller, net, fee);
    }

    function _trackReputation(address seller, bool sellerWon) internal {
        reputation[seller].disputedJobs++;
        if (sellerWon) reputation[seller].completedJobs++;
    }

    // ── View ──────────────────────────────────────────────────────────────

    function getJob(uint256 jobId) external view returns (Job memory) {
        return jobs[jobId];
    }

    function getMilestones(uint256 jobId) external view returns (uint256[] memory) {
        return milestones[jobId];
    }

    function remainingAmount(uint256 jobId) external view returns (uint256) {
        return jobs[jobId].amount - releasedAmount[jobId];
    }

    /// @notice Returns seller's average rating as a fixed-point number (multiplied by 100).
    /// e.g. 450 = 4.50 stars
    function sellerRating(address seller) external view returns (uint256 avgX100, uint256 count) {
        SellerReputation memory rep = reputation[seller];
        count = rep.ratingCount;
        avgX100 = count == 0 ? 0 : (rep.totalRatings * 100) / count;
    }

    function sellerStats(address seller) external view returns (
        uint256 completedJobs,
        uint256 disputedJobs,
        uint256 avgRatingX100,
        uint256 ratingCount
    ) {
        SellerReputation memory rep = reputation[seller];
        completedJobs  = rep.completedJobs;
        disputedJobs   = rep.disputedJobs;
        ratingCount    = rep.ratingCount;
        avgRatingX100  = ratingCount == 0 ? 0 : (rep.totalRatings * 100) / ratingCount;
    }
}
